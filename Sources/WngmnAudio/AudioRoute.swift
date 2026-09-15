import CoreAudio
import Foundation

/// Whether the current audio route puts a Bluetooth link into duplex.
public enum AudioRoute {
    /// A Bluetooth headset used for output *and* input runs its link in duplex.
    ///
    /// Opening the headset's microphone switches the link from high-quality one-way audio to
    /// a phone-quality two-way codec, and the output device's sample rate drops with it —
    /// 48 kHz to 24 on AirPods. The capture graph follows that rate (`SystemAudioTap`,
    /// note 4), so the caller is still transcribed, at phone quality. Pure so the rule can
    /// be stated once and asserted; the detection around it is in `duplexHeadset()`.
    public static func runsInDuplex(
        outputIsBluetooth: Bool, inputIsSameBluetoothDevice: Bool
    ) -> Bool {
        outputIsBluetooth && inputIsSameBluetoothDevice
    }

    /// Names the headset whose link runs in duplex on this machine right now, or nil.
    ///
    /// Checked against the *system* default input rather than wngmn's own choice: the call
    /// app opens a microphone too, and Zoom set to the headset puts the link in duplex no
    /// matter which device wngmn was told to use.
    public static func duplexHeadset() -> String? {
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

        guard runsInDuplex(outputIsBluetooth: true, inputIsSameBluetoothDevice: true) else {
            return nil
        }
        return output.name
    }
}
