import Foundation
import WngmnCore

/// Drives real-time answers: it turns the stream of utterances into answered turns.
///
/// Utterances go in via `question`; a periodic `tick` closes a turn that has gone quiet.
/// When auto is enabled and a turn qualifies, it is answered against the shared
/// `CallConversation` and the answer is pushed to every open page over the same `answer_done`
/// frame a manual Ask uses — so it lands in the answer panel with no new UI.
///
/// The reply is buffered rather than streamed token by token: the model may reply `NONE`
/// when a turn needs no answer, and a page must never flash `NONE` before it is recognised.
/// A caller waiting a beat for the whole answer is the agreed behaviour anyway.
///
/// An actor: utterances and ticks arrive on different tasks and the turn batcher is the
/// state between them. The network call and the page are injected, so the whole loop is
/// tested without credentials or a socket.
///
/// One request is in flight at a time, and that is `AnswerQueue`'s doing rather than the
/// actor's. `question` and `tick` used to await the answer inline; an actor is re-entrant
/// while it is suspended, so the ticker could start a second request beside a streaming one,
/// and the ledger then held both user turns before either reply. Now they enqueue and return,
/// and a single drain task owns whatever request is out.
public actor AutoAnswerer {
    public struct Stats: Sendable, Equatable {
        public var answers: Int
        public var calls: Int
        public init(answers: Int = 0, calls: Int = 0) {
            self.answers = answers
            self.calls = calls
        }
    }

    /// Streams a reply for a system prompt and a message list, calling `onText` per fragment.
    public typealias Respond = @Sendable (
        _ system: String, _ messages: [ClaudeClient.Message],
        _ onText: @escaping @Sendable (String) -> Void
    ) async throws -> Void

    private var batcher: TurnBatcher
    private var queue = AnswerQueue<ConversationItem>()
    private let conversation: CallConversation
    private let isEnabled: @Sendable () -> Bool
    private let respond: Respond
    private let broadcast: @Sendable (String) -> Void
    private let broadcastLive: @Sendable (String) -> Void
    private var stats = Stats()

    /// The one task that sends. It lives from the first `send` until the queue has nothing
    /// left, so there is never a second one to race it.
    private var drain: Task<Void, Never>?
    /// The request that is out, so a `cancel` command has something to cancel.
    private var inFlight: (id: Int, task: Task<Void, Error>)?
    /// Cancellations asked for, by request id. A set and not just `inFlight?.task.cancel()`
    /// because a cancel can arrive in the gap between the queue handing out an id and the
    /// request's task existing — `perform` awaits the ledger first — and would otherwise be
    /// lost; `perform` reads it on the far side of that await and sends nothing. It is also
    /// what decides a request was cancelled, rather than the error it threw: a transport may
    /// surface cancellation as `URLError.cancelled`, or finish anyway.
    private var cancelRequested: Set<Int> = []

    public init(
        conversation: CallConversation,
        turnGapSeconds: Double = 2.5,
        answerOwnQuestions: Bool = false,
        ownTurnMinimumWords: Int = 4,
        isEnabled: @escaping @Sendable () -> Bool,
        respond: @escaping Respond,
        broadcast: @escaping @Sendable (String) -> Void,
        broadcastLive: @escaping @Sendable (String) -> Void
    ) {
        self.batcher = TurnBatcher(
            turnGapSeconds: turnGapSeconds,
            answerOwnQuestions: answerOwnQuestions,
            ownTurnMinimumWords: ownTurnMinimumWords
        )
        self.conversation = conversation
        self.isEnabled = isEnabled
        self.respond = respond
        self.broadcast = broadcast
        self.broadcastLive = broadcastLive
    }

    public var currentStats: Stats { stats }
    public var conversationLedger: CallConversation { conversation }

    /// An utterance arrived. Feeds the batcher and queues any turn it closes. Does not wait
    /// for the answer.
    public func question(text: String, t0: Double, t1: Double, speaker: Speaker, now: Double) async {
        if let turn = batcher.question(text: text, t0: t0, t1: t1, speaker: speaker, now: now) {
            submit(turn)
        }
    }

    /// Time passed. Queues a turn that has gone quiet past the gap. Does not wait for the
    /// answer.
    public func tick(now: Double) async {
        if let turn = batcher.tick(now: now) {
            submit(turn)
        }
    }

    /// Hands a closed turn to the queue. `preempts` is for an item that must not wait behind an
    /// answer nobody needs any more; no spoken turn ever sets it.
    ///
    /// The turn is a real turn whether or not auto is on; but with auto off there is no ledger
    /// to keep and no answer to give, so it is simply not recorded. Turning auto on mid-call
    /// starts the memory from that point, which is the honest thing — it never had the earlier
    /// turns. The toggle is read here, when the turn closes, and again in `run` before anything
    /// is sent.
    func submit(_ turn: TurnBatcher.Turn, preempts: Bool = false) {
        guard isEnabled() else { return }
        handle(queue.enqueue(.turn(turn), preempts: preempts))
    }

    /// A picture of the screen, taken on purpose. It is announced to the page at once — the
    /// shutter is silenced, so that row is the only sign the keypress did anything — and it
    /// cuts in on whatever answer is out, which is usually an answer to "let me paste this".
    ///
    /// The auto toggle is not consulted. The toggle governs what is overheard; pressing a key
    /// is asking, the same as pressing Ask.
    public func shot(_ shot: Shot) {
        broadcast(Self.shotFrame(shot))
        handle(queue.enqueue(.shot(shot), preempts: true))
    }

    /// A key was pressed and no picture came of it — no Screen Recording grant, or an image
    /// too large to send. It is still given a row, with the reason on it, because a warning
    /// alone lands in the side panel and a phone does not show the side panel at all.
    public func shotFailed(t: Double, mode: ShotMode, detail: String) {
        let blank = Shot(base64: "", t: t, mode: mode, width: 0, height: 0, byteCount: 0)
        broadcast(Self.shotFrame(blank))
        broadcast(Self.answerFailedFrame(key: blank.key, detail: detail))
    }

    /// Suspends until nothing is in flight and nothing waits. A loop, because a drain that ends
    /// can be followed at once by another.
    func idle() async {
        while let task = drain { await task.value }
    }

    private func handle(_ command: AnswerQueue<ConversationItem>.Command) {
        switch command {
        case .none:
            return
        case let .cancel(id):
            cancelRequested.insert(id)
            if inFlight?.id == id { inFlight?.task.cancel() }
        case let .send(id, batch):
            // The queue hands out a `send` from `enqueue` only when nothing is in flight, and
            // from `settled` only inside the drain below, so this never replaces a live drain.
            drain = Task { await self.run(id: id, batch: batch) }
        }
    }

    private func run(id firstID: Int, batch firstBatch: [ConversationItem]) async {
        var next: (id: Int, batch: [ConversationItem])? = (firstID, firstBatch)
        while let (id, batch) = next {
            // Read again before every send, and not only when the turn closed. Unticking auto
            // because the call has turned confidential means "send nothing more", and a batch
            // held behind a slow request would otherwise leave when that request settled — up
            // to the 90 s request timeout after the toggle went off. What is skipped is not
            // recorded either, like any turn that closes while auto is off.
            //
            // A screenshot is exempt, here as in `shot`: it was asked for. With auto off it
            // goes alone — it must not carry held speech out with it.
            let sendable = isEnabled() ? batch : batch.filter { if case .shot = $0 { true } else { false } }
            if !sendable.isEmpty { await perform(id: id, batch: sendable) }
            // Whatever became of it, this id is finished with. A cancel that lands while the
            // reply is being committed arrives too late to matter, and would otherwise sit in
            // the set for the rest of the call.
            cancelRequested.remove(id)
            if case let .send(nextID, nextBatch) = queue.settled(id) {
                next = (nextID, nextBatch)
            } else {
                next = nil
            }
        }
        drain = nil
    }

    /// One request for one batch. The answer belongs to the batch's last turn: the earlier
    /// ones are what was said on the way to it, and are context.
    private func perform(id: Int, batch: [ConversationItem]) async {
        guard let last = batch.last else { return }
        let shotKeys = batch.compactMap { item -> String? in
            if case let .shot(shot) = item { return shot.key }
            return nil
        }
        // A batch that holds a screenshot is answered under the screenshot, and the last one
        // if there are several — not under whatever closed last. A spoken turn can slip in
        // between the keypress and the send; the answer is still about the picture, and the
        // picture's row is the one on the stage saying "Asking…".
        let key = shotKeys.last ?? Self.key(for: last)
        let answersAShot = !shotKeys.isEmpty
        let (system, messages) = await conversation.startBatch(batch)
        // Every shot in the batch but the last shares the last one's answer.
        settleOvertaken(Array(shotKeys.dropLast()))
        // A cancel can land while the ledger was being awaited, before any request exists. The
        // turns are committed — they were said — but there is nothing to send, and launching a
        // request only to cancel it would still be counted, and shown, as a call.
        if cancelRequested.contains(id) {
            settleOvertaken(shotKeys.suffix(1))
            return
        }
        stats.calls += 1
        broadcastLive(Self.statsFrame(stats))

        let accumulated = Accumulator()
        let respond = self.respond
        let task = Task { try await respond(system, messages) { accumulated.append($0) } }
        inFlight = (id, task)
        let result = await task.result
        inFlight = nil

        // Cancelled: the turns stay in the ledger as context and nothing is shown — the shape a
        // NONE leaves. The call was still made, so it stays counted.
        if cancelRequested.contains(id) {
            settleOvertaken(shotKeys.suffix(1))
            return
        }

        switch result {
        case .success:
            let full = accumulated.value
            await conversation.finishTurn(answer: full)
            if CallConversation.isNone(full) {
                // Nothing worth answering; the turn stays in the ledger as context and the
                // page shows nothing. The call still counted — it is spend the user can see.
                //
                // Except over a screenshot, where "shows nothing" is wrong: the page has been
                // saying "Asking…" since the key was pressed, and nothing would ever replace it.
                if answersAShot {
                    broadcast(Self.answerFailedFrame(
                        key: key, detail: "the model had nothing to say about this screenshot"))
                }
                return
            }
            stats.answers += 1
            broadcastLive(Self.statsFrame(stats))
            broadcast(Self.answerDoneFrame(key: key, text: full.trimmingCharacters(in: .whitespacesAndNewlines)))
        case let .failure(error):
            // A picture the API will not take — too large, not an image it reads — would be
            // sent again with every later turn and fail every one of them. Anything else (a
            // dropped connection, a 529) says nothing about the picture, so it stays and the
            // next request carries it.
            if case let ClaudeClient.Failure.http(status, _) = error, status == 400 || status == 413 {
                await conversation.removeShots(keys: shotKeys)
            }
            broadcast(Self.answerFailedFrame(key: key, detail: "\(error)"))
        }
    }

    /// Writes end-of-call notes from the whole conversation and pushes them to every page.
    ///
    /// Nothing to summarise when nothing was sent — the ledger is built from what auto
    /// answered and from screenshots — so it says so rather than summarising an empty
    /// conversation.
    public func summarise() async {
        // Before the guard, not after it. Notes asked for while an answer is out would be
        // written beside it, from a ledger holding the question and not the reply, and
        // without the turns held in the queue behind it; and a first turn whose request has
        // not yet reached the ledger would be told there is no conversation. Bounded by the
        // request timeout.
        await idle()
        guard await !conversation.isEmpty else {
            broadcast(Self.summaryFailedFrame(
                detail: "no conversation yet — notes are written from what auto answered and from screenshots"))
            return
        }
        broadcast(Self.summaryPendingFrame())
        let (system, messages) = await conversation.summaryRequest()
        let accumulated = Accumulator()
        do {
            try await respond(system, messages) { accumulated.append($0) }
            broadcast(Self.summaryDoneFrame(
                text: accumulated.value.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            broadcast(Self.summaryFailedFrame(detail: "\(error)"))
        }
    }

    /// Ends "Asking…" on screenshots that will get no answer of their own. On the page that
    /// text is not a state: it is what any asked row shows until something arrives under its
    /// key, and a cancelled request sends nothing. Only a newer screenshot pre-empts, so a
    /// cancelled one always has a later one whose answer covers it — the picture is still in
    /// the conversation that answer is written from.
    private func settleOvertaken(_ keys: some Sequence<String>) {
        for key in keys {
            broadcast(Self.answerDoneFrame(key: key, text: "*Answered with the screenshot after this one.*"))
        }
    }

    /// A tiny reference box so the streaming closure can accumulate without capturing `self`.
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    // MARK: - Frames (pure, so the wire shape is asserted without a socket)

    /// Keyed like a manual Ask so the page attaches it to the turn's first line and shows it
    /// in the answer panel. The page keys answers by `<speaker>@<t0>`.
    ///
    /// `t0` goes through the same encoder the question line went through, and not raw
    /// interpolation. The page rebuilds this key from the JSON it was given, where `t0` has
    /// already been rounded to 3 dp, so the two spellings only ever agreed when the Double's
    /// shortest form happened to be that short. `t0` accumulates as `startTime + i / rate`,
    /// which is essentially never that short, so live auto-answers matched no row and were
    /// dropped silently — after the call had been made, and counted in the `auto` stats, which
    /// is why the page could report an answer and show an empty panel.
    static func key(for turn: TurnBatcher.Turn) -> String {
        "\(turn.speaker.rawValue)@\(EventEncoder.number(turn.t0))"
    }

    static func key(for item: ConversationItem) -> String {
        switch item {
        case let .turn(turn): key(for: turn)
        case let .shot(shot): shot.key
        }
    }

    /// Tells the page a screenshot was taken: when, how, and how big. Never the picture — this
    /// frame is backlogged and written to the session log, and the log is kept indefinitely.
    ///
    /// Built by hand rather than through `JSONSerialization`, which spells 83.412 as
    /// 83.412000000000006. `t` and the key have to agree to the digit.
    static func shotFrame(_ shot: Shot) -> String {
        #"{"type":"shot","key":\#(EventEncoder.quote(shot.key)),"t":\#(EventEncoder.number(shot.t)),"#
            + #""mode":\#(EventEncoder.quote(shot.mode.rawValue)),"w":\#(shot.width),"h":\#(shot.height),"#
            + #""bytes":\#(shot.byteCount)"# + (shot.part > 1 ? #","part":\#(shot.part)"# : "") + "}"
    }

    static func answerDoneFrame(key: String, text: String) -> String {
        // `for` is deliberately omitted: the turn spans lines whose joined text matches no
        // single question line, and the page only applies its staleness guard when `for` is
        // present. Keyed by the first line, it lands there.
        object(["type": "answer_done", "key": key, "text": text])
    }

    static func answerFailedFrame(key: String, detail: String) -> String {
        object(["type": "answer_failed", "key": key, "detail": detail])
    }

    static func statsFrame(_ stats: Stats) -> String {
        object(["type": "auto", "answers": stats.answers, "calls": stats.calls])
    }

    static func summaryPendingFrame() -> String { object(["type": "summary_pending"]) }
    static func summaryDoneFrame(text: String) -> String {
        object(["type": "summary_done", "text": text])
    }
    static func summaryFailedFrame(detail: String) -> String {
        object(["type": "summary_failed", "detail": detail])
    }

    private static func object(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8)
        else { return "{}" }
        return line
    }
}
