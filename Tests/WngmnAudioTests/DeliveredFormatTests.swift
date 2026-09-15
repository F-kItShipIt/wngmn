import AVFoundation
import Testing
@testable import WngmnAudio

/// The rate the IOProc delivers is the aggregate's, not the tap's.
///
/// `kAudioTapPropertyFormat` reports the tap's native format, 48 kHz. But the IOProc runs
/// on the aggregate, and the aggregate is clocked by the output device. When that device is
/// a Bluetooth headset whose microphone has just been opened, the link drops to duplex and
/// the device — so the aggregate — runs at 24 kHz. The tap's property still says 48.
/// Measured: `selftest` counted 72,000 frames over a 3 s window, 24,000 a second, while
/// the format read 48,000. Fed to the recogniser as 48 kHz that audio plays at double speed
/// an octave up, and the caller transcribes as fragments or not at all.
@Suite("Delivered format")
struct DeliveredFormatTests {
    let tap = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true
    )!

    @Test("The aggregate's rate wins when it disagrees with the tap")
    func aggregateRateWins() {
        let delivered = SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: 24_000)
        #expect(delivered.sampleRate == 24_000)
    }

    /// Only the rate moves. Channel count and sample layout were validated against the
    /// tap's own description and must survive the substitution.
    @Test("Layout is preserved across the rate substitution")
    func layoutPreserved() {
        let delivered = SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: 24_000)
        #expect(delivered.channelCount == 1)
        #expect(delivered.commonFormat == .pcmFormatFloat32)
        #expect(delivered.isInterleaved == tap.isInterleaved)
    }

    @Test("Agreement leaves the tap format untouched")
    func agreementIsIdentity() {
        #expect(SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: 48_000) == tap)
    }

    /// An unreadable or nonsensical aggregate rate is not a reason to guess. The tap's own
    /// description is the best remaining evidence.
    @Test("No usable aggregate rate falls back to the tap")
    func fallsBackToTap() {
        #expect(SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: nil) == tap)
        #expect(SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: 0) == tap)
        #expect(SystemAudioTap.deliveredFormat(tap: tap, aggregateRate: -1) == tap)
    }
}
