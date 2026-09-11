import AVFoundation
import CoreAudio
import Foundation
import WngmnCore
import Synchronization

/// Captures the audio a conferencing app is sending to the speakers, without a virtual
/// audio driver and without a reboot.
///
/// The graph is: a `CATapDescription` scoped by bundle ID → a **private** aggregate device
/// clocked by the current default output device → an IOProc that copies frames into a
/// lock-free ring buffer.
///
/// Three things about this graph are counter-intuitive and all three are load-bearing:
///
/// 1. **The IOProc must be real-time safe.** It runs on a Core Audio real-time thread.
///    Allocating, locking or writing to a pipe there stalls that thread when the consumer
///    falls behind, which produces audible dropouts *on the live call*. It therefore does
///    nothing but copy floats into a preallocated ring.
///
/// 2. **The aggregate only clocks IO while the tapped output device is running.** With the
///    speakers idle, `AudioDeviceStart` returns `noErr`, `kAudioDevicePropertyDeviceIsRunning`
///    reads 0, and the IOProc fires *zero times, forever*. Measured causally: 0 callbacks
///    over 2 s with the speakers idle, 202 callbacks after attaching a silent output IOProc
///    to them. Because whether anything else happens to be playing is a coin flip, this
///    failure looks exactly like flakiness. `keepOutputAlive` holds the output device open
///    with a silent IOProc for the whole session so it cannot happen.
///
/// 3. **Tap creation succeeding proves nothing.** `AudioHardwareCreateProcessTap` returns a
///    fully formed tap with a valid format for bundle IDs of apps that are not installed.
///    Only non-zero samples prove capture works, which is what `selftest` is for.
public final class SystemAudioTap: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Apps to capture. Scoping by bundle ID rather than by process object means the tap
        /// works before the app launches and survives it restarting mid-call.
        public var bundleIDs: [String]
        /// Capture everything instead of scoping. Picks up notification sounds and other
        /// tabs, so Do Not Disturb becomes mandatory in this mode.
        public var globalTap: Bool
        /// Hold the tapped output device open with a silent IOProc. See note 2 above.
        public var keepOutputAlive: Bool
        public var ringCapacityFrames: Int

        public init(
            bundleIDs: [String] = [], globalTap: Bool = false,
            keepOutputAlive: Bool = true, ringCapacityFrames: Int = 1 << 20
        ) {
            self.bundleIDs = bundleIDs
            self.globalTap = globalTap
            self.keepOutputAlive = keepOutputAlive
            self.ringCapacityFrames = ringCapacityFrames
        }
    }

    public struct Diagnostics: Sendable {
        public let callbacks: UInt64
        public let frames: UInt64
        public let peak: Float
        public let lastHostTime: UInt64
        public let framesDropped: UInt64
        /// False when the tapped output device is not clocking. See note 2.
        public let outputDeviceRunning: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case noDefaultOutputDevice
        case noOutputDeviceUID
        case coreAudio(String, OSStatus)
        case unexpectedFormat(String)

        public var description: String {
            switch self {
            case .noDefaultOutputDevice:
                return "no default output device; the aggregate has nothing to clock against"
            case .noOutputDeviceUID:
                return "the default output device has no UID"
            case let .coreAudio(what, status):
                return "\(what): \(AudioProperty.statusDescription(status))"
            case let .unexpectedFormat(detail):
                return "unexpected tap format: \(detail)"
            }
        }
    }

    public let ring: AudioRingBuffer
    public private(set) var format: AVAudioFormat!
    /// The output device the aggregate is clocked by. Pinned at start; if it disappears the
    /// IOProc silently stops, which is what `DeviceWatcher` exists to notice.
    public private(set) var clockDeviceID: AudioObjectID = kAudioObjectUnknown

    private let configuration: Configuration
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var keepAliveProcID: AudioDeviceIOProcID?
    private var keepAliveDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var started = false
    /// Which buffer of the IOProc's input list actually carries the tap.
    ///
    /// An aggregate exposes the union of its members' streams, so its input scope holds the
    /// **sub-device's own input buffers first** and the tap's last. Taking buffer 0 is only
    /// correct when the output device happens to have no inputs. Measured: with the built-in
    /// speakers (0 in) the input config is `[(0, 1)]` and the tap is buffer 0; with a device
    /// that has inputs it is `[(0, 2), (1, 1)]` and buffer 0 is that device's *microphone*.
    /// Reading the wrong buffer would transcribe the wrong device for the whole interview —
    /// silently, because `readTapFormat()` validates the tap object's format, not the
    /// aggregate's layout.
    private var tapBufferIndex = 0

    private let counters = Counters()
    private let ioQueue = DispatchQueue(label: "wngmn.tap", qos: .userInitiated)

    /// Counters the IOProc updates. `Atomic` is non-copyable, so it cannot be captured by
    /// value into the block; a shared reference type is the way to reach it from the
    /// real-time thread without touching `self`.
    private final class Counters: Sendable {
        let callbacks = Atomic<UInt64>(0)
        let frames = Atomic<UInt64>(0)
        let peakBits = Atomic<UInt32>(0)
        let lastHostTime = Atomic<UInt64>(0)
    }

    /// Every aggregate this program creates carries this prefix, so a leftover can be
    /// identified unambiguously and nothing else is ever touched.
    static let aggregateUIDPrefix = "local.wngmn."

    public init(configuration: Configuration) {
        self.configuration = configuration
        ring = AudioRingBuffer(capacityFrames: configuration.ringCapacityFrames)
    }

    /// Destroys aggregate devices left behind by a previous run.
    ///
    /// `atexit` does not run on SIGKILL, so a crash can leave one behind — and a private
    /// aggregate is invisible to `system_profiler` by construction, which means nobody would
    /// ever notice. Only devices carrying this program's own UID prefix are touched.
    /// Returns the number destroyed, which is normally zero: the HAL may well reap them when
    /// the creating client disconnects, and a private aggregate belonging to a dead process
    /// may not be visible here at all.
    @discardableResult
    public static func sweepLeakedAggregates() -> Int {
        var swept = 0
        for device in AudioCatalog.devices()
        where device.isAggregate && device.uid.hasPrefix(aggregateUIDPrefix) {
            if AudioHardwareDestroyAggregateDevice(device.objectID) == noErr { swept += 1 }
        }
        return swept
    }

    deinit { teardown() }

    // MARK: - Lifecycle

    public func start() throws {
        guard let output = AudioCatalog.defaultOutputDevice() else { throw Failure.noDefaultOutputDevice }
        guard let outputUID = AudioCatalog.deviceUID(output), !outputUID.isEmpty else {
            throw Failure.noOutputDeviceUID
        }
        clockDeviceID = output

        // Partial construction must not leak. Any throw below leaves a tap, and possibly an
        // aggregate device, already registered with the HAL — and a private aggregate is
        // invisible to `system_profiler`, so it would never be noticed.
        var completed = false
        defer { if !completed { rollback() } }

        try createTap()
        try readTapFormat()
        try createAggregate(clockedBy: outputUID)
        try resolveTapBufferIndex()
        if configuration.keepOutputAlive { startKeepAlive(on: output) }
        try startIO()
        started = true
        completed = true
    }

    /// Undoes a partially built graph without latching the idempotent teardown flag, so a
    /// caller may retry `start()` on the same instance.
    private func rollback() {
        if let procID = keepAliveProcID, keepAliveDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(keepAliveDeviceID, procID)
            AudioDeviceDestroyIOProcID(keepAliveDeviceID, procID)
            keepAliveProcID = nil
            keepAliveDeviceID = kAudioObjectUnknown
        }
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        started = false
    }

    private func createTap() throws {
        let description: CATapDescription
        if configuration.globalTap {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        } else {
            // Include semantics: an empty process list plus a bundle-ID list means
            // "only these apps". isExclusive stays false, isMixdown stays true.
            description = CATapDescription(monoMixdownOfProcesses: [])
            description.bundleIDs = configuration.bundleIDs
        }
        description.name = "wngmn capture"
        description.uuid = UUID()
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        // Never `.muted`: the speakers must keep playing on a live call.
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw Failure.coreAudio("AudioHardwareCreateProcessTap", status)
        }
        tapID = id
        tapUUIDString = description.uuid.uuidString
    }

    private var tapUUIDString = ""

    private func readTapFormat() throws {
        var asbd = try AudioProperty.value(
            AudioStreamBasicDescription.self, from: tapID,
            AudioProperty.address(kAudioTapPropertyFormat)
        )
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw Failure.unexpectedFormat("could not build an AVAudioFormat from the tap ASBD")
        }
        // The tap ASBD is Float32 48 kHz interleaved (flags 0x9). Interleaving is moot at one
        // channel, but the source format handed to AVAudioConverter is built from this ASBD
        // rather than hardcoded, so a future stereo tap would not silently mis-read.
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw Failure.unexpectedFormat("expected Float32, got \(format)")
        }
        guard format.channelCount == 1 else {
            // A stereo tap would need an explicit downmix: AVAudioConverter defaults to
            // channelMap [0] and would silently discard the right channel.
            throw Failure.unexpectedFormat("expected a mono mixdown, got \(format.channelCount) channels")
        }
        self.format = format
    }

    private func createAggregate(clockedBy outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "\(Self.aggregateUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "wngmn",
            // Private means per-client: invisible to other processes, still visible to us.
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUIDString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw Failure.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = id
    }

    /// Locates the tap within the aggregate's input layout, and refuses to start if it
    /// cannot be identified with certainty.
    private func resolveTapBufferIndex() throws {
        var addr = AudioProperty.address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size), size < 64 * 1024
        else {
            throw Failure.unexpectedFormat("could not read the aggregate's input stream configuration")
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else {
            throw Failure.unexpectedFormat("could not read the aggregate's input stream configuration")
        }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        guard !list.isEmpty else {
            throw Failure.unexpectedFormat("the aggregate exposes no input buffers")
        }
        // Tap streams are appended after the sub-device's own input streams.
        let index = list.count - 1
        let channels = list[index].mNumberChannels
        guard channels == UInt32(format.channelCount) else {
            throw Failure.unexpectedFormat(
                "aggregate input buffer \(index) carries \(channels) channels, the tap has "
                + "\(format.channelCount) — refusing to capture from an unidentified stream"
            )
        }
        tapBufferIndex = index
    }

    private func startIO() throws {
        let ring = self.ring
        let counters = self.counters
        let tapBufferIndex = self.tapBufferIndex
        let expectedChannels = UInt32(format.channelCount)

        // `@Sendable` on the closure is not cosmetic. Without it the block inherits the
        // enclosing actor isolation, and the isolation check Swift 6 inserts calls
        // dispatch_assert_queue on the Core Audio IO thread and traps — at -O, in Swift 6
        // language mode, with no compiler warning, the instant the first buffer arrives.
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            @Sendable (_, inInputData, inInputTime, _, _) in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard tapBufferIndex < list.count else { return }
            let buffer = list[tapBufferIndex]
            // The layout was validated at start(); if it ever changes underneath us, drop
            // the buffer rather than reinterpret an interleaved stream as mono.
            guard buffer.mNumberChannels == expectedChannels, let raw = buffer.mData else { return }

            let frameCount = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * Int(expectedChannels))
            guard frameCount > 0 else { return }

            let samples = raw.assumingMemoryBound(to: Float.self)
            let hostTime = inInputTime.pointee.validHostTime ?? 0

            // One pass for the level meter. No allocation, no locks, no syscalls.
            var peak: Float = 0
            for i in 0..<frameCount {
                let magnitude = abs(samples[i])
                if magnitude > peak { peak = magnitude }
            }

            _ = ring.write(samples, frameCount: frameCount, hostTime: hostTime)

            counters.callbacks.wrappingAdd(1, ordering: .relaxed)
            counters.frames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            counters.lastHostTime.store(hostTime, ordering: .relaxed)
            let bits = peak.bitPattern
            if bits > counters.peakBits.load(ordering: .relaxed) {
                counters.peakBits.store(bits, ordering: .relaxed)
            }
        }
        guard status == noErr, procID != nil else {
            throw Failure.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw Failure.coreAudio("AudioDeviceStart", status) }
    }

    /// Holds the tapped output device open with an IOProc that writes silence, so the
    /// aggregate keeps clocking even when nothing else is playing.
    ///
    /// A failure here is not fatal: capture still works whenever the device happens to be
    /// running, which on a live call it is.
    private func startKeepAlive(on device: AudioObjectID) {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, device, ioQueue
        ) { @Sendable (_, _, _, outOutputData, _) in
            // Explicitly silence the buffers. They are not guaranteed to arrive zeroed, and
            // handing the speakers uninitialised memory during an interview would be loud.
            let list = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buffer in list {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        guard status == noErr, let procID else { return }
        guard AudioDeviceStart(device, procID) == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            return
        }
        keepAliveProcID = procID
        keepAliveDeviceID = device
    }

    // MARK: - Teardown

    private let tornDown = Atomic<Bool>(false)

    /// Idempotent. Runs from normal exit, from the signal handler, and from `deinit`.
    ///
    /// A leaked private aggregate is invisible to `system_profiler` by construction, so
    /// "no leaked devices" can only be checked by enumerating `kAudioHardwarePropertyDevices`
    /// — and even then not synchronously, because the HAL client caches the object list for
    /// about a second after a destroy.
    public func teardown() {
        guard !tornDown.exchange(true, ordering: .acquiringAndReleasing) else { return }

        if let procID = keepAliveProcID, keepAliveDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(keepAliveDeviceID, procID)
            AudioDeviceDestroyIOProcID(keepAliveDeviceID, procID)
            keepAliveProcID = nil
        }
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        started = false
    }

    // MARK: - Observation

    public var diagnostics: Diagnostics {
        Diagnostics(
            callbacks: counters.callbacks.load(ordering: .relaxed),
            frames: counters.frames.load(ordering: .relaxed),
            peak: Float(bitPattern: counters.peakBits.load(ordering: .relaxed)),
            lastHostTime: counters.lastHostTime.load(ordering: .relaxed),
            framesDropped: ring.framesDropped,
            outputDeviceRunning: Self.isRunningSomewhere(clockDeviceID)
        )
    }

    public func resetPeak() { counters.peakBits.store(0, ordering: .relaxed) }

    /// System-wide: 1 while any process is running IO on the device. This is the property
    /// that answers "will the aggregate clock", not the per-process `DeviceIsRunning`.
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        let value = try? AudioProperty.value(
            UInt32.self, from: device,
            AudioProperty.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        )
        return (value ?? 0) != 0
    }

    /// True while our IOProc is still registered on the aggregate.
    ///
    /// The scope must be Input or Output — on `kAudioObjectPropertyScopeGlobal` the size
    /// query returns `noErr` with a garbage length (observed in the gigabytes), and
    /// allocating it segfaults.
    public var ioProcStillRegistered: Bool {
        guard let procID = ioProcID, aggregateID != kAudioObjectUnknown else { return false }
        var addr = AudioProperty.address(
            kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
              size <= 64 * 1024
        else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { raw.deallocate() }
        raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self).pointee.mIOProc =
            unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        return AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr
    }
}
