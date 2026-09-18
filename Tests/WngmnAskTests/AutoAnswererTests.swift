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
            var concurrent = 0
            var maxConcurrent = 0
            var requests: [[String]] = []
        }
        let state = Mutex(State())

        func record(_ s: String) { state.withLock { $0.frames.append(s) } }
        var seen: [String] { state.withLock { $0.frames } }
        var enabled: Bool { state.withLock { $0.enabled } }
        func setEnabled(_ b: Bool) { state.withLock { $0.enabled = b } }
        var reply: String { state.withLock { $0.reply } }
        func setReply(_ s: String) { state.withLock { $0.reply = s } }
        var respondCalls: Int { state.withLock { $0.respondCalls } }
        /// The most requests that were ever out at the same moment.
        var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
        /// What each request carried, as message texts, in the order the requests began.
        var requests: [[String]] { state.withLock { $0.requests } }
    }

    /// Holds every request at the door until it is opened, so a test can do things while a
    /// request is in flight. Without it the scripted reply returns at once and nothing is ever
    /// concurrent with anything.
    final class Gate: Sendable {
        struct State { var isOpen = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
        let state = Mutex(State())

        func wait() async {
            await withCheckedContinuation { continuation in
                let alreadyOpen = state.withLock { s -> Bool in
                    if s.isOpen { return true }
                    s.waiters.append(continuation)
                    return false
                }
                if alreadyOpen { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.isOpen = true
                defer { s.waiters = [] }
                return s.waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func make(_ h: Harness, gap: Double = 2.5, own: Bool = false, gate: Gate? = nil) -> AutoAnswerer {
        AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns\n\n## Context\nc")),
            turnGapSeconds: gap,
            answerOwnQuestions: own,
            isEnabled: { h.enabled },
            respond: { _, messages, onText in
                let r = h.state.withLock { s -> String in
                    s.respondCalls += 1
                    s.concurrent += 1
                    s.maxConcurrent = max(s.maxConcurrent, s.concurrent)
                    s.requests.append(messages.map(\.text))
                    return s.reply
                }
                await gate?.wait()
                h.state.withLock { $0.concurrent -= 1 }
                try Task.checkCancellation()
                onText(r)
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
    }

    /// Polls until `condition` holds, or gives up. The same helper `TranscriptServerTests` has.
    func wait(until condition: () -> Bool, seconds: Double = 2) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A caller turn is answered and pushed as a keyed answer_done frame")
    func answersCallerTurn() async {
        let h = Harness(); h.setReply("Series B, forty-two million.")
        let a = make(h)
        await a.question(text: "Tell me about the round.", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)   // gap closes the turn

        let done = h.seen.first { $0.contains("answer_done") }
        #expect(done != nil)
        #expect(done!.contains("\"key\":\"caller@1\""))
        #expect(done!.contains("Series B, forty-two million."))
        #expect(!done!.contains("\"for\""))
        let stats = await a.currentStats
        #expect(stats.calls == 1)
        #expect(stats.answers == 1)
    }

    /// The answer must be spelled with the `t0` the question line was published with.
    ///
    /// Every other key assertion in this suite uses a whole-number `t0`, and that is the one
    /// case where raw interpolation and `EventEncoder.number` agree — `1.0` against `1` is a
    /// difference the old code got away with because nothing compared them. So no test here
    /// crossed the boundary, and the mismatch shipped: a live `t0` accumulates as
    /// `startTime + i / rate` and carries far more than three decimals, the page is only ever
    /// given the rounded spelling, and an answer keyed the long way matched no row. It was
    /// dropped after the model call had been made and counted, which is how the page came to
    /// report an answer over an empty panel.
    @Test("An answer is keyed with the t0 spelling the question line was published with")
    func keyMatchesThePublishedQuestionLine() async {
        // The value from the session log that exposed this, to 14 decimal places.
        let t0 = 58.10982145766667
        let published = EventEncoder.number(t0)
        #expect(published == "58.11", "the page is only ever given a 3 dp t0")
        #expect("\(t0)" != published, "raw interpolation spells the same instant differently")

        let h = Harness(); h.setReply("Series B, forty-two million.")
        let a = make(h)
        await a.question(text: "Tell me about the round.", t0: t0, t1: 60.25, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)

        let done = h.seen.first { $0.contains("answer_done") }
        #expect(done != nil)
        #expect(done?.contains("\"key\":\"caller@\(published)\"") == true,
                "the answer has to land on the row the page built from that question line")
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
        #expect(failed!.contains("\"key\":\"caller@2\""))
    }

    @Test("Summarise writes notes from the conversation and broadcasts them")
    func summarises() async {
        let h = Harness(); h.setReply("Big answer.")
        let a = make(h)
        // Build some ledger first.
        await a.question(text: "Tell me about the round.", t0: 1.0, t1: 2.0, speaker: .caller, now: 100.0)
        _ = await a.tick(now: 103.0)
        h.setReply("Notes: the round, the plan.")
        await a.summarise()
        #expect(h.seen.contains { $0.contains("summary_pending") })
        let done = h.seen.first { $0.contains("summary_done") }
        #expect(done != nil)
        #expect(done!.contains("Notes: the round, the plan."))
    }

    @Test("Summarising an empty call reports there is nothing to summarise")
    func summariseEmpty() async {
        let h = Harness()
        let a = make(h)
        await a.summarise()
        #expect(h.seen.first { $0.contains("summary_failed") } != nil)
        #expect(h.seen.first { $0.contains("summary_done") } == nil)
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
        #expect(hOn.seen.first { $0.contains("\"key\":\"you@1\"") } != nil)
    }

    /// The hole, reproduced. `question` and `tick` used to await the answer inline, and an
    /// actor is re-entrant while it is suspended — so with the caller's answer still streaming,
    /// the ticker could close your turn and start a second request beside the first. The
    /// second request was then built from a ledger holding both user turns and neither reply.
    @Test("A turn that closes while a request is in flight does not start a second request")
    func oneRequestAtATime() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, own: true, gate: gate)

        // You start speaking, which closes the caller's turn; its request stops at the gate.
        let first = Task {
            await a.question(text: "Tell me about the round.", t0: 1, t1: 2, speaker: .caller, now: 100.0)
            await a.question(text: "So the round closed in March, all of it.", t0: 3, t1: 5, speaker: .you, now: 101.0)
        }
        await wait(until: { h.respondCalls == 1 })

        // Your turn goes quiet past the gap while that request is still out — the ticker's path.
        let ticked = Mutex(false)
        let second = Task {
            await a.tick(now: 110.0)
            ticked.withLock { $0 = true }
        }
        await wait(until: { h.maxConcurrent == 2 || ticked.withLock { $0 } })

        #expect(h.maxConcurrent == 1, "a second request started beside the first")

        gate.open()
        await first.value
        await second.value
        await wait(until: { h.seen.filter { $0.contains("answer_done") }.count == 2 })

        #expect(h.respondCalls == 2)
        #expect(h.requests.last == [
            "Caller: Tell me about the round.",
            "An answer.",
            "You: So the round closed in March, all of it.",
        ], "the second request must be built after the first reply is in the ledger")
    }
}
