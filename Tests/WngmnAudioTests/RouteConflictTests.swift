import Testing
@testable import WngmnAudio

/// Detecting the audio route that silently kills caller capture.
///
/// When the output device is a Bluetooth headset and something opens that same headset's
/// microphone, the link switches to duplex and the macOS process tap stops seeing rendered
/// audio entirely. Nothing errors: the tap keeps clocking, the timeline advances, and the
/// caller's half of the conversation is simply absent. Verified on AirPods Max — tap alone
/// captures, tap plus that headset's mic captures nothing, in either start order.
@Suite("Route conflict")
struct RouteConflictTests {
    @Test("A Bluetooth headset used for both output and input is flagged")
    func flagsDuplexHeadset() {
        #expect(AudioRoute.willBreakTap(
            outputIsBluetooth: true, inputIsSameBluetoothDevice: true))
    }

    /// The working configuration: hear through the headset, speak into another microphone.
    @Test("Bluetooth output with a different microphone is fine")
    func bluetoothOutputWiredInput() {
        #expect(!AudioRoute.willBreakTap(
            outputIsBluetooth: true, inputIsSameBluetoothDevice: false))
    }

    @Test("A wired or built-in output is never affected")
    func nonBluetoothOutput() {
        #expect(!AudioRoute.willBreakTap(
            outputIsBluetooth: false, inputIsSameBluetoothDevice: true))
        #expect(!AudioRoute.willBreakTap(
            outputIsBluetooth: false, inputIsSameBluetoothDevice: false))
    }
}
