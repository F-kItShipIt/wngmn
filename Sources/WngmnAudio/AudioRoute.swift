import CoreAudio
import Foundation

/// Whether the current audio route can carry a process tap at all.
public enum AudioRoute {
    /// A Bluetooth headset used for output *and* input kills the tap.
    ///
    /// Opening the headset's microphone switches the link into duplex mode, and while it is
    /// there the tap captures nothing — no error, no dropped buffers, the timeline keeps
    /// advancing, and the caller's audio is simply not in it. Pure so the rule can be stated
    /// once and asserted; the detection around it is in `conflict()`.
    public static func willBreakTap(
        outputIsBluetooth: Bool, inputIsSameBluetoothDevice: Bool
    ) -> Bool {
        outputIsBluetooth && inputIsSameBluetoothDevice
    }

    /// Describes the conflict on this machine right now, or nil when the route is usable.
    ///
    /// Checked against the *system* default input rather than wngmn's own choice: the
    /// call app opens a microphone too, and Zoom set to the headset breaks the tap no matter
    /// which device wngmn was told to use.
    public static func conflict() -> String? {
        let devices = AudioCatalog.devices()
        guard let outputID = AudioCatalog.defaultOutputDevice(),
              let output = devices.first(where: { $0.objectID == outputID }),
              output.isBluetooth
        else { return nil }

        guard let inputID = AudioCatalog.defaultInputDevice(),
              let input = devices.first(where: { $0.objectID == inputID }),
              input.isBluetooth,
              // Same physical headset: macOS exposes the two directions as separate devices
              // whose UIDs share the MAC address prefix.
              input.uid.split(separator: ":").first == output.uid.split(separator: ":").first
        else { return nil }

        guard willBreakTap(outputIsBluetooth: true, inputIsSameBluetoothDevice: true) else {
            return nil
        }
        return output.name
    }
}
