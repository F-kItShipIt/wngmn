import Testing
@testable import WngmnCore

/// Grouping consecutive utterances into a turn worth answering.
///
/// A question can be spread across several sentences with pauses between them. Answering
/// each endpoint separately would answer half-questions; the batcher waits for the speaker
/// to finish — signalled by the other speaker starting, or by a gap of silence — and hands
/// over the whole turn. Caller turns always qualify (the model replies NONE if there is
/// nothing to answer); your own turns qualify the same way when the feature is enabled.
@Suite("TurnBatcher")
struct TurnBatcherTests {
    @Test("Consecutive caller lines within the gap form one turn, closed when you speak")
    func groupsUntilYouSpeak() {
        var b = TurnBatcher(turnGapSeconds: 2.5)
        #expect(b.question(text: "So tell me", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0) == nil)
        #expect(b.question(text: "about the funding round.", t0: 2.5, t1: 3.5, speaker: .caller, now: 101.0) == nil)
        // You start a plain statement — it closes the caller turn but is not itself answered.
        let turn = b.question(text: "Great question.", t0: 4.0, t1: 4.5, speaker: .you, now: 102.0)
        #expect(turn?.text == "So tell me about the funding round.")
        #expect(turn?.speaker == .caller)
        #expect(turn?.t0 == 1.0)
        #expect(turn?.t1 == 3.5)
        #expect(turn?.lineCount == 2)
    }

    @Test("A silence gap closes the caller turn without you speaking")
    func gapClosesTurn() {
        var b = TurnBatcher(turnGapSeconds: 2.5)
        _ = b.question(text: "What is your burn rate?", t0: 1.0, t1: 3.0, speaker: .caller, now: 100.0)
        #expect(b.tick(now: 101.0) == nil, "still within the gap")
        #expect(b.tick(now: 103.0)?.text == "What is your burn rate?")
        #expect(b.tick(now: 104.0) == nil, "the turn was already closed")
    }

    @Test("A caller line after the gap closes the previous turn and starts a new one")
    func newLineAfterGapClosesPrevious() {
        var b = TurnBatcher(turnGapSeconds: 2.5)
        _ = b.question(text: "First question.", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        let closed = b.question(text: "Second question.", t0: 10.0, t1: 11.0, speaker: .caller, now: 103.0)
        #expect(closed?.text == "First question.")
        #expect(b.tick(now: 106.0)?.text == "Second question.")
    }

    @Test("Nothing open yields nothing")
    func nothingOpen() {
        var b = TurnBatcher()
        #expect(b.tick(now: 100.0) == nil)
        #expect(b.question(text: "Hi.", t0: 1, t1: 2, speaker: .you, now: 100.0) == nil,
                "a plain you-statement with answerOwnQuestions off is never a turn")
    }

    @Test("Your own statement is never answered when the feature is off")
    func ownStatementOffNeverAnswers() {
        var b = TurnBatcher(turnGapSeconds: 2.0, answerOwnQuestions: false)
        _ = b.question(text: "Let me think about that.", t0: 1, t1: 3, speaker: .you, now: 100.0)
        #expect(b.tick(now: 103.0) == nil)
    }

    @Test("Your own question is answered when the feature is on")
    func ownQuestionOnAnswers() {
        var b = TurnBatcher(turnGapSeconds: 2.0, answerOwnQuestions: true)
        _ = b.question(text: "How would I reverse a linked list", t0: 1, t1: 3, speaker: .you, now: 100.0)
        let turn = b.tick(now: 103.0)
        #expect(turn?.text == "How would I reverse a linked list")
        #expect(turn?.speaker == .you)
    }

    @Test("Your own turn qualifies when the feature is on, question-shaped or not")
    func ownTurnOnQualifies() {
        var b = TurnBatcher(turnGapSeconds: 2.0, answerOwnQuestions: true)
        // The recogniser clipped "Can you write" and dropped the question mark.
        _ = b.question(text: "To, a program to merge 2 sorted arrays.", t0: 1, t1: 3, speaker: .you, now: 100.0)
        #expect(b.tick(now: 103.0)?.speaker == .you, "the model decides NONE, not the batcher")
    }

    @Test("A caller turn still always qualifies, question-shaped or not")
    func callerAlwaysQualifies() {
        var b = TurnBatcher(turnGapSeconds: 2.0, answerOwnQuestions: true)
        _ = b.question(text: "I think we should talk about pricing.", t0: 1, t1: 3, speaker: .caller, now: 100.0)
        #expect(b.tick(now: 103.0)?.speaker == .caller, "the model decides NONE, not the batcher")
    }

    @Test("A short pause keeps lines in the same turn")
    func shortPauseStaysOneTurn() {
        var b = TurnBatcher(turnGapSeconds: 2.5)
        _ = b.question(text: "I was wondering,", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        #expect(b.tick(now: 101.5) == nil)
        _ = b.question(text: "about your margins.", t0: 3.0, t1: 4.0, speaker: .caller, now: 102.0)
        #expect(b.question(text: "Sure.", t0: 5, t1: 5.5, speaker: .you, now: 103.0)?.text
                == "I was wondering, about your margins.")
    }
}
