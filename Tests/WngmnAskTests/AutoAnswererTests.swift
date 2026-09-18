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
            var cancelledCalls = 0
            var pictures: [Int] = []
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
        /// Requests whose task was cancelled, counted the moment the cancel landed. Observed
        /// through a cancellation handler because `Gate.wait()` cannot be woken by a cancel: a
        /// test that only looked at what came out afterwards passed with both `task.cancel()`
        /// calls deleted, since the reply of a request marked cancelled is discarded either way.
        var cancelledCalls: Int { state.withLock { $0.cancelledCalls } }
        /// How many pictures each request carried, in the order the requests began.
        var pictures: [Int] { state.withLock { $0.pictures } }
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
                    s.pictures.append(messages.filter(CallConversation.hasPicture).count)
                    return s.reply
                }
                await withTaskCancellationHandler {
                    await gate?.wait()
                } onCancel: {
                    h.state.withLock { $0.cancelledCalls += 1 }
                }
                h.state.withLock { $0.concurrent -= 1 }
                try Task.checkCancellation()
                onText(r)
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
    }

    func turn(_ text: String, _ t0: Double) -> TurnBatcher.Turn {
        TurnBatcher.Turn(text: text, t0: t0, t1: t0 + 1, lineCount: 1, speaker: .caller)
    }

    /// Polls until `condition` holds, or gives up. The same helper `TranscriptServerTests` has.
    func wait(until condition: () -> Bool, seconds: Double = 10) async {
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
        await a.idle()

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
        await a.idle()

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
        await a.idle()

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
        await a.idle()
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
        await a.idle()
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
        await a.idle()
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
        await off.idle()
        #expect(hOff.respondCalls == 0, "own questions off: not answered")

        let hOn = Harness()
        let on = make(hOn, own: true)
        await on.question(text: "How would I reverse a list?", t0: 1, t1: 2, speaker: .you, now: 100.0)
        _ = await on.tick(now: 103.0)
        await on.idle()
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

    @Test("Turns that close while a request is out go together, answered under the last one's key")
    func waitingTurnsAreBatched() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("First question.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.submit(turn("Second question.", 5))
        await a.submit(turn("Third question.", 9))
        gate.open()
        await a.idle()

        #expect(h.respondCalls == 2, "one request for the first turn, one for the two that waited")
        #expect(h.requests.last == [
            "Caller: First question.", "An answer.",
            "Caller: Second question.", "Caller: Third question.",
        ])
        let done = h.seen.filter { $0.contains("answer_done") }
        #expect(done.count == 2)
        #expect(done.last?.contains("\"key\":\"caller@9\"") == true)
        #expect(!h.seen.contains { $0.contains("\"key\":\"caller@5\"") }, "the middle turn is context")
    }

    /// No spoken turn pre-empts: it is for something the user did deliberately rather than
    /// something overheard. The cancelled turn stays in the ledger with no reply after it —
    /// what a NONE already leaves behind.
    @Test("A pre-empting item cancels the request in flight and is answered with it as context")
    func preemptionCancelsAndCarriesContext() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Let me paste this here.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.submit(turn("The pasted problem.", 5), preempts: true)
        #expect(h.cancelledCalls == 1, "the request in flight was not cancelled")
        gate.open()
        await a.idle()

        #expect(h.maxConcurrent == 1)
        #expect(h.requests.last == ["Caller: Let me paste this here.", "Caller: The pasted problem."],
                "the cancelled turn is context, with no reply after it")
        let done = h.seen.filter { $0.contains("answer_done") }
        #expect(done.count == 1, "the cancelled request shows nothing")
        #expect(done.first?.contains("\"key\":\"caller@5\"") == true)
        #expect(!h.seen.contains { $0.contains("answer_failed") }, "a cancellation is not a failure")
        let stats = await a.currentStats
        #expect(stats.calls == 2, "the cancelled call was still made, so it is still counted")
        #expect(stats.answers == 1)
    }

    @Test("A failed request does not strand what was waiting behind it")
    func failureKeepsDraining() async {
        struct Boom: Error {}
        let h = Harness()
        let gate = Gate()
        let calls = Mutex(0)
        let a = AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns\n\n## Context\nc")),
            isEnabled: { true },
            respond: { _, _, onText in
                let n = calls.withLock { c -> Int in c += 1; return c }
                await gate.wait()
                if n == 1 { throw Boom() }
                onText("Second time lucky.")
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )

        await a.submit(turn("First.", 1))
        await wait(until: { calls.withLock { $0 } == 1 })
        await a.submit(turn("Second.", 5))
        gate.open()
        await a.idle()

        #expect(h.seen.contains { $0.contains("answer_failed") && $0.contains("caller@1") })
        #expect(h.seen.contains { $0.contains("answer_done") && $0.contains("caller@5") })
    }

    @Test("A turn that closes with auto off is not queued, even behind a request in flight")
    func autoOffIsNotQueued() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Asked with auto on.", 1))
        await wait(until: { h.respondCalls == 1 })
        h.setEnabled(false)
        await a.submit(turn("Said with auto off.", 5))
        gate.open()
        await a.idle()

        #expect(h.respondCalls == 1)
    }

    /// Unticking auto means "send nothing more". The toggle used to be read only when a turn
    /// closed, so a batch held behind a slow request still left when that request settled —
    /// up to the 90 s request timeout after the toggle went off.
    @Test("Turns held behind a request are not sent once auto is switched off")
    func heldTurnsAreDroppedWhenAutoGoesOff() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Asked with auto on.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.submit(turn("Held, and accepted while auto was still on.", 5))
        h.setEnabled(false)
        gate.open()
        await a.idle()

        #expect(h.respondCalls == 1, "a request left after auto was switched off")
    }

    /// Notes asked for mid-answer used to be written beside it, from a ledger that had the
    /// question and not the reply, and without anything held in the queue behind it.
    @Test("Notes asked for while an answer is out wait for it, and for what was held behind it")
    func summariseWaitsForTheQueue() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("What is your burn rate?", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.submit(turn("And your runway?", 5))
        let notes = Task { await a.summarise() }
        // Every chance to go out early, which is the defect; it is not waited for otherwise.
        await wait(until: { h.respondCalls == 2 }, seconds: 0.3)
        #expect(h.maxConcurrent == 1, "the notes request went out beside the answer")

        gate.open()
        await notes.value

        #expect(Array(h.requests.last?.prefix(4) ?? []) == [
            "Caller: What is your burn rate?", "An answer.",
            "Caller: And your runway?", "An answer.",
        ], "the notes must be written from the whole conversation")
    }

    /// The cancel can land before the request exists — `perform` awaits the ledger first — and
    /// nothing here can force that ordering, so this asserts only what must hold whichever way
    /// the race goes: never two requests, never a failure, and the pre-empting item answered.
    @Test("A pre-empting item that arrives before the request has left is still answered")
    func preemptionBeforeTheRequestLeaves() async {
        let h = Harness()
        let a = make(h)

        await a.submit(turn("Let me paste this here.", 1))
        await a.submit(turn("The pasted problem.", 5), preempts: true)
        await a.idle()

        #expect(h.maxConcurrent == 1)
        #expect(!h.seen.contains { $0.contains("answer_failed") })
        #expect(h.requests.last?.last == "Caller: The pasted problem.")
        #expect(h.seen.last { $0.contains("answer_done") }?.contains("\"key\":\"caller@5\"") == true)
    }

    // MARK: - Screenshots

    func shot(_ t: Double) -> Shot {
        Shot(base64: "iVBORw0KGgo=", t: t, mode: .region, width: 1500, height: 900, byteCount: 412_380)
    }

    /// Pressing the key is the Ask. The toggle is for what is overheard; this was deliberate.
    @Test("A screenshot is answered with auto off")
    func shotIsAnsweredWithAutoOff() async {
        let h = Harness(); h.setEnabled(false); h.setReply("It is a two-pointer merge.")
        let a = make(h)
        await a.shot(shot(83.412))
        await a.idle()

        #expect(h.respondCalls == 1)
        #expect(h.pictures == [1])
        let done = h.seen.first { $0.contains("answer_done") }
        #expect(done?.contains("\"key\":\"screen@83.412\"") == true)
        #expect(done?.contains("two-pointer merge") == true)
    }

    /// The `shot` frame is the only sign the keypress worked — the shutter is silenced — so it
    /// goes out at once, ahead of the request. It says that a picture was taken and how big;
    /// it never carries the picture, because this frame is what the session log keeps.
    @Test("A screenshot is announced to the page before it is answered, without the picture")
    func shotIsAnnounced() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)
        await a.shot(shot(83.412))

        let frame = h.seen.first { $0.contains("\"type\":\"shot\"") }
        #expect(frame == #"{"type":"shot","key":"screen@83.412","t":83.412,"mode":"region","w":1500,"h":900,"bytes":412380}"#)
        #expect(!h.seen.contains { $0.contains("iVBORw0KGgo=") }, "the picture reached a frame")
        #expect(!h.seen.contains { $0.contains("answer_done") }, "announced before it is answered")

        gate.open()
        await a.idle()
    }

    @Test("A screenshot cancels the answer in flight, and goes out with that turn as context")
    func shotCutsIn() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Let me paste this here.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.shot(shot(5))
        #expect(h.cancelledCalls == 1, "the request in flight was not cancelled")
        gate.open()
        await a.idle()

        #expect(h.maxConcurrent == 1)
        #expect(h.requests.last == [
            "Caller: Let me paste this here.", "Screen: a screenshot I just took of my screen.",
        ])
        #expect(h.pictures.last == 1)
        let done = h.seen.filter { $0.contains("answer_done") }
        #expect(done.count == 1)
        #expect(done.first?.contains("\"key\":\"screen@5\"") == true)
    }

    /// Auto was switched off with speech still held behind a request. The screenshot is sent —
    /// it was deliberate — and must not carry the held speech out with it.
    @Test("With auto off, a screenshot does not take held speech out with it")
    func shotDoesNotDragSpeechOut() async {
        let h = Harness()
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Asked with auto on.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.submit(turn("Held, and auto goes off before it is sent.", 3))
        h.setEnabled(false)
        await a.shot(shot(5))
        gate.open()
        await a.idle()

        #expect(h.requests.last == [
            "Caller: Asked with auto on.", "Screen: a screenshot I just took of my screen.",
        ], "the held turn must not leave once auto is off")
    }

    /// A picture the API rejects would be sent, and rejected, on every later turn.
    @Test("A screenshot the API rejects is taken back out of the conversation")
    func rejectedShotIsRemoved() async {
        let h = Harness()
        let calls = Mutex(0)
        let a = AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns\n\n## Context\nc")),
            isEnabled: { true },
            respond: { _, messages, onText in
                let n = calls.withLock { c -> Int in c += 1; return c }
                h.state.withLock { $0.requests.append(messages.map(\.text)) }
                if n == 1 { throw ClaudeClient.Failure.http(status: 400, detail: "image exceeds the limit") }
                onText("An answer.")
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
        await a.shot(shot(5))
        await a.idle()
        await a.submit(turn("Did that come through?", 9))
        await a.idle()

        #expect(h.seen.contains { $0.contains("answer_failed") && $0.contains("screen@5") })
        #expect(h.requests.last == ["Caller: Did that come through?"], "the rejected picture is still in the conversation")
    }

    /// A dropped connection says nothing about the picture. It stays, and the next request
    /// carries it.
    @Test("A screenshot that fails on the network stays in the conversation")
    func networkFailureKeepsTheShot() async {
        let h = Harness()
        let calls = Mutex(0)
        let a = AutoAnswerer(
            conversation: CallConversation(profile: Profile(text: "## Style\ns\n\n## Context\nc")),
            isEnabled: { true },
            respond: { _, messages, onText in
                let n = calls.withLock { c -> Int in c += 1; return c }
                h.state.withLock { $0.requests.append(messages.map(\.text)) }
                if n == 1 { throw URLError(.networkConnectionLost) }
                onText("An answer.")
            },
            broadcast: { h.record($0) },
            broadcastLive: { h.record($0) }
        )
        await a.shot(shot(5))
        await a.idle()
        await a.submit(turn("Can you see it now?", 9))
        await a.idle()

        #expect(h.requests.last == [
            "Screen: a screenshot I just took of my screen.", "Caller: Can you see it now?",
        ])
    }

    /// NONE means "nothing to show", which is right for small talk and wrong here: the page is
    /// showing "Asking…" because a key was pressed, and nothing would ever replace it.
    @Test("A model that declines a screenshot is reported, not left hanging")
    func noneOnAShotIsReported() async {
        let h = Harness(); h.setReply("NONE")
        let a = make(h)
        await a.shot(shot(5))
        await a.idle()

        let failed = h.seen.first { $0.contains("answer_failed") }
        #expect(failed?.contains("screen@5") == true)
        #expect(!h.seen.contains { $0.contains("answer_done") })
    }

    /// "Asking…" on the page is not a state of its own: it is what any asked row shows until
    /// something arrives under its key. A cancelled request sends nothing, so without this a
    /// screenshot overtaken by another would say "Asking…" for the rest of the call.
    @Test("A screenshot overtaken by another is told so, rather than left asking")
    func overtakenShotIsSettled() async {
        let h = Harness(); h.setReply("Both halves: a two-pointer merge.")
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.shot(shot(5))
        await wait(until: { h.respondCalls == 1 })
        await a.shot(shot(9))
        gate.open()
        await a.idle()

        let first = h.seen.first { $0.contains("answer_done") && $0.contains("\"key\":\"screen@5\"") }
        #expect(first?.contains("Answered with the screenshot after this one") == true)
        let second = h.seen.first { $0.contains("answer_done") && $0.contains("\"key\":\"screen@9\"") }
        #expect(second?.contains("two-pointer merge") == true)
        #expect(h.pictures.last == 2, "the overtaken picture is still in the conversation")
    }

    @Test("Two screenshots sent together are answered under the later one")
    func twoShotsInOneBatch() async {
        let h = Harness(); h.setReply("Read together, it is one problem.")
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Here, it is in two parts.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.shot(shot(5))
        await a.shot(shot(9))
        gate.open()
        await a.idle()

        #expect(h.respondCalls == 2, "one request was cancelled, one carried both pictures")
        #expect(h.seen.contains { $0.contains("\"key\":\"screen@5\"") && $0.contains("Answered with the screenshot after this one") })
        #expect(h.seen.contains { $0.contains("\"key\":\"screen@9\"") && $0.contains("one problem") })
    }

    /// A spoken turn can close between the keypress and the request. The answer is about the
    /// picture, and the picture's row is the one on the stage saying "Asking…".
    @Test("An answer to a batch holding a screenshot lands on the screenshot, whatever was said after it")
    func answerLandsOnTheShot() async {
        let h = Harness(); h.setReply("It is a merge of two sorted arrays.")
        let gate = Gate()
        let a = make(h, gate: gate)

        await a.submit(turn("Let me paste this here.", 1))
        await wait(until: { h.respondCalls == 1 })
        await a.shot(shot(5))
        await a.submit(turn("Take your time with it.", 7))
        gate.open()
        await a.idle()

        #expect(h.requests.last?.suffix(2) == [
            "Screen: a screenshot I just took of my screen.", "Caller: Take your time with it.",
        ])
        let done = h.seen.filter { $0.contains("answer_done") }
        #expect(done.count == 1)
        #expect(done.first?.contains("\"key\":\"screen@5\"") == true)
    }

    /// A shot that could not be taken still has to show up where the reader is looking. A
    /// warning alone lands in the side panel, which a phone does not show at all.
    @Test("A screenshot that could not be taken is a row with its reason, not only a warning")
    func failedCaptureIsARow() async {
        let h = Harness()
        let a = make(h)
        await a.shotFailed(t: 12.5, mode: .screen, detail: "Screen Recording is not granted")

        #expect(h.seen.first == #"{"type":"shot","key":"screen@12.5","t":12.5,"mode":"screen","w":0,"h":0,"bytes":0}"#)
        #expect(h.seen.last?.contains("answer_failed") == true)
        #expect(h.seen.last?.contains("screen@12.5") == true)
        #expect(h.seen.last?.contains("Screen Recording is not granted") == true)
        #expect(h.respondCalls == 0)
    }
}
