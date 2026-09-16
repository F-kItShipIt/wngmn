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
    private let conversation: CallConversation
    private let isEnabled: @Sendable () -> Bool
    private let respond: Respond
    private let broadcast: @Sendable (String) -> Void
    private let broadcastLive: @Sendable (String) -> Void
    private var stats = Stats()

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

    /// An utterance arrived. Feeds the batcher and answers any turn it closes.
    public func question(text: String, t0: Double, t1: Double, speaker: Speaker, now: Double) async {
        if let turn = batcher.question(text: text, t0: t0, t1: t1, speaker: speaker, now: now) {
            await answer(turn)
        }
    }

    /// Time passed. Closes and answers a turn that has gone quiet past the gap.
    public func tick(now: Double) async {
        if let turn = batcher.tick(now: now) {
            await answer(turn)
        }
    }

    private func answer(_ turn: TurnBatcher.Turn) async {
        // The turn is a real turn whether or not auto is on; but with auto off there is no
        // ledger to keep and no answer to give, so it is simply not recorded. Turning auto on
        // mid-call starts the memory from that point, which is the honest thing — it never had
        // the earlier turns.
        guard isEnabled() else { return }

        let key = Self.key(for: turn)
        let (system, messages) = await conversation.startTurn(turn)
        stats.calls += 1
        broadcastLive(Self.statsFrame(stats))

        let accumulated = Accumulator()
        do {
            try await respond(system, messages) { fragment in accumulated.append(fragment) }
            let full = accumulated.value
            await conversation.finishTurn(answer: full)
            if CallConversation.isNone(full) {
                // Nothing worth answering; the turn stays in the ledger as context and the
                // page shows nothing. The call still counted — it is spend the user can see.
                return
            }
            stats.answers += 1
            broadcastLive(Self.statsFrame(stats))
            broadcast(Self.answerDoneFrame(key: key, text: full.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            broadcast(Self.answerFailedFrame(key: key, detail: "\(error)"))
        }
    }

    /// Writes end-of-call notes from the whole conversation and pushes them to every page.
    ///
    /// Nothing to summarise when auto never ran — the ledger is built from answered turns —
    /// so it says so rather than summarising an empty conversation.
    public func summarise() async {
        guard await !conversation.isEmpty else {
            broadcast(Self.summaryFailedFrame(
                detail: "no conversation yet — turn auto on during the call to build notes"))
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
