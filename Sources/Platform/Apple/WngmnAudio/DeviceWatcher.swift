import CoreAudio
import Foundation

/// Notices when the capture graph's foundations move under it.
///
/// The aggregate pins the default output device's UID at startup. When the user plugs in
/// headphones, switches to AirPods, or the machine sleeps and wakes, that sub-device
/// vanishes: the IOProc stops firing and **every status code still reads `noErr`**.
///
/// Property listeners are the primary signal because they fire deterministically on the
/// actual event. A no-buffer timer cannot be primary, and the naive version of that
/// watchdog is actively harmful: the tap legitimately delivers zero buffers whenever the
/// tapped output device is not clocking, which is what a quiet moment in an interview can
/// look like. A short no-buffer timer would therefore tear down and rebuild the capture
/// graph in the middle of the pause right before the journalist's next question.
public final class DeviceWatcher: @unchecked Sendable {
    public enum Change: Sendable {
        case defaultOutputDeviceChanged
        case clockDeviceDied
        /// The clock device changed sample rate without changing identity.
        case clockRateChanged
    }

    private var tokens: [AudioPropertyListenerToken] = []
    private let queue = DispatchQueue(label: "wngmn.devices")
    private let handler: @Sendable (Change) -> Void

    /// - Note: callbacks arrive on a HAL-internal thread, not on any queue of ours — the C
    ///   listener API has no queue parameter — so everything hops to `queue` first.
    public init(handler: @escaping @Sendable (Change) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    /// Registers the system-wide default-output listener.
    ///
    /// Deliberately separate from `watchClockDevice`, and registered *before* the capture
    /// graph is built: if building it throws, the process must still hear about the device
    /// change that follows. Otherwise unplugging a headset — which can make the graph fail to
    /// start at exactly the moment the default is in flux — leaves no listener at all, and
    /// recovery falls back to the 90-second no-buffer window.
    public func start() throws {
        stop()
        let queue = self.queue
        let handler = self.handler
        tokens.append(try AudioPropertyListener.add(
            to: AudioObjectID(kAudioObjectSystemObject),
            AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        ) { _, _ in
            queue.async { handler(.defaultOutputDeviceChanged) }
        })
    }

    /// Adds liveness and sample-rate listeners for the device the aggregate is clocked by.
    ///
    /// Rate matters as much as liveness. A Bluetooth headset whose microphone is opened
    /// mid-call drops its link to duplex and the device from 48 kHz to 24, keeping its
    /// identity: the default-output listener does not fire, `DeviceIsAlive` still reads 1,
    /// and the aggregate follows the new rate while everything downstream is still built
    /// for the old one. Only a rebuild puts them back in agreement.
    public func watchClockDevice(_ device: AudioObjectID) throws {
        guard device != kAudioObjectUnknown else { return }
        let queue = self.queue
        let handler = self.handler
        tokens.append(try AudioPropertyListener.add(
            to: device, AudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        ) { device, _ in
            // The notification carries no payload; re-read to find out what happened. A
            // device the HAL has forgotten fails the read outright, so a failed read is
            // itself the death signal.
            guard !AudioProperty.isAlive(device) else { return }
            queue.async { handler(.clockDeviceDied) }
        })
        tokens.append(try AudioPropertyListener.add(
            to: device, AudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        ) { _, _ in
            queue.async { handler(.clockRateChanged) }
        })
    }

    public func stop() {
        for token in tokens { AudioPropertyListener.remove(token) }
        tokens.removeAll()
    }
}
