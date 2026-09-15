import Testing
@testable import WngmnAudio

/// Detecting the audio route that drops the caller to phone quality.
///
/// A Bluetooth headset used for both output and input runs its link in duplex, and the
/// output device's rate drops with it — 48 kHz to 24 on AirPods. The capture graph follows
/// that rate (`SystemAudioTap`, note 4), so the caller is still transcribed; this check
/// exists so the quality drop is named at startup rather than discovered on the call.
@Suite("Duplex route")
struct DuplexRouteTests {
    @Test("A Bluetooth headset used for both output and input runs in duplex")
    func flagsDuplexHeadset() {
        #expect(AudioRoute.runsInDuplex(
            outputIsBluetooth: true, inputIsSameBluetoothDevice: true))
    }

    /// The full-rate configuration: hear through the headset, speak into another microphone.
    @Test("Bluetooth output with a different microphone stays at full rate")
    func bluetoothOutputWiredInput() {
        #expect(!AudioRoute.runsInDuplex(
            outputIsBluetooth: true, inputIsSameBluetoothDevice: false))
    }

    @Test("A wired or built-in output is never affected")
    func nonBluetoothOutput() {
        #expect(!AudioRoute.runsInDuplex(
            outputIsBluetooth: false, inputIsSameBluetoothDevice: true))
        #expect(!AudioRoute.runsInDuplex(
            outputIsBluetooth: false, inputIsSameBluetoothDevice: false))
    }
}
