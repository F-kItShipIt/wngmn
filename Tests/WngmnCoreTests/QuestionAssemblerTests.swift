import Testing
@testable import WngmnCore

@Suite("QuestionAssembler")
struct QuestionAssemblerTests {
    private func endpoint(
        _ start: Double, _ end: Double, decision: Double? = nil,
        continues: Bool = false, chainStart: Double? = nil
    ) -> Endpoint {
        Endpoint(
            speechStart: start, speechEnd: end, decisionTime: decision ?? (end + 0.25),
            forced: false, continuesPrevious: continues, chainStart: chainStart
        )
    }

    @Test("A final covering the endpoint emits the question")
    func basicQuestion() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 100.0)
        let out = a.finalArrived(start: 1.0, end: 3.1, text: "So tell me about the round.", now: 100.07)

        #expect(out.count == 1)
        let q = try! #require(out.first)
        #expect(q.text == "So tell me about the round.")
        #expect(q.t0 == 1.0)
        #expect(q.t1 == 3.0)
        #expect(q.latencyMilliseconds == 70)
        #expect(!q.revises)
        #expect(!q.timedOut)
    }

    @Test("A final that stops short of the endpoint does not emit yet")
    func partialCoverageWaits() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 5.0), now: 100.0)
        #expect(a.finalArrived(start: 1.0, end: 2.0, text: "So tell me", now: 100.05).isEmpty)
        #expect(a.hasPendingQuestion)

        let out = a.finalArrived(start: 2.0, end: 5.05, text: "about the round.", now: 100.08)
        #expect(out.count == 1)
        // Both fragments belong to the question.
        #expect(out[0].text == "So tell me about the round.")
    }

    @Test("Forced-finalisation punctuation artifacts are stripped")
    func normalisesArtifacts() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 10)
        let out = a.finalArrived(start: 1.0, end: 3.1, text: #",... And what is next?"#, now: 10.07)
        #expect(out.first?.text == "And what is next?")
    }

    @Test("Jargon is repaired using the term list")
    func repairsJargon() {
        var a = QuestionAssembler(terms: TermList(text: "ARR | the air"))
        a.endpointDetected(endpoint(1.0, 3.0), now: 10)
        let out = a.finalArrived(start: 1.0, end: 3.1, text: "what is the air now?", now: 10.07)
        // normalizeFinal also fixes the sentence-initial capital a forced final drops.
        #expect(out.first?.text == "What is ARR now?")
    }

    @Test("A continuation re-emits the whole question and marks it as a revision")
    func continuationRevises() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 2.0), now: 10)
        let first = a.finalArrived(start: 1.0, end: 2.1, text: "So tell me a bit about", now: 10.07)
        #expect(first.count == 1)
        #expect(!first[0].revises)

        a.endpointDetected(endpoint(2.6, 4.0, continues: true, chainStart: 1.0), now: 12)
        let second = a.finalArrived(start: 2.6, end: 4.1, text: "the funding round.", now: 12.07)
        #expect(second.count == 1)
        #expect(second[0].revises)
        #expect(second[0].text == "So tell me a bit about the funding round.")
        #expect(second[0].t0 == 1.0, "the revision must span from the original start")
        #expect(second[0].t1 == 4.0)
    }

    @Test("Two separate questions do not bleed into each other")
    func separateQuestionsStaySeparate() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 2.0), now: 10)
        let first = a.finalArrived(start: 1.0, end: 2.1, text: "Why now?", now: 10.07)
        #expect(first.first?.text == "Why now?")

        a.endpointDetected(endpoint(4.0, 5.0), now: 13)
        let second = a.finalArrived(start: 4.0, end: 5.1, text: "And why you?", now: 13.07)
        #expect(second.first?.text == "And why you?")
        #expect(second.first?.revises == false)
    }

    @Test("A question whose final never arrives is emitted on a timeout, not lost")
    func timeoutEmits() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 100)
        _ = a.finalArrived(start: 1.0, end: 1.5, text: "So tell me", now: 100.05)
        #expect(a.tick(now: 101.0).isEmpty, "not yet past the timeout")

        let out = a.tick(now: 103.0)
        #expect(out.count == 1)
        #expect(out[0].timedOut)
        #expect(out[0].text == "So tell me")
        #expect(!a.hasPendingQuestion)
    }

    @Test("A question with no text at all is dropped rather than emitted empty")
    func emptyQuestionDropped() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 10)
        #expect(a.finalArrived(start: 1.0, end: 3.1, text: "  ,... ", now: 10.07).isEmpty)
        #expect(!a.hasPendingQuestion, "the pending question is consumed even when it yields no text")
    }

    @Test("Endpoints covered by one blob of final text drain without duplicating it")
    func queuedEndpoints() {
        // Two endpoints fire, then the recogniser returns a single final spanning both.
        // The first question claims the text; the second must be drained rather than left
        // pending, and must not re-emit the same words.
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 2.0), now: 10)
        a.endpointDetected(endpoint(3.0, 4.0), now: 12)
        let out = a.finalArrived(start: 1.0, end: 4.1, text: "Why now? And why you?", now: 12.07)

        #expect(out.count == 1)
        #expect(out[0].text == "Why now? And why you?")
        #expect(!a.hasPendingQuestion, "both endpoints must be drained, not left to time out")
    }

    @Test("Latency is never reported as negative")
    func nonNegativeLatency() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 100)
        let out = a.finalArrived(start: 1.0, end: 3.1, text: "Hello.", now: 99.9)
        #expect(out.first?.latencyMilliseconds == 0)
    }
}

@Suite("Dropped questions")
struct DroppedQuestionTests {
    private func endpoint(_ start: Double, _ end: Double) -> Endpoint {
        Endpoint(speechStart: start, speechEnd: end, decisionTime: end + 0.25)
    }

    @Test("A boundary that produces no text is reported, not silently discarded")
    func dropIsReported() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 10)
        #expect(a.finalArrived(start: 1.0, end: 3.1, text: ",...", now: 10.07).isEmpty)

        let dropped = a.takeDropped()
        #expect(dropped.count == 1)
        #expect(dropped[0].endpoint.speechStart == 1.0)
        #expect(dropped[0].hadTranscript, "a gutted final did arrive, so this is a real loss")
        #expect(a.takeDropped().isEmpty, "draining must clear the list")
    }

    @Test("A dropped question does not become the target of a later revision")
    func dropClearsTheChain() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 2.0), now: 10)
        #expect(a.finalArrived(start: 1.0, end: 2.1, text: "A real question?", now: 10.05).count == 1)

        // A boundary in between that yields nothing.
        a.endpointDetected(endpoint(3.0, 4.0), now: 12)
        #expect(a.finalArrived(start: 3.0, end: 4.1, text: " ... ", now: 12.05).isEmpty)

        // A later continuation must not be glued onto the question from before the gap.
        let continuation = Endpoint(
            speechStart: 5.0, speechEnd: 6.0, decisionTime: 6.25,
            continuesPrevious: true, chainStart: 3.0
        )
        a.endpointDetected(continuation, now: 14)
        let out = a.finalArrived(start: 5.0, end: 6.1, text: "and then what?", now: 14.05)
        #expect(out.count == 1)
        #expect(out[0].text == "And then what?")
        #expect(!out[0].revises, "there is nothing on screen to revise")
    }
}

@Suite("Volatile fallback")
struct VolatileFallbackTests {
    private func endpoint(_ start: Double, _ end: Double) -> Endpoint {
        Endpoint(speechStart: start, speechEnd: end, decisionTime: end + 0.25)
    }

    @Test("Content loss is detected, not just an empty final")
    func detectsContentLoss() {
        // Both shapes are produced by forcing finalisation of a region that begins shortly
        // after a previous forced boundary.
        #expect(QuestionAssembler.lostMostOfItsContent(final: ",.....", volatile: "The funding round."))
        #expect(QuestionAssembler.lostMostOfItsContent(final: "What..........", volatile: "What really matters a great deal here."))
        // An ordinary final differs from its volatile by a word or two, never by half.
        #expect(!QuestionAssembler.lostMostOfItsContent(final: "So tell me about the round.", volatile: "So tell me about the round"))
        #expect(!QuestionAssembler.lostMostOfItsContent(final: "Why now?", volatile: "Why now"))
        #expect(!QuestionAssembler.lostMostOfItsContent(final: "anything", volatile: ""))
    }

    @Test("A final that dropped a leading word is recognised as lossy")
    func detectsDroppedLeadingWord() {
        // Measured on a live Meet call: the volatile stream had the whole question, the
        // forced final came back without its first word. Only 3 letters of 31 went missing,
        // so the bulk-loss rule cannot see it.
        #expect(QuestionAssembler.finalIsSubrangeOfVolatile(
            final: "You able to listen to me properly?",
            volatile: "Are you able to listen to me properly?"))
    }

    @Test("A final that merely reworded the volatile is not treated as lossy")
    func rewordingIsNotLoss() {
        #expect(!QuestionAssembler.finalIsSubrangeOfVolatile(
            final: "How big is the team?", volatile: "How big is your team"))
        // Identical content is not loss either, punctuation and case aside.
        #expect(!QuestionAssembler.finalIsSubrangeOfVolatile(
            final: "Why now?", volatile: "why now"))
    }

    @Test("A final that dropped a leading word is replaced by the volatile text")
    func recoversDroppedLeadingWord() {
        var a = QuestionAssembler()
        a.endpointDetected(
            Endpoint(speechStart: 27.19, speechEnd: 29.26, decisionTime: 29.51), now: 100)
        a.volatileArrived(start: 27.19, end: 29.3, text: "Are you able to listen to me properly?")
        let out = a.finalArrived(
            start: 27.19, end: 29.3, text: "You able to listen to me properly?", now: 100.094)

        #expect(out.count == 1)
        #expect(out[0].text == "Are you able to listen to me properly?")
        #expect(out[0].usedVolatileFallback)
    }

    @Test("A final that replaced a phrase with a punctuation run is lossy")
    func detectsPunctuationRun() {
        // Measured: the volatile had the whole clause, the forced final swapped the first
        // six words for a run of full stops. It keeps 29 letters against the volatile's 52,
        // so the bulk rule clears it, and it inserts "that", so it is not a subrange either.
        #expect(QuestionAssembler.finalLostContent(
            final: "that.......... such that they add up to Target",
            volatile: "Return the indices of the 2 numbers such that they add up to Target"))
    }

    @Test("Ordinary sentence punctuation is not mistaken for a dropped phrase")
    func ordinaryPunctuationSurvives() {
        #expect(!QuestionAssembler.finalLostContent(
            final: "So, tell me... why now?", volatile: "So tell me why now"))
        #expect(!QuestionAssembler.finalLostContent(
            final: "How big is the team?", volatile: "How big is the team"))
    }

    @Test("A volatile survives until its own final arrives, not just until the next one")
    func keepsVolatilePerRegion() {
        // A long question finalises in several regions. With a single volatile slot the
        // second region's volatile overwrites the first, and by the time the first
        // region's gutted final lands there is nothing left to rescue it with.
        var a = QuestionAssembler()
        a.endpointDetected(
            Endpoint(speechStart: 1.0, speechEnd: 8.0, decisionTime: 8.25), now: 100)
        a.volatileArrived(start: 1.0, end: 4.0, text: "Return the indices of the two numbers")
        a.volatileArrived(start: 4.0, end: 8.0, text: "such that they add up to target")

        _ = a.finalArrived(start: 1.0, end: 4.0, text: "that..........", now: 100.05)
        let out = a.finalArrived(
            start: 4.0, end: 8.0, text: "such that they add up to target.", now: 100.09)

        #expect(out.count == 1)
        #expect(out[0].text == "Return the indices of the two numbers such that they add up to target.")
        #expect(out[0].usedVolatileFallback)
    }

    @Test("A gutted final is replaced by the volatile text for the same range")
    func substitutesWholeRegion() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(1.0, 3.0), now: 10)
        a.volatileArrived(start: 1.0, end: 3.1, text: "the funding round you just closed")
        let out = a.finalArrived(start: 1.0, end: 3.1, text: ",.....", now: 10.07)

        #expect(out.count == 1)
        #expect(out[0].text == "The funding round you just closed")
        #expect(out[0].usedVolatileFallback)
    }

    /// The bug behind "recognised, then lost": a boundary whose forced final never lands
    /// still has its volatile text — the words the caption was showing. build() read only
    /// finalised segments, so it dropped the endpoint as "no usable text" with the answer
    /// sitting in `volatiles`. Measured live: endpoint 77.36-79.72 dropped while its
    /// volatile "Testing, 123" was retained.
    @Test("A timed-out boundary falls back to its retained volatile instead of dropping")
    func timeoutFallsBackToVolatile() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(77.36, 79.72), now: 100)
        a.volatileArrived(start: 77.4, end: 80.21, text: "Testing, 123")
        // No final ever lands for this span.
        let out = a.tick(now: 103)
        #expect(out.count == 1)
        #expect(out.first?.text == "Testing, 123")
        #expect(out.first?.usedVolatileFallback == true)
        #expect(out.first?.timedOut == true)
        #expect(a.takeDropped().isEmpty, "the volatile was usable, so nothing was dropped")
    }

    /// The coverage path has the same hole, plus a second: a later utterance's final purged
    /// the stale endpoint's volatile before build() ran for it, so even the fallback had
    /// nothing. The purge must spare a volatile that still belongs to a pending endpoint.
    @Test("A later final does not purge a pending endpoint's volatile out from under it")
    func laterFinalSparesPendingVolatile() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(77.36, 79.72), now: 100)
        a.volatileArrived(start: 77.4, end: 80.21, text: "Testing, 123")
        // A later utterance finalises cleanly; its coverage triggers the pending build.
        let out = a.finalArrived(start: 84.9, end: 85.6, text: "Next sentence.", now: 101)
        let stale = out.first { $0.text.contains("Testing") }
        #expect(stale != nil, "the earlier endpoint should surface with its volatile text")
        #expect(stale?.usedVolatileFallback == true)
        #expect(a.takeDropped().isEmpty)
    }

    /// A boundary the recogniser produced nothing at all for — no final, no volatile — is
    /// still dropped, but flagged as no-transcript so the mic can report it quietly rather
    /// than as a lost question. This is the common case on your own mic: typing, a cough.
    @Test("A boundary with no transcript at all is flagged as no-transcript")
    func silentDropIsFlagged() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(10.0, 12.0), now: 100)
        let out = a.tick(now: 103)
        #expect(out.isEmpty)
        let dropped = a.takeDropped()
        #expect(dropped.count == 1)
        #expect(dropped[0].hadTranscript == false, "nothing was ever recognised for this span")
    }

    @Test("Volatile text from an unrelated range is never substituted")
    func rangeMustMatch() {
        var a = QuestionAssembler()
        a.endpointDetected(endpoint(5.0, 7.0), now: 10)
        // Volatile from a much earlier region.
        a.volatileArrived(start: 0.0, end: 1.0, text: "something completely different")
        #expect(a.finalArrived(start: 5.0, end: 7.1, text: ",...", now: 10.07).isEmpty)
        #expect(a.takeDropped().count == 1)
    }
}
