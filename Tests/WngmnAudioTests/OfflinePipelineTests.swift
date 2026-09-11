import Testing
import Foundation
import Synchronization
@testable import WngmnAudio
@testable import WngmnCore

/// Golden-file tier: real recorded speech through the real endpointer, resampler, analyser
/// and assembler. Needs no system-audio permission — only the tap does — so this runs in any
/// terminal, which is what keeps ordinary development off the TCC critical path.
@Suite("Offline pipeline", .serialized)
struct OfflinePipelineTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "wav"),
            "fixture \(name).wav is missing"
        )
    }

    /// Runs a fixture and returns everything the pipeline emitted.
    static func run(
        _ name: String,
        speed: Double = 8,
        terms: TermList = .empty,
        configure: (inout EndpointerConfig) -> Void = { _ in }
    ) async throws -> [Event] {
        let collected = Mutex<[Event]>([])
        let writer = EventWriter(sink: { event in collected.withLock { $0.append(event) } })

        var endpointer = EndpointerConfig()
        configure(&endpointer)
        let runner = OfflineRunner(
            configuration: OfflineRunner.Configuration(
                transcriber: Transcriber.Configuration(),
                endpointer: endpointer,
                terms: terms,
                emitPartials: false,
                speed: speed
            ),
            writer: writer
        )
        try await runner.run(url: try fixture(name))
        return collected.withLock { $0 }
    }

    @Test("Two spoken questions come out as two questions with the right words")
    func twoQuestions() async throws {
        let events = try await Self.run("two-questions")
        let questions = events.questions
        #expect(questions.count == 2, "got \(questions.map(\.text))")
        guard questions.count == 2 else { return }

        #expect(questions[0].text == "So tell me about the funding round.")
        #expect(questions[1].text == "And what is next for the company?")
        // Forced finalisation returns lower-case mid-conversation; the wngmn shows these
        // to a person, so the first letter is fixed.
        #expect(questions[1].text.first == "A")
        #expect(questions.allSatisfy { !$0.revises })
    }

    @Test("Endpoint-to-final latency stays well inside the budget")
    func latency() async throws {
        // The design's whole justification for forcing finalisation is that waiting for the
        // framework's own isFinal costs 857-921 ms. This asserts the win is real.
        let events = try await Self.run("two-questions")
        let questions = events.questions
        #expect(!questions.isEmpty)
        for question in questions {
            #expect(question.ms < 400, "endpoint→final took \(question.ms) ms")
        }
    }

    @Test("A mid-question hesitation is recovered as a revised question")
    func hesitationRecovered() async throws {
        // Two things are being checked at once, and both were real bugs. The endpointer
        // splits a 530 ms hesitation, and the recogniser then returns *punctuation only*
        // for the second region — so without the volatile fallback the second half of the
        // question is lost outright rather than merely mis-segmented.
        let events = try await Self.run("hesitation")
        let questions = events.questions
        #expect(questions.count == 2, "got \(questions.map(\.text))")
        guard questions.count == 2 else { return }

        #expect(questions[0].text == "So tell me a bit about.")
        #expect(questions[1].revises, "the second half must supersede the first, not follow it")
        #expect(questions[1].text == "So tell me a bit about the funding round you just closed.")
        #expect(questions[1].t0 == questions[0].t0, "the revision spans from the original start")
        // The seam is repaired: no full stop left in the middle of the sentence.
        #expect(!questions[1].text.contains("about. the"))
        #expect(!questions[1].text.contains("about. The"))
    }

    @Test("Raising the hangover past the hesitation avoids the split entirely")
    func longHangoverAvoidsSplit() async throws {
        // The other half of the trade-off, measured rather than asserted: 600 ms produces
        // one clean question and needs no fallback, at the cost of 350 ms on every question.
        let events = try await Self.run("hesitation") { $0.hangoverMs = 600 }
        let questions = events.questions
        #expect(questions.count == 1, "got \(questions.map(\.text))")
        #expect(questions.first?.text == "So tell me a bit about the funding round you just closed.")
        #expect(!events.contains { if case .warning(let code, _) = $0 { return code == "volatile_fallback" } else { return false } })
    }

    @Test("The term list repairs jargon the recogniser gets wrong")
    func jargonRepair() async throws {
        let terms = TermList(text: """
        Mixstream | mix stream | mixed stream
        Series A | series 8
        """)
        let plain = try await Self.run("jargon").questions
        let repaired = try await Self.run("jargon", terms: terms).questions

        #expect(plain.count == 1)
        #expect(repaired.count == 1)
        guard let before = plain.first?.text, let after = repaired.first?.text else { return }
        // The recogniser reliably splits "Mixstream" into two words; only an alias reaches it.
        #expect(before.contains("mixed stream"))
        #expect(after.contains("Mixstream"))
        #expect(!after.contains("mixed stream"))
    }

    @Test("The emitted stream is well-formed JSON Lines")
    func wellFormedOutput() async throws {
        let encoder = EventEncoder()
        for event in try await Self.run("two-questions") {
            let line = encoder.line(event)
            #expect(!line.contains("\n"))
            let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let object = try #require(parsed as? [String: Any])
            #expect(object["type"] is String)
        }
    }
}

/// The continuation window, through the real endpointer, resampler and assembler.
///
/// The `hesitation` fixture is a question with a 530 ms pause in the middle of it — the
/// case the window exists for. Whether the two halves come back as one stitched question or
/// two separate ones is entirely a function of this setting, which is why the microphone
/// needs its own: consecutive sentences of your own are not one sentence with a pause in it.
@Suite("Continuation window", .serialized)
struct ContinuationWindowTests {
    @Test("A window wider than the pause stitches the halves into one line")
    func widerWindowStitches() async throws {
        let questions = try await OfflinePipelineTests.run("hesitation") { $0.mergeWindowMs = 700 }
            .questions
        #expect(questions.contains { $0.revises }, "expected a stitched revision, got \(questions.map(\.text))")
    }

    /// Narrower than the pause, so the second half is its own utterance rather than a
    /// rewrite of the first — which is what stops your sentences overwriting each other.
    @Test("A window narrower than the pause keeps them separate")
    func narrowerWindowSeparates() async throws {
        let questions = try await OfflinePipelineTests.run("hesitation") { $0.mergeWindowMs = 250 }
            .questions
        #expect(!questions.contains { $0.revises }, "expected no stitching, got \(questions.map(\.text))")
        #expect(questions.count >= 2, "expected separate lines, got \(questions.map(\.text))")
    }
}

/// Whether a pause inside a sentence ends it.
///
/// `hesitation` is one question with a 530 ms pause in the middle — the length people
/// routinely pause for mid-thought. At the tap's 250 ms hangover the endpoint fires during
/// that pause and the sentence arrives in two halves; waiting longer means it never fires
/// and the sentence stays whole, which is why the microphone can afford a hangover the tap
/// cannot: nobody reads their own words back off the screen.
@Suite("Hangover and mid-sentence pauses", .serialized)
struct HangoverPauseTests {
    @Test("A short hangover splits the sentence at the pause")
    func shortHangoverSplits() async throws {
        let questions = try await OfflinePipelineTests.run("hesitation") {
            $0.hangoverMs = 250
            $0.mergeWindowMs = 250   // stitching off, so the split is visible
        }.questions
        #expect(questions.count >= 2, "expected a split, got \(questions.map(\.text))")
    }

    /// Longer than the pause, so it is never treated as the end of anything.
    @Test("A hangover longer than the pause keeps the sentence whole")
    func longHangoverKeepsItWhole() async throws {
        let questions = try await OfflinePipelineTests.run("hesitation") {
            $0.hangoverMs = 800
            $0.mergeWindowMs = 250
        }.questions
        #expect(questions.count == 1, "expected one line, got \(questions.map(\.text))")
        #expect(questions.first?.text.contains("funding round") == true,
                "the second half should be in the same line: \(questions.map(\.text))")
    }
}

extension Array where Element == Event {
    var questions: [
        (text: String, t0: Double, t1: Double, ms: Int, revises: Bool, usedVolatile: Bool,
         speaker: Speaker?)
    ] {
        compactMap {
            if case let .question(text, t0, t1, ms, revises, usedVolatile, speaker) = $0 {
                return (text, t0, t1, ms, revises, usedVolatile, speaker)
            }
            return nil
        }
    }
}
