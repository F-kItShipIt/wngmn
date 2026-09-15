import Foundation
import Synchronization
import Testing
import WngmnCore
@testable import WngmnAsk

/// The real-time answer loop: utterances in, answer frames out, driven by the toggle.
@Suite("AutoAnswerer")
struct AutoAnswererTests {
    /// Collects the frames the answerer broadcasts, and scripts the model's reply.
    final class Harness: Sendable {
        struct State {
            var frames: [String] = []
            var reply = "An answer."
            var enabled = true
            var respondCalls = 0
        }
        let state = Mutex(State())

        func record(_ s: String) { state.withLock { $0.frames.append(s) } }
        var seen: [String] { state.withLock { $0.frames } }
        var enabled: Bool { state.withLock { $0.enabled } }
        func setEnabled(_ b: Bool) { state.withLock { $0.enabled = b } }
        var reply: String { state.withLock { $0.reply } }
        func setReply(_ s: String) { state.withLock { $0.reply = s } }
        var respondCalls: Int { state.withLock { $0.respondCalls } }
    }

    func make(_ h: Harness, gap: Double = 2.5, own: Bool = false) -> AutoAnswerer {
        AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns\n\n## Context\nc")),
            turnGapSeconds: gap,
            answerOwnQuestions: own,
            isEnabled: { h.enabled },
            respond: { _, _, onText in
                let r = h.state.withLock { s -> String in s.respondCalls += 1; return s.reply }
                onText(r)
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
    }

    @Test("A caller turn is answered and pushed as a keyed answer_done frame")
    func answersCallerTurn() async {
        let h = Harness(); h.setReply("Series B, forty-two million.")
        let a = make(h)
        await a.question(text: "Tell me about the round.", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)   // gap closes the turn

        let done = h.seen.first { $0.contains("answer_done") }
        #expect(done != nil)
        #expect(done!.contains("\"key\":\"caller@1.0\""))
        #expect(done!.contains("Series B, forty-two million."))
        #expect(!done!.contains("\"for\""))
        let stats = await a.currentStats
        #expect(stats.calls == 1)
        #expect(stats.answers == 1)
    }

    @Test("A NONE reply shows nothing but still counts the call and keeps context")
    func noneShowsNothing() async {
        let h = Harness(); h.setReply("NONE")
        let a = make(h)
        await a.question(text: "Nice to meet you.", t0: 5.0, t1: 6.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)

        #expect(h.seen.first { $0.contains("answer_done") } == nil, "no answer is shown for NONE")
        let stats = await a.currentStats
        #expect(stats.calls == 1)
        #expect(stats.answers == 0)
        // The turn stayed in the ledger as context for the next answer.
        let (_, messages) = await a.conversationLedger.startTurn(
            TurnBatcher.Turn(text: "And the burn?", t0: 7, t1: 8, lineCount: 1, speaker: .caller))
        #expect(messages.count == 2)
    }

    @Test("With auto off, no call is made")
    func offMakesNoCall() async {
        let h = Harness(); h.setEnabled(false)
        let a = make(h)
        await a.question(text: "Tell me about the round.", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)
        #expect(h.respondCalls == 0)
        #expect(h.seen.isEmpty)
    }

    @Test("A failed answer is reported as answer_failed under the same key")
    func failureReported() async {
        let h = Harness()
        let a = AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns")),
            isEnabled: { true },
            respond: { _, _, _ in throw ClaudeClient.Failure.refused },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
        await a.question(text: "Tricky one?", t0: 2.0, t1: 3.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)
        let failed = h.seen.first { $0.contains("answer_failed") }
        #expect(failed != nil)
        #expect(failed!.contains("\"key\":\"caller@2.0\""))
    }

    @Test("Your own question is answered only when the feature is on")
    func ownQuestionGated() async {
        let hOff = Harness()
        let off = make(hOff, own: false)
        await off.question(text: "How would I reverse a list?", t0: 1, t1: 2, speaker: .you, now: 100.0)
        _ = await off.tick(now: 103.0)
        #expect(hOff.respondCalls == 0, "own questions off: not answered")

        let hOn = Harness()
        let on = make(hOn, own: true)
        await on.question(text: "How would I reverse a list?", t0: 1, t1: 2, speaker: .you, now: 100.0)
        _ = await on.tick(now: 103.0)
        #expect(hOn.seen.first { $0.contains("\"key\":\"you@1.0\"") } != nil)
    }
}
