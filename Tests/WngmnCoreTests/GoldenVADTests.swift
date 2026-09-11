import Testing
import Foundation
@testable import WngmnCore

/// Golden-file tier: the endpointer run over real recorded speech rather than synthesised
/// square waves. Fast, offline, and needs no audio permission, so it runs in any terminal.
///
/// Fixtures are headerless 16 kHz mono little-endian Int16, produced with `say`. They open
/// and close with silence because a live call does: the tap is already running before the
/// journalist starts, and the hangover has to complete after they stop.
@Suite("Golden VAD")
struct GoldenVADTests {
    static let rate: Double = 16_000

    static func load(_ name: String) throws -> [Float] {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "s16le16k"),
            "fixture \(name) is missing"
        )
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    /// Feeds a fixture in 10 ms chunks, the way live buffers arrive, then lets the hangover
    /// complete against the clock.
    static func run(_ name: String, config: EndpointerConfig = EndpointerConfig()) throws -> [EndpointerEvent] {
        let samples = try load(name)
        var endpointer = Endpointer(config: config)
        var events: [EndpointerEvent] = []
        let chunk = Int(rate / 100)
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            events += endpointer.push(
                Array(samples[offset..<(offset + n)]),
                startTime: Double(offset) / rate,
                sampleRate: rate
            )
            offset += n
        }
        events += endpointer.idle(upTo: Double(samples.count) / rate + 1.0)
        return events
    }

    @Test("One spoken question yields exactly one boundary")
    func oneQuestion() throws {
        let events = try Self.run("one-question")
        let endpoints = events.endpoints
        #expect(endpoints.count == 1, "got \(endpoints.count) boundaries: \(endpoints)")

        let e = try #require(endpoints.first)
        // 0.5 s of leading silence, then ~1.9 s of speech.
        #expect(e.speechStart > 0.35 && e.speechStart < 0.75, "speechStart \(e.speechStart)")
        #expect(e.speechEnd > 2.15 && e.speechEnd < 2.75, "speechEnd \(e.speechEnd)")
        #expect(!e.forced)
    }

    @Test("Two spoken questions separated by a pause yield exactly two boundaries")
    func twoQuestions() throws {
        let events = try Self.run("two-questions")
        let endpoints = events.endpoints
        #expect(endpoints.count == 2, "got \(endpoints.count) boundaries: \(endpoints)")
        guard endpoints.count == 2 else { return }
        // The second question must begin after the first one ended, with the 1.2 s gap intact.
        #expect(endpoints[1].speechStart > endpoints[0].speechEnd + 0.8)
    }

    @Test("Spelled-out letters inside a question do not split it")
    func spelledLettersDoNotSplit() throws {
        // "What is your A R R at Mixstream after the Series A?" — spelling a term out loud
        // puts real gaps mid-question, which is exactly the shape that produces a false
        // boundary if the hangover is too short.
        let events = try Self.run("jargon")
        #expect(events.endpoints.count == 1, "got \(events.endpoints.count): \(events.endpoints)")
    }

    @Test("A mid-question hesitation is stitched back into one question")
    func hesitationIsChained() throws {
        // "So tell me a bit about [530 ms] the funding round you just closed." Synthesised
        // speech is unnaturally fluent — every other fixture survives even a 40 ms hangover —
        // so this is the fixture that actually exercises the boundary. The endpoint still
        // fires fast on the first half; the second half arrives flagged as its continuation.
        let endpoints = try Self.run("hesitation").endpoints
        #expect(endpoints.count == 2, "got \(endpoints.count): \(endpoints)")
        guard endpoints.count == 2 else { return }

        #expect(endpoints[0].continuesPrevious == false)
        #expect(endpoints[1].continuesPrevious, "the second half must be recognised as a continuation")
        #expect(endpoints[1].chainStart == endpoints[0].speechStart)
    }

    @Test("Two genuinely separate questions are not chained together")
    func separateQuestionsAreNotChained() throws {
        // The 1.2 s gap here is more than double the 530 ms hesitation, which is what the
        // merge window is sized to tell apart.
        let endpoints = try Self.run("two-questions").endpoints
        #expect(endpoints.count == 2)
        guard endpoints.count == 2 else { return }
        #expect(endpoints[1].continuesPrevious == false)
        #expect(endpoints[1].chainStart == endpoints[1].speechStart)
    }

    @Test("Raising the hangover past the hesitation removes the split, at a latency cost")
    func hangoverThresholdIsMeasured() throws {
        // Evidence behind the default rather than a preference: 600 ms closes the split
        // outright, but spends 350 ms more of the end-to-end budget on every question to
        // protect the rare one. Revisit after rehearsal with real conversational speech.
        var long = EndpointerConfig()
        long.hangoverMs = 600
        #expect(try Self.run("hesitation", config: long).endpoints.count == 1)
        #expect(try Self.run("two-questions", config: long).endpoints.count == 2)
    }
}
