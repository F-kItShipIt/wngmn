import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import WngmnAudio

/// Where the recogniser's timestamps land on the shared capture timeline.
///
/// The two capture sources measure from one origin, so a source that starts after the
/// other has a first buffer that is already seconds into that timeline — or, when its
/// buffers predate the origin, at negative seconds. The recogniser counts from zero. Its
/// times have to be translated back onto the timeline every endpoint is stamped on, or a
/// question from that source never matches the boundary that closed it and is released
/// only by the timeout, with the wrong words.
@Suite("Transcriber timeline", .serialized)
struct TranscriberTimelineTests {
    /// Feeds a fixture as if capture had started at `origin` seconds on the shared timeline
    /// and returns every finalised transcript as (start, end, text) in stream seconds.
    static func finals(from name: String, origin: Double) async throws -> [(Double, Double, String)] {
        let samples = try OfflineRunner.readMono48k(url: try OfflinePipelineTests.fixture(name))
        let transcriber = try await Transcriber(configuration: .init())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try await transcriber.prepare(sourceFormat: format)

        let collected = Mutex<[(Double, Double, String)]>([])
        let transcripts = transcriber.transcripts
        let consumer = Task {
            for await transcript in transcripts where transcript.isFinal {
                collected.withLock { $0.append((transcript.start, transcript.end, transcript.text)) }
            }
        }

        let chunk = 512
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            try await transcriber.advance(toStreamSeconds: origin + Double(offset) / 48_000)
            try await transcriber.feed(Array(samples[offset..<(offset + n)]))
            offset += n
            // Paced as the offline runner is, so the decoder keeps up.
            try? await Task.sleep(for: .nanoseconds(chunk * 1_000_000_000 / 48_000 / 8))
        }
        await transcriber.finish()
        _ = await consumer.result
        return collected.withLock { $0 }
    }

    @Test("Transcript times are reported on the shared timeline, even from a negative start")
    func negativeOriginIsTranslated() async throws {
        let origin = -3.0
        let finals = try await Self.finals(from: "two-questions", origin: origin)
        #expect(!finals.isEmpty, "the recogniser produced no finals")
        guard let first = finals.first else { return }
        // Speech in the fixture starts inside its first second, so on a timeline that was
        // already at -3 s when the audio began, the first final starts before zero.
        #expect(first.0 < 0, "first final reported at \(first.0) s; the audio began at \(origin) s")
        let end = origin + 6.8
        #expect(finals.allSatisfy { $0.1 <= end + 0.5 }, "a final ends after the audio does: \(finals.map { $0.1 })")
    }

    @Test("Transcript times are reported on the shared timeline from a late start")
    func positiveOriginIsTranslated() async throws {
        let finals = try await Self.finals(from: "two-questions", origin: 12)
        #expect(!finals.isEmpty, "the recogniser produced no finals")
        guard let first = finals.first else { return }
        #expect(first.0 >= 12, "first final reported at \(first.0) s; the audio began at 12 s")
        #expect(first.0 < 14, "first final reported at \(first.0) s; speech starts within the first second")
    }
}

extension TranscriberTimelineTests {
    /// The stated contract: audio fed before any `advance` sits at zero on the timeline. It
    /// used to be re-based to wherever the first `advance` landed, so a caller that fed first
    /// got results whose times disagreed with later ones for the same audio.
    @Test("Audio fed before any advance sits at zero")
    func feedBeforeAdvanceSitsAtZero() async throws {
        let transcriber = try await Transcriber(configuration: .init())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try await transcriber.prepare(sourceFormat: format)

        try await transcriber.feed([Float](repeating: 0, count: 4_800))   // 0.1 s at 48 kHz
        let filled = try await transcriber.advance(toStreamSeconds: 1.0)
        #expect(abs(filled - 0.9) < 0.05, "filled \(filled) s; the audio should have started at zero")
        let cursor = await transcriber.cursorSeconds
        #expect(abs(cursor - 1.0) < 0.05, "cursor at \(cursor) s")
        await transcriber.finish()
    }
}

/// Whether the microphone's recogniser should be walked forward through silence.
///
/// The mic delivers continuously, so unlike the tap it never stalls — except while muted,
/// when its buffers are discarded. Left alone, the recogniser then stood still for the
/// whole mute and the first buffer after it filled the whole hole in one burst: a ten-minute
/// mute became six hundred buffers of silence queued ahead of the first real word. Pure, so
/// the rule can be asserted without a microphone.
@Suite("Mic idle advance")
struct MicIdleAdvanceTests {
    @Test("Far enough behind the clock, the target is the settled time")
    func advancesWhenBehind() {
        let target = MicSource.idleAdvanceTarget(now: 10, cursor: 9, allowance: 0.06, threshold: 0.025)
        #expect(target.map { abs($0 - 9.94) < 1e-9 } == true, "target was \(String(describing: target))")
    }

    /// Within the threshold the resampler's own small lag is not a hole to fill.
    @Test("A hair behind is left alone")
    func leavesSmallLagAlone() {
        #expect(MicSource.idleAdvanceTarget(now: 10, cursor: 9.93, allowance: 0.06, threshold: 0.025) == nil)
    }

    /// The clock always leads the newest delivered audio; only time the mic has certainly
    /// finished delivering is ever filled.
    @Test("Nothing is filled inside the delivery allowance")
    func respectsTheAllowance() {
        #expect(MicSource.idleAdvanceTarget(now: 10, cursor: 9.97, allowance: 0.06, threshold: 0.025) == nil)
    }

    /// With the call on speakers a mic buffer waits in its ring until the tap has reported on
    /// the same stretch of time. It is audio, not idleness: walked past, it would be fed
    /// behind the recogniser's cursor, and every timestamp after it would sit late by however
    /// long it waited.
    @Test("A buffer waiting in the ring is not silence to be filled")
    func aWaitingBufferIsNotIdleness() {
        #expect(MicSource.idleAdvanceTarget(
            now: 10, cursor: 9, allowance: 0.06, threshold: 0.025, bufferWaiting: true) == nil)
        #expect(MicSource.idleAdvanceTarget(
            now: 10, cursor: 9, allowance: 0.06, threshold: 0.025, bufferWaiting: false) != nil)
    }
}

/// With the call on speakers the mic judges each buffer against what the tap heard at that
/// moment, so a buffer the tap has not yet reported on waits in the ring. Pure, so the rule —
/// and above all that it gives up — can be asserted without a microphone or a tap.
@Suite("Mic waits for the tap")
struct MicWaitsForTheTapTests {
    @Test("A buffer the tap has not reported on yet is left in the ring")
    func waits() {
        #expect(MicSource.shouldWaitForTheTap(segmentEnd: 10.00, knownThrough: 9.98, now: 10.01, limit: 0.3))
    }

    @Test("Once the tap has reported past it, by sound or by silence, it is taken")
    func proceeds() {
        #expect(!MicSource.shouldWaitForTheTap(segmentEnd: 10.00, knownThrough: 10.00, now: 10.01, limit: 0.3))
        #expect(!MicSource.shouldWaitForTheTap(segmentEnd: 10.00, knownThrough: 10.40, now: 10.01, limit: 0.3))
    }

    /// A tap that is rebuilding, or never started, reports nothing. The mic is the half that
    /// still works then, and it must not stop with it.
    @Test("A tap that never reports holds the mic back by the limit and no longer")
    func givesUp() {
        #expect(MicSource.shouldWaitForTheTap(segmentEnd: 10, knownThrough: -.infinity, now: 10.99, limit: 1))
        #expect(!MicSource.shouldWaitForTheTap(segmentEnd: 10, knownThrough: -.infinity, now: 11.0, limit: 1))
        #expect(!MicSource.shouldWaitForTheTap(segmentEnd: 10, knownThrough: 3, now: 60, limit: 1))
    }
}
