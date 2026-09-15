import Testing
@testable import WngmnAudio

/// Detecting a tap that is clocking but carrying nothing.
///
/// `no_audio` asks whether buffers are arriving. It cannot see the failure where they are —
/// so the watchdog stays quiet and the timeline advances normally — while every sample in
/// them is silence. First observed when the AirPods microphone was opened, before the
/// capture graph followed the clock device's rate: the link switched to duplex, the tap
/// kept clocking, and the caller's audio simply stopped being in it. Four minutes with no
/// warning of any kind.
@Suite("Silent capture")
struct SilentCaptureTests {
    let floor = -60.0
    let after = 120.0

    func check(peak: Double, seconds: Double, warned: Bool = false) -> Bool {
        Pipeline.shouldWarnSilentCapture(
            loudestDB: peak, secondsSinceStart: seconds, alreadyWarned: warned,
            floorDB: floor, afterSeconds: after
        )
    }

    @Test("Real audio never triggers it, however quiet")
    func realAudioIsFine() {
        #expect(!check(peak: -50, seconds: 300))
        #expect(!check(peak: -59.9, seconds: 300))
    }

    /// The window has to be long: a genuinely quiet stretch before a call starts is normal,
    /// and crying wolf there would train the warning to be ignored.
    @Test("Silence is not reported until it has lasted")
    func waitsBeforeReporting() {
        #expect(!check(peak: -90, seconds: 30))
        #expect(!check(peak: -90, seconds: 119))
        #expect(check(peak: -90, seconds: 121))
    }

    @Test("Reported once, not every poll")
    func onlyOnce() {
        #expect(check(peak: -90, seconds: 200, warned: false))
        #expect(!check(peak: -90, seconds: 200, warned: true))
    }

    /// Digital silence is the signature of this failure — not merely a quiet room.
    @Test("Absolute silence is the trigger")
    func absoluteSilence() {
        #expect(check(peak: -120, seconds: 200))
    }
}
