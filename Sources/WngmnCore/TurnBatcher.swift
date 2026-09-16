import Foundation

/// Groups consecutive utterances into a turn worth answering.
///
/// The endpointer emits one `question` per utterance; a real question is often several of
/// them, spread across pauses. Answering each separately answers half-questions. The
/// batcher holds the current speaker's utterances open until the turn ends — the other
/// speaker starts, or a gap of silence passes — then hands the whole turn over at once.
///
/// A caller turn always qualifies, and so does your own when `answerOwnQuestions` is on:
/// whether a turn actually needs an answer is the model's call (it replies `NONE`), not the
/// batcher's. A shape heuristic here misjudged live transcripts — the recogniser clips the
/// opening "Can you…" and drops the question mark — so the model, which sees the whole
/// conversation, decides instead.
///
/// Pure and time-driven, like `QuestionAssembler`: utterances and a monotonic `now` go in,
/// turns come out, so it is tested without a socket or a clock.
public struct TurnBatcher: Sendable {
    public struct Turn: Sendable, Equatable {
        public let text: String
        public let t0: Double
        public let t1: Double
        public let lineCount: Int
        public let speaker: Speaker

        public init(text: String, t0: Double, t1: Double, lineCount: Int, speaker: Speaker) {
            self.text = text
            self.t0 = t0
            self.t1 = t1
            self.lineCount = lineCount
            self.speaker = speaker
        }
    }

    /// Silence after the last utterance before the turn is considered over. Longer than the
    /// caller merge window, so a mid-question breath does not split a turn in two.
    public var turnGapSeconds: Double
    /// Whether your own turns are sent for an answer too, not only the caller's.
    public var answerOwnQuestions: Bool

    public init(turnGapSeconds: Double = 2.5, answerOwnQuestions: Bool = false) {
        self.turnGapSeconds = turnGapSeconds
        self.answerOwnQuestions = answerOwnQuestions
    }

    private struct Open {
        var lines: [String] = []
        var t0: Double = 0
        var t1: Double = 0
        var speaker: Speaker
    }

    private var open: Open?
    private var lastNow: Double = 0

    /// An utterance arrived. `now` is monotonic seconds, used only for the gap.
    ///
    /// Returns the previous turn if this utterance ended it — the other speaker started, or
    /// this speaker resumed after the gap — and buffers the new utterance as the current turn.
    public mutating func question(
        text: String, t0: Double, t1: Double, speaker: Speaker, now: Double
    ) -> Turn? {
        var emitted: Turn?
        if let current = open {
            let switchedSpeaker = current.speaker != speaker
            let gapped = now - lastNow > turnGapSeconds
            if switchedSpeaker || gapped {
                emitted = closeOpen()
            }
        }
        if open == nil {
            open = Open(speaker: speaker)
            open?.t0 = t0
        }
        open?.lines.append(text)
        open?.t1 = t1
        lastNow = now
        return emitted
    }

    /// Time passed. Closes and returns the current turn if the gap has elapsed.
    public mutating func tick(now: Double) -> Turn? {
        guard open != nil, now - lastNow > turnGapSeconds else { return nil }
        return closeOpen()
    }

    /// Closes the open turn, returning it only if it qualifies for an answer.
    private mutating func closeOpen() -> Turn? {
        guard let current = open else { return nil }
        open = nil
        let text = current.lines.joined(separator: " ")
        let turn = Turn(
            text: text, t0: current.t0, t1: current.t1,
            lineCount: current.lines.count, speaker: current.speaker
        )
        switch current.speaker {
        case .caller:
            return turn
        case .you:
            return answerOwnQuestions ? turn : nil
        }
    }
}
