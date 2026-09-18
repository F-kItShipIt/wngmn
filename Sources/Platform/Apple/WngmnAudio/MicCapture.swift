import AVFoundation
import CoreAudio
import Foundation
import WngmnCore
import Synchronization

/// Captures the local microphone — the "You" half of a two-speaker transcript.
///
/// A separate capture path rather than another stream on `SystemAudioTap`'s private
/// aggregate. The aggregate carries the device-change rebuild logic that has to survive a
/// live call, and threading a second device through it would put the riskiest code in the
/// system on the critical path for a feature that does not need it. The two sources are
/// correlated by host time instead, which is what `AudioStreamClock` already does for the
/// tap — so they share a timeline without sharing a device.
///
/// Microphone access is granted to the *terminal app*, not to this binary, exactly as
/// System Audio Recording is. A denial yields silence rather than an error, so
/// `diagnostics` exists to tell "nobody is speaking" apart from "we were never allowed to
/// listen".
public final class MicCapture: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Device UID to capture from. Nil uses the system default input.
        public var deviceUID: String?
        public var ringCapacityFrames: Int

        public init(deviceUID: String? = nil, ringCapacityFrames: Int = 1 << 20) {
            self.deviceUID = deviceUID
            self.ringCapacityFrames = ringCapacityFrames
        }
    }

    public struct Diagnostics: Sendable {
        public let callbacks: UInt64
        public let frames: UInt64
        public let peak: Float
        public let lastHostTime: UInt64
        public let framesDropped: UInt64
    }

    public enum Failure: Error, CustomStringConvertible {
        case noInputDevice
        case unknownDevice(String)
        case unexpectedFormat(String)
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .noInputDevice:
                return "no default input device; pass --mic-device with a UID from `wngmn devices`"
            case let .unknownDevice(uid):
                return "no input device with UID '\(uid)'; run `wngmn devices` to list them"
            case let .unexpectedFormat(detail):
                return detail
            case let .coreAudio(call, status):
                return "\(call) failed: \(AudioProperty.statusDescription(status))"
            }
        }
    }

    /// Frames of headroom for the downmix scratch. Core Audio buffer sizes are far below
    /// this; the guard in the IOProc drops anything larger rather than overrun it.
    private static let maxFramesPerCallback = 8192

    /// Preallocated downmix scratch. A class, for the same reason `Counters` is one: the
    /// IOProc block is `@Sendable`, and a bare `UnsafeMutablePointer` cannot cross that
    /// boundary. Owned solely by the IOProc, which is the only thing that ever writes it.
    private final class MonoScratch: @unchecked Sendable {
        let samples: UnsafeMutablePointer<Float>
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
        }

        deinit {
            samples.deinitialize(count: capacity)
            samples.deallocate()
        }
    }

    private final class Counters: Sendable {
        let callbacks = Atomic<UInt64>(0)
        let frames = Atomic<UInt64>(0)
        let peakBits = Atomic<UInt32>(0)
        let lastHostTime = Atomic<UInt64>(0)
    }

    public let ring: AudioRingBuffer
    public private(set) var format: AVAudioFormat!
    public private(set) var deviceID: AudioObjectID = kAudioObjectUnknown

    private let configuration: Configuration
    private let counters = Counters()
    private let ioQueue = DispatchQueue(label: "wngmn.mic.io", qos: .userInitiated)
    private var ioProcID: AudioDeviceIOProcID?
    /// Preallocated so the IOProc never allocates. A multi-channel input is downmixed into
    /// this before it reaches the ring.
    private let scratch = MonoScratch(capacity: MicCapture.maxFramesPerCallback)

    public init(configuration: Configuration) {
        self.configuration = configuration
        ring = AudioRingBuffer(capacityFrames: configuration.ringCapacityFrames)
    }

    public var diagnostics: Diagnostics {
        Diagnostics(
            callbacks: counters.callbacks.load(ordering: .relaxed),
            frames: counters.frames.load(ordering: .relaxed),
            peak: Float(bitPattern: counters.peakBits.load(ordering: .relaxed)),
            lastHostTime: counters.lastHostTime.load(ordering: .relaxed),
            framesDropped: ring.framesDropped
        )
    }

    public func start() throws {
        deviceID = try resolveDevice()
        let asbd = try readInputFormat(deviceID)

        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else {
            throw Failure.unexpectedFormat(
                "input device is not 32-bit float PCM; wngmn reads the HAL's float stream "
                + "directly and will not silently reinterpret \(asbd.mBitsPerChannel)-bit samples"
            )
        }

        // Presented to the rest of the pipeline as mono at the device's own rate: the
        // transcriber resamples from here, and a downmix is cheaper and more predictable
        // than asking the HAL to change the device's format out from under other apps.
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.unexpectedFormat("could not describe the input as mono float32")
        }
        format = mono

        try startIO(channels: asbd.mChannelsPerFrame, interleaved: asbd.isInterleaved)
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            self.ioProcID = nil
        }
        deviceID = kAudioObjectUnknown
    }

    // MARK: - Setup

    private func resolveDevice() throws -> AudioObjectID {
        guard let uid = configuration.deviceUID else {
            guard let device = AudioCatalog.defaultInputDevice() else { throw Failure.noInputDevice }
            return device
        }
        guard let match = AudioCatalog.devices().first(
            where: { $0.uid == uid && $0.inputChannels > 0 }
        ) else {
            throw Failure.unknownDevice(uid)
        }
        return match.objectID
    }

    private func readInputFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        do {
            return try AudioProperty.value(
                AudioStreamBasicDescription.self, from: device,
                AudioProperty.address(
                    kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput
                )
            )
        } catch {
            throw Failure.coreAudio("kAudioDevicePropertyStreamFormat", kAudioHardwareUnknownPropertyError)
        }
    }

    private func startIO(channels: UInt32, interleaved: Bool) throws {
        let ring = self.ring
        let counters = self.counters
        let scratch = self.scratch
        let maxFrames = Self.maxFramesPerCallback
        let channelCount = Int(channels)

        // `@Sendable` is load-bearing, not cosmetic: without it the block inherits the
        // enclosing isolation and Swift 6 inserts a dispatch_assert_queue that traps on the
        // Core Audio IO thread the instant the first buffer arrives.
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, ioQueue) {
            @Sendable (_, inInputData, inInputTime, _, _) in
            let mono = scratch.samples
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            guard let buffer = list.first, let raw = buffer.mData else { return }

            let bufferChannels = Int(buffer.mNumberChannels)
            guard bufferChannels > 0 else { return }
            let frameCount = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * bufferChannels)
            guard frameCount > 0, frameCount <= maxFrames else { return }

            let samples = raw.assumingMemoryBound(to: Float.self)
            let hostTime = inInputTime.pointee.validHostTime ?? 0

            // Downmix and measure in one pass. No allocation, no locks, no syscalls.
            var peak: Float = 0
            if bufferChannels == 1 {
                for i in 0..<frameCount {
                    let sample = samples[i]
                    mono[i] = sample
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
            } else if interleaved || bufferChannels == channelCount {
                let scale = 1 / Float(bufferChannels)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<bufferChannels {
                        sum += samples[frame * bufferChannels + channel]
                    }
                    let sample = sum * scale
                    mono[frame] = sample
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                }
            } else {
                return
            }

            _ = ring.write(mono, frameCount: frameCount, hostTime: hostTime)

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

        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            ioProcID = nil
            throw Failure.coreAudio("AudioDeviceStart", status)
        }
    }
}

extension AudioStreamBasicDescription {
    /// The HAL signals non-interleaved by *setting* this flag, so interleaved is its absence.
    var isInterleaved: Bool { mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 }
}
