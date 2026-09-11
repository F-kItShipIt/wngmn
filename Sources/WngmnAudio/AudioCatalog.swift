import CoreAudio
import Foundation

/// Read-only inventory of what the HAL currently knows about.
///
/// This backs `wngmn devices`, which exists to answer two questions that cannot be
/// answered from documentation: which bundle ID actually carries Meet audio (Chrome renders
/// it from a helper process, not the browser process), and whether a previous run leaked a
/// private aggregate device.
public enum AudioCatalog {
    public struct Process: Sendable {
        public let objectID: AudioObjectID
        public let bundleID: String
        public let pid: pid_t
        /// True when this process is currently **rendering** audio. This is the signal that
        /// identifies which bundle ID carries a call's audio; `kAudioProcessPropertyIsRunning`
        /// is also true for a process that is only recording, which would point the tap at a
        /// microphone-only process.
        public let isRunningOutput: Bool
    }

    public struct Device: Sendable {
        public let objectID: AudioObjectID
        public let uid: String
        public let name: String
        public let transport: UInt32
        public let inputChannels: Int
        public let outputChannels: Int
        public let isAlive: Bool
        public let isDefaultOutput: Bool
        public let isDefaultInput: Bool

        public var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }
        /// Opening a Bluetooth headset's microphone switches the link to duplex, and while
        /// it is in that mode the process tap captures nothing at all — the caller's audio
        /// disappears with no error anywhere. Measured on AirPods Max: tap-only gives
        /// partials and questions, tap-plus-headset-mic gives zero, whichever order they
        /// are started in.
        public var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth }
        public var transportName: String { AudioProperty.fourCC(transport) }
    }

    // MARK: - Processes

    public static func processes() -> [Process] {
        let ids = (try? AudioProperty.array(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        )) ?? []

        return ids.map { id in
            // The HAL returns noErr with an EMPTY string for a process with no bundle (CLI
            // tools, including this one), so an empty result is not an error.
            let bundleID = AudioProperty.optionalString(
                from: id, AudioProperty.address(kAudioProcessPropertyBundleID)
            ) ?? ""
            let pid = (try? AudioProperty.value(
                pid_t.self, from: id, AudioProperty.address(kAudioProcessPropertyPID)
            )) ?? -1
            let renderingOutput = (try? AudioProperty.value(
                UInt32.self, from: id, AudioProperty.address(kAudioProcessPropertyIsRunningOutput)
            )) ?? 0
            return Process(
                objectID: id, bundleID: bundleID, pid: pid, isRunningOutput: renderingOutput != 0
            )
        }
    }

    /// Resolves bundle IDs to process object IDs.
    ///
    /// Only useful for diagnostics: the tap itself is scoped with
    /// `CATapDescription.bundleIDs`, which works even when the app is not running yet and
    /// survives it restarting mid-call.
    public static func processObjects(matching bundleIDs: [String]) -> [AudioObjectID] {
        let wanted = Set(bundleIDs.map { $0.lowercased() })
        return processes()
            .filter { !$0.bundleID.isEmpty && wanted.contains($0.bundleID.lowercased()) }
            .map(\.objectID)
    }

    /// `kAudioHardwarePropertyTranslatePIDToProcessObject` returns `noErr` with object ID 0
    /// for a PID that has never touched audio, so the status code says nothing.
    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = AudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var input = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &input, &size, &out
        )
        guard status == noErr, out != kAudioObjectUnknown, out != 0 else { return nil }
        return out
    }

    // MARK: - Devices

    public static func devices() -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = (try? AudioProperty.array(
            AudioObjectID.self, from: system, AudioProperty.address(kAudioHardwarePropertyDevices)
        )) ?? []
        let defaultOut = defaultOutputDevice()
        let defaultIn = defaultInputDevice()

        return ids.map { id in
            Device(
                objectID: id,
                uid: AudioProperty.optionalString(
                    from: id, AudioProperty.address(kAudioDevicePropertyDeviceUID)
                ) ?? "",
                name: AudioProperty.optionalString(
                    from: id, AudioProperty.address(kAudioObjectPropertyName)
                ) ?? "",
                transport: (try? AudioProperty.value(
                    UInt32.self, from: id, AudioProperty.address(kAudioDevicePropertyTransportType)
                )) ?? 0,
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                isAlive: AudioProperty.isAlive(id),
                isDefaultOutput: id == defaultOut,
                isDefaultInput: id == defaultIn
            )
        }
    }

    public static func defaultOutputDevice() -> AudioObjectID? {
        let id = try? AudioProperty.value(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        )
        return (id == kAudioObjectUnknown) ? nil : id
    }

    public static func defaultInputDevice() -> AudioObjectID? {
        let id = try? AudioProperty.value(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            AudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
        )
        return (id == kAudioObjectUnknown) ? nil : id
    }

    public static func deviceUID(_ device: AudioObjectID) -> String? {
        AudioProperty.optionalString(from: device, AudioProperty.address(kAudioDevicePropertyDeviceUID))
    }

    public static func deviceName(_ device: AudioObjectID) -> String {
        AudioProperty.optionalString(from: device, AudioProperty.address(kAudioObjectPropertyName))
            ?? "(unnamed)"
    }

    private static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0,
              size < 64 * 1024
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Live taps

    /// Taps this client owns. Used by teardown verification.
    public static func liveTaps() -> [AudioObjectID] {
        (try? AudioProperty.array(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            AudioProperty.address(kAudioHardwarePropertyTapList)
        )) ?? []
    }
}
