import Foundation

/// Turns endpoints and finalised transcript fragments into questions.
///
/// This is the join between the two halves of the design and the fiddliest part of it: the
/// endpointer decides *when* a question ended from the audio, and the recogniser says *what*
/// was said, and the two arrive independently. Keeping it here — pure, with an injected
/// clock — means it can be tested without a microphone, a permission, or a real analyser.
///
/// Question text is built **only** from finalised results. Reconstructing it by slicing
/// volatile text against a committed prefix garbles the output, because the volatile and
/// final strings genuinely differ.
public struct QuestionAssembler: Sendable {
    public struct Question: Sendable, Equatable {
        public let text: String
        public let t0: Double
        public let t1: Double
        /// Latency from the endpoint to the final that satisfied it.
        public let latencyMilliseconds: Int
        /// This question supersedes the one before it: the journalist paused mid-question
        /// and then carried on.
        public let revises: Bool
        /// Emitted on a timeout rather than on a matching final.
        public let timedOut: Bool
        /// At least one region's text came from the volatile stream because its final was
        /// empty. Worth surfacing: it means the recogniser dropped a forced region.
        public let usedVolatileFallback: Bool
    }

    /// How close a final's end must come to the endpoint before the question is considered
    /// covered. Finals are forced by us, so one lands just past the boundary.
    public var coverageTolerance: Double = 0.15
    /// Finals starting within this much of the decision time belong to the question.
    public var claimTolerance: Double = 0.25
    /// A pending question with no matching final after this long is emitted anyway, with
    /// whatever text exists. Losing the question entirely is the worse failure.
    public var finalTimeout: Double = 2.5
    /// How closely a volatile result's range must match a final's before its text may stand
    /// in for an empty final.
    public var volatileMatchTolerance: Double = 0.25
    /// Upper bound on unclaimed finalised fragments.
    ///
    /// Every fragment is normally claimed by the question whose endpoint follows it. If
    /// endpoints stop arriving — the VAD goes quiet while the recogniser keeps producing —
    /// these would otherwise accumulate for the length of the interview, and the oldest of
    /// them would eventually be prepended to a question they have nothing to do with.
    public var maximumHeldSegments: Int = 200
    /// Upper bound on retained volatile regions. A long question finalises in a handful;
    /// older entries are stale and would only risk matching a later final by coincidence.
    public var maximumHeldVolatiles: Int = 12

    private struct Pending {
        let endpoint: Endpoint
        let requestedAt: Double
    }

    private struct Segment {
        let start: Double
        let end: Double
        let text: String
        var fromVolatile = false
    }

    /// A boundary that closed but produced no question, and why.
    public struct DroppedEndpoint: Sendable, Equatable {
        public let endpoint: Endpoint
        /// A transcript did arrive for the span but normalised to nothing usable (pure
        /// punctuation or artifacts) — a genuine loss. `false` means the recogniser
        /// produced no text at all, usually non-speech the gate opened on.
        public let hadTranscript: Bool
    }

    private var pending: [Pending] = []
    private var segments: [Segment] = []
    /// High-water mark of finalised audio. Tracked separately from `segments`, which is
    /// emptied as questions claim it — otherwise a second endpoint covered by the same
    /// final would look uncovered and sit pending until it timed out.
    private var coveredThrough: Double = 0
    private var lastText = ""
    private var lastStart: Double = 0
    /// One retained volatile per region, not one in total.
    ///
    /// A long question finalises in several regions, and the volatile stream re-emits a
    /// growing string for each of them many times a second. With a single slot, region
    /// two's volatile overwrites region one's, so when region one's gutted final arrives
    /// there is nothing left to rescue it with — measured on a seven-second question, where
    /// six words were replaced by a run of full stops that reached the user verbatim.
    private var volatiles: [Segment] = []
    private var dropped: [DroppedEndpoint] = []
    /// Settable so a reloaded profile reaches jargon repair without rebuilding the
    /// assembler, which would discard the questions it is holding mid-utterance.
    public var terms: TermList

    public init(terms: TermList = .empty) {
        self.terms = terms
    }

    public var hasPendingQuestion: Bool { !pending.isEmpty }

    /// Boundaries that were satisfied but produced no usable text, since the last call.
    ///
    /// Each carries whether a transcript arrived at all (`hadTranscript`). One that did and
    /// still normalised to nothing is a genuine loss worth a warning; one that never
    /// produced a word is usually the gate opening on non-speech — on your own mic, typing
    /// or a cough — and the caller of this decides how loudly to say so.
    public mutating func takeDropped() -> [DroppedEndpoint] {
        defer { dropped.removeAll() }
        return dropped
    }

    /// The endpointer decided a question ended. `now` is monotonic seconds, used only to
    /// measure the latency that gets reported on the question.
    public mutating func endpointDetected(_ endpoint: Endpoint, now: Double) {
        pending.append(Pending(endpoint: endpoint, requestedAt: now))
    }

    /// A volatile (non-final) transcript update arrived.
    ///
    /// Kept only as a fallback. Forcing finalisation of a region that begins shortly after a
    /// previous forced boundary — which is exactly what a mid-question hesitation produces —
    /// makes the recogniser return a final containing nothing but punctuation, even though
    /// its volatile output for the identical range was correct. Measured repeatedly on a
    /// 530 ms hesitation: `[2.10, 4.34] "The funding round you just closed."` volatile,
    /// `[2.10, 4.34] ",....."` final. Without this the second half of the question is lost
    /// outright, which is far worse than transcribing it slightly less accurately.
    ///
    /// This is *not* the rejected technique of slicing volatile text against a committed
    /// prefix. Whole regions are substituted, never spliced, so volatile and final strings
    /// are never mixed inside one span.
    public mutating func volatileArrived(start: Double, end: Double, text: String) {
        guard !TextNormalizer.stripArtifacts(text).isEmpty else { return }
        let segment = Segment(start: start, end: end, text: text, fromVolatile: true)
        // Replace in place rather than append: the stream re-emits the same region as it
        // grows, and keeping every revision would flush the history within one sentence —
        // which is the single-slot bug again, just with more steps.
        if let i = volatiles.firstIndex(where: { abs($0.start - start) <= volatileMatchTolerance }) {
            volatiles[i] = segment
        } else {
            volatiles.append(segment)
        }
        if volatiles.count > maximumHeldVolatiles {
            volatiles.removeFirst(volatiles.count - maximumHeldVolatiles)
        }
    }

    /// The retained volatile whose range matches this final most closely, if any.
    private func bestVolatile(start: Double, end: Double) -> Segment? {
        func distance(_ s: Segment) -> Double { abs(s.start - start) + abs(s.end - end) }
        return volatiles
            .filter {
                abs($0.start - start) <= volatileMatchTolerance
                    && abs($0.end - end) <= volatileMatchTolerance
            }
            .min { distance($0) < distance($1) }
    }

    /// A finalised transcript fragment arrived.
    public mutating func finalArrived(
        start: Double, end: Double, text: String, now: Double
    ) -> [Question] {
        var segment = Segment(start: start, end: end, text: text)
        if let candidate = bestVolatile(start: start, end: end),
           Self.finalLostContent(final: text, volatile: candidate.text) {
            segment = Segment(start: start, end: end, text: candidate.text, fromVolatile: true)
        }
        // Everything this final covers is now decided. Holding volatiles longer would only
        // risk one matching a later final by coincidence — except a volatile that still
        // belongs to a *pending* endpoint, whose own forced final may never land: build()
        // needs it as the fallback, and this same final's coverage is about to trigger that
        // build below. Spare exactly those.
        volatiles.removeAll { v in
            guard v.end <= end + volatileMatchTolerance else { return false }
            let neededByPending = pending.contains { p in
                v.start < p.endpoint.decisionTime + claimTolerance
                    && v.end > p.endpoint.speechStart - claimTolerance
            }
            return !neededByPending
        }
        segments.append(segment)
        if segments.count > maximumHeldSegments {
            segments.removeFirst(segments.count - maximumHeldSegments)
        }
        coveredThrough = max(coveredThrough, end)
        var emitted: [Question] = []
        while let next = pending.first {
            guard coveredThrough >= next.endpoint.speechEnd - coverageTolerance else { break }
            pending.removeFirst()
            if let question = build(next, now: now, timedOut: false) { emitted.append(question) }
        }
        return emitted
    }

    /// Emits any pending question whose final never arrived.
    public mutating func tick(now: Double) -> [Question] {
        var emitted: [Question] = []
        while let next = pending.first, now - next.requestedAt > finalTimeout {
            pending.removeFirst()
            if let question = build(next, now: now, timedOut: true) { emitted.append(question) }
        }
        return emitted
    }

    /// True when a forced final has clearly dropped what the recogniser had already heard.
    ///
    /// The empty case is the common one — a final of `",....."` against a correct volatile —
    /// but the same failure also produces a final that keeps one word and returns the rest as
    /// punctuation (`"What.........."`). Comparing letter counts catches both without
    /// second-guessing a final that merely worded something differently: an ordinary final
    /// is within a word or two of the volatile that preceded it, never half its length.
    static func lostMostOfItsContent(final: String, volatile: String) -> Bool {
        let volatileLetters = volatile.count(where: { $0.isLetter || $0.isNumber })
        guard volatileLetters > 0 else { return false }
        let finalLetters = final.count(where: { $0.isLetter || $0.isNumber })
        return finalLetters * 2 < volatileLetters
    }

    /// True when a forced final has lost content the recogniser had already heard, by
    /// either of the two measured mechanisms.
    static func finalLostContent(final: String, volatile: String) -> Bool {
        lostMostOfItsContent(final: final, volatile: volatile)
            || finalIsSubrangeOfVolatile(final: final, volatile: volatile)
            || hasPunctuationRun(final)
    }

    /// True when the final contains a run of full stops or commas.
    ///
    /// The third measured shape of the same failure, and the one both other rules miss. On
    /// a seven-second question the recogniser replaced six words with ten full stops:
    /// `"Return the indices of the 2 numbers such that…"` became `"that.......... such
    /// that…"`. That keeps 29 letters against the volatile's 52, so the bulk rule clears
    /// it, and it *inserts* a word, so it is not a subrange either. The run itself is the
    /// reliable signal — no genuine transcript from this recogniser contains one.
    ///
    /// Four or more, so a deliberate three-dot ellipsis is never mistaken for debris.
    static func hasPunctuationRun(_ text: String) -> Bool {
        text.range(of: "[.,]{4,}", options: .regularExpression) != nil
    }

    /// True when the final's words are a strict, contiguous subrange of the volatile's.
    ///
    /// `lostMostOfItsContent` only fires when a forced final comes back as punctuation.
    /// Measured on a live Meet call, the same failure also arrives in a milder form: the
    /// final keeps the sentence but loses a word off the front — `"Are you able to listen
    /// to me properly?"` finalised as `"You able to listen to me properly?"`. Three letters
    /// of thirty-one is nowhere near half, so the bulk rule cannot see it, and a question
    /// reaches the user missing its first word.
    ///
    /// Demanding an *exact contiguous* match is what keeps this from firing on a final that
    /// merely worded something differently: a reword is never a subrange, so an ordinary
    /// final that improves on its volatile still wins.
    static func finalIsSubrangeOfVolatile(final: String, volatile: String) -> Bool {
        let f = comparableWords(final), v = comparableWords(volatile)
        // Equal length is not loss — that is the ordinary case of a final tidying wording.
        guard !f.isEmpty, f.count < v.count else { return false }
        for start in 0...(v.count - f.count) where Array(v[start..<(start + f.count)]) == f {
            return true
        }
        return false
    }

    /// Case-folded, punctuation-free words, so the comparison sees content and not the
    /// capitalisation and terminal punctuation a final adds on purpose.
    private static func comparableWords(_ s: String) -> [String] {
        TextNormalizer.matchKey(s).split(separator: " ").map(String.init)
    }

    private mutating func build(_ next: Pending, now: Double, timedOut: Bool) -> Question? {
        let endpoint = next.endpoint
        let cutoff = endpoint.decisionTime + claimTolerance
        let claimed = segments.filter { $0.start < cutoff }
        segments.removeAll { $0.start < cutoff }

        var pieces = claimed
        var text = TextNormalizer.normalizeFinal(
            claimed.map(\.text).joined(separator: " "), terms: terms
        )

        // Fallback to the retained volatile when no usable final covers the span. A forced
        // final that never lands, or lands gutted to punctuation, otherwise dropped a
        // boundary whose words were sitting in `volatiles` — exactly what the caption was
        // showing. Whole regions are substituted, never spliced, the same rule finalArrived
        // uses; claimed only by range, so an unrelated volatile is never pulled in.
        let windowVolatiles = volatiles.filter {
            $0.start < cutoff && $0.end > endpoint.speechStart - claimTolerance
        }
        var rescuedVolatile = false
        if text.isEmpty, !windowVolatiles.isEmpty {
            let starts = Set(windowVolatiles.map(\.start))
            volatiles.removeAll { starts.contains($0.start) }
            pieces = windowVolatiles.sorted { $0.start < $1.start }
            text = TextNormalizer.normalizeFinal(
                pieces.map(\.text).joined(separator: " "), terms: terms
            )
            rescuedVolatile = !text.isEmpty
        }

        guard !text.isEmpty else {
            // Nothing was emitted, so there is no previous question on screen for a later
            // continuation to revise. Leaving the old text in place would glue the next
            // half-question onto one the user stopped seeing questions ago.
            lastText = ""
            lastStart = 0
            dropped.append(DroppedEndpoint(
                endpoint: endpoint,
                hadTranscript: !claimed.isEmpty || !windowVolatiles.isEmpty
            ))
            return nil
        }
        let usedVolatile = rescuedVolatile || pieces.contains(where: \.fromVolatile)

        var t0 = endpoint.speechStart
        var revises = false
        if endpoint.continuesPrevious, !lastText.isEmpty {
            // Re-emit the whole thing so a consumer replaces the half-question it already
            // has on screen rather than appending to it.
            text = TextNormalizer.joinContinuation(lastText, text, terms: terms)
            t0 = lastStart
            revises = true
        }
        lastText = text
        lastStart = t0

        return Question(
            text: text,
            t0: t0,
            t1: endpoint.speechEnd,
            latencyMilliseconds: max(0, Int(((now - next.requestedAt) * 1000).rounded())),
            revises: revises,
            timedOut: timedOut,
            usedVolatileFallback: usedVolatile
        )
    }
}

public extension Event {
    static func question(_ q: QuestionAssembler.Question, speaker: Speaker? = nil) -> Event {
        .question(
            text: q.text, t0: q.t0, t1: q.t1, ms: q.latencyMilliseconds,
            revises: q.revises, usedVolatile: q.usedVolatileFallback, speaker: speaker
        )
    }
}
