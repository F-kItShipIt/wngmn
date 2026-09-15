import AVFoundation
import Testing
@testable import WngmnAudio

/// A capture-graph rebuild can come back at a different rate — a Bluetooth link dropping
/// into duplex takes the aggregate from 48 kHz to 24 — and the transcriber's resampler was
/// built for the old one. Left alone it reads the new buffers at the old rate: double speed,
/// an octave up. The cursor is the observable: a second of audio must advance it by a
/// second whichever rate it arrived at.
@Suite("Transcriber source rate", .serialized)
struct TranscriberSourceRateTests {
    @Test("Reconfiguring the source rate changes how far a buffer advances the cursor")
    func reconfigureTracksTheNewRate() async throws {
        let transcriber = try await Transcriber(configuration: .init())
        let at48k = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try await transcriber.prepare(sourceFormat: at48k)
        try await transcriber.feed([Float](repeating: 0, count: 48_000))
        let afterOneSecond = await transcriber.cursorSeconds
        #expect(abs(afterOneSecond - 1.0) < 0.05)

        // Without the reconfigure, 24,000 frames read at 48 kHz would advance it by half a
        // second and land at 1.5.
        let at24k = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try await transcriber.reconfigure(sourceFormat: at24k)
        try await transcriber.feed([Float](repeating: 0, count: 24_000))
        let afterTwoSeconds = await transcriber.cursorSeconds
        #expect(abs(afterTwoSeconds - 2.0) < 0.05)

        await transcriber.finish()
    }
}
