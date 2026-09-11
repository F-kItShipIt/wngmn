import Testing
@testable import WngmnCore

/// The JSON Lines stream is the contract stage 2 consumes, so its exact shape is asserted.
@Suite("Events")
struct EventsTests {
    let encoder = EventEncoder()

    @Test("Every event type matches the published shape")
    func shapes() {
        #expect(
            encoder.line(.status(state: "capturing", format: StreamFormat(rate: 48000, ch: 1), detail: nil))
                == #"{"type":"status","state":"capturing","format":{"rate":48000,"ch":1}}"#
        )
        #expect(
            encoder.line(.partial(text: "so tell me about the", t: 12.31))
                == #"{"type":"partial","text":"so tell me about the","t":12.31}"#
        )
        #expect(
            encoder.line(.question(text: "So tell me about the funding round.", t0: 10.88, t1: 13.02, ms: 74))
                == #"{"type":"question","text":"So tell me about the funding round.","t0":10.88,"t1":13.02,"ms":74}"#
        )
        #expect(
            encoder.line(.warning(code: "no_audio", detail: "no buffers for 5s; rebuilding tap"))
                == #"{"type":"warning","code":"no_audio","detail":"no buffers for 5s; rebuilding tap"}"#
        )
    }

    /// Speaker is carried only when there is more than one source. With the mic off the
    /// line must stay byte-identical to the shape stage 2 already consumes.
    @Test("Speaker is absent from a single-source line")
    func speakerOmittedWhenUnset() {
        #expect(
            encoder.line(.question(text: "Hello.", t0: 1, t1: 2, ms: 9))
                == #"{"type":"question","text":"Hello.","t0":1,"t1":2,"ms":9}"#
        )
        #expect(
            encoder.line(.partial(text: "hel", t: 1))
                == #"{"type":"partial","text":"hel","t":1}"#
        )
    }

    @Test("Speaker is carried on both question and partial when set")
    func speakerCarried() {
        #expect(
            encoder.line(.question(text: "Hello.", t0: 1, t1: 2, ms: 9, speaker: .you))
                == #"{"type":"question","text":"Hello.","t0":1,"t1":2,"ms":9,"speaker":"you"}"#
        )
        #expect(
            encoder.line(.question(text: "Hello.", t0: 1, t1: 2, ms: 9, speaker: .caller))
                == #"{"type":"question","text":"Hello.","t0":1,"t1":2,"ms":9,"speaker":"caller"}"#
        )
        #expect(
            encoder.line(.partial(text: "hel", t: 1, speaker: .you))
                == #"{"type":"partial","text":"hel","t":1,"speaker":"you"}"#
        )
    }

    /// Speaker goes last so every key that stage 2 already reads keeps its position.
    @Test("Speaker follows the existing flags rather than displacing them")
    func speakerIsLast() {
        #expect(
            encoder.line(.question(
                text: "Hi.", t0: 1, t1: 2, ms: 9,
                revises: true, usedVolatile: true, speaker: .caller))
                == #"{"type":"question","text":"Hi.","t0":1,"t1":2,"ms":9,"revises":true,"volatile":true,"speaker":"caller"}"#
        )
    }

    @Test("Lines never contain an embedded newline")
    func singleLine() {
        let line = encoder.line(.question(text: "First line.\nSecond line.", t0: 0, t1: 1, ms: 5))
        #expect(!line.contains("\n"))
    }

    @Test("Timestamps are trimmed to milliseconds so golden files stay stable")
    func timestampPrecision() {
        let line = encoder.line(.partial(text: "x", t: 1.23456789))
        #expect(line.contains(#""t":1.235"#))
    }

    @Test("Slashes are not escaped, so URLs and paths stay readable")
    func noSlashEscaping() {
        let line = encoder.line(.warning(code: "device", detail: "/dev/null"))
        #expect(line.contains("/dev/null"))
    }
}

@Suite("Question revisions")
struct QuestionRevisionTests {
    let encoder = EventEncoder()

    @Test("A plain question carries no revises key")
    func revisesOmittedWhenFalse() {
        let line = encoder.line(.question(text: "Why now?", t0: 1, t1: 2, ms: 70))
        #expect(!line.contains("revises"))
    }

    @Test("A plain question carries no volatile key")
    func volatileOmittedWhenFalse() {
        let line = encoder.line(.question(text: "Why now?", t0: 1, t1: 2, ms: 70))
        #expect(!line.contains("volatile"))
    }

    @Test("A question rescued from the volatile stream says so on the wire")
    func volatileEmittedWhenTrue() {
        let line = encoder.line(
            .question(text: "Why now?", t0: 1, t1: 2, ms: 70, usedVolatile: true))
        #expect(line == #"{"type":"question","text":"Why now?","t0":1,"t1":2,"ms":70,"volatile":true}"#)
    }

    @Test("A continuation is marked so stage 2 can replace rather than append")
    func revisesEmittedWhenTrue() {
        let line = encoder.line(.question(text: "Why now, really?", t0: 1, t1: 3, ms: 70, revises: true))
        #expect(line == #"{"type":"question","text":"Why now, really?","t0":1,"t1":3,"ms":70,"revises":true}"#)
    }
}

/// Which events belong in the replay buffer a late or reconnecting page is caught up from.
///
/// The distinction is not cosmetic. A partial is a snapshot of a sentence still being
/// spoken, superseded by the next one a fraction of a second later; they arrive several
/// times a second, and remembering them fills a bounded buffer with data that was obsolete
/// on arrival and evicts the questions — which is exactly what a reconnecting phone then
/// fails to be told about.
@Suite("Replayable events")
struct ReplayableEventTests {
    @Test("Speech in progress is not worth remembering")
    func partialsAreNotReplayable() {
        #expect(Event.partial(text: "how would you", t: 1).isReplayable == false)
    }

    @Test("Everything a late page has to be caught up on is")
    func durableEventsAreReplayable() {
        #expect(Event.question(
            text: "Design a rate limiter.", t0: 1, t1: 2, ms: 400,
            revises: false, usedVolatile: false, speaker: nil
        ).isReplayable)
        #expect(Event.status(state: "capturing", format: nil, detail: nil).isReplayable)
        #expect(Event.warning(code: "capture_gap", detail: "3s").isReplayable)
        #expect(Event.error(code: "fatal", detail: "boom").isReplayable)
    }

    /// Latency samples redraw a chart from the questions themselves, so replaying them adds
    /// nothing a late page cannot already compute — and there is one per question.
    @Test("Metrics are not")
    func metricsAreNotReplayable() {
        #expect(Event.metric(name: "endpoint_ms", value: 412, unit: "ms").isReplayable == false)
    }
}
