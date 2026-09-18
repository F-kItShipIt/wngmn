/// Decides what is sent to the model and when: one request at a time, and nothing lost while
/// it is out.
///
/// Items go in as they arrive; commands come out. While a request is in flight everything
/// else waits, in arrival order, and when that request settles everything that waited goes
/// out together as one batch — the way Claude Code delivers queued prompts — so the model
/// answers the conversation as it stands now rather than a backlog of stale turns one by one.
///
/// It exists because "one at a time" used to be an accident of how an actor was scheduled,
/// and the accident had a hole. `AutoAnswerer` awaited each answer inline, actors are
/// re-entrant, and so the half-second ticker could close a turn and start a second request
/// while the first was still streaming. The ledger then held both user turns before either
/// reply. Here it is a property of a value type instead.
///
/// Pure and time-free, like `TurnBatcher`: no clock, no task, no actor. Generic over the item
/// so that this target never learns what a turn or a screenshot is.
public struct AnswerQueue<Item: Sendable>: Sendable {
    public enum Command: Sendable {
        /// Nothing to do.
        case none
        /// Make one request carrying every item in `batch`, in this order.
        case send(id: Int, batch: [Item])
        /// Cancel the request with this id. The next `send` comes from `settled`, not from here.
        case cancel(id: Int)
    }

    private var pending: [Item] = []
    private var inFlight: Int?
    private var nextID = 1

    public init() {}

    /// Nothing in flight and nothing waiting.
    public var isIdle: Bool { inFlight == nil && pending.isEmpty }

    /// An item arrived. `preempts` is for the item that must not wait behind an answer nobody
    /// needs any more — a screenshot, which is usually cutting in on "let me paste this here".
    public mutating func enqueue(_ item: Item, preempts: Bool = false) -> Command {
        pending.append(item)
        guard let id = inFlight else { return sendPending() }
        // Cancel only. Sending here as well would put two requests in flight for as long as
        // the cancelled one takes to unwind.
        return preempts ? .cancel(id: id) : .none
    }

    /// The request with this id is over — finished, failed or cancelled; to the queue they are
    /// the same event. A stale id is ignored, so a late settle cannot free a slot that a newer
    /// request now holds.
    public mutating func settled(_ id: Int) -> Command {
        guard inFlight == id else { return .none }
        inFlight = nil
        return pending.isEmpty ? .none : sendPending()
    }

    private mutating func sendPending() -> Command {
        let id = nextID
        nextID += 1
        inFlight = id
        let batch = pending
        pending = []
        return .send(id: id, batch: batch)
    }
}

extension AnswerQueue.Command: Equatable where Item: Equatable {}
