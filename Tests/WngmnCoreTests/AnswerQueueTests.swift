import Testing
@testable import WngmnCore

/// One request at a time, and nothing lost while it is out.
///
/// The answerer used to await each answer inline on a re-entrant actor, so a turn closed by
/// the ticker while an answer was streaming started a second request beside the first, and
/// the ledger recorded both user turns before either reply. The queue makes "one in flight"
/// a property of a value type that can be tested without a network, rather than something
/// an actor's scheduling happens to provide.
@Suite("AnswerQueue")
struct AnswerQueueTests {
    typealias Queue = AnswerQueue<String>

    @Test("The first item is sent at once, on its own")
    func firstItemIsSent() {
        var q = Queue()
        #expect(q.enqueue("a") == .send(id: 1, batch: ["a"]))
    }

    @Test("An item that arrives while a request is in flight waits")
    func itemWaitsWhileInFlight() {
        var q = Queue()
        _ = q.enqueue("a")
        #expect(q.enqueue("b") == .none)
    }

    /// Delivered together, the way Claude Code delivers queued prompts: the model answers the
    /// conversation as it stands now, not a backlog of stale turns one at a time.
    @Test("Everything that waited goes out together, in arrival order, when the request settles")
    func waitingItemsGoOutTogether() {
        var q = Queue()
        _ = q.enqueue("a")
        _ = q.enqueue("b")
        _ = q.enqueue("c")
        #expect(q.settled(1) == .send(id: 2, batch: ["b", "c"]))
    }

    @Test("With nothing waiting, settling sends nothing")
    func nothingWaitingNothingSent() {
        var q = Queue()
        _ = q.enqueue("a")
        #expect(q.settled(1) == .none)
        #expect(q.isIdle)
    }

    /// The send follows from the cancelled request settling, never from the enqueue. Sending on
    /// enqueue would put two requests in flight for as long as the cancelled one takes to
    /// unwind — the very thing this type exists to rule out.
    @Test("A pre-empting item cancels the request in flight and waits for it to settle")
    func preemptingItemCancels() {
        var q = Queue()
        _ = q.enqueue("speech")
        #expect(q.enqueue("urgent", preempts: true) == .cancel(id: 1))
        #expect(q.settled(1) == .send(id: 2, batch: ["urgent"]))
    }

    @Test("A pre-empting item carries along whatever was already waiting, in order")
    func preemptingItemKeepsOrder() {
        var q = Queue()
        _ = q.enqueue("a")
        _ = q.enqueue("b")
        #expect(q.enqueue("urgent", preempts: true) == .cancel(id: 1))
        #expect(q.settled(1) == .send(id: 2, batch: ["b", "urgent"]))
    }

    @Test("A pre-empting item with nothing in flight is simply sent")
    func preemptingItemWhenIdle() {
        var q = Queue()
        #expect(q.enqueue("urgent", preempts: true) == .send(id: 1, batch: ["urgent"]))
    }

    @Test("An ordinary item never cancels")
    func ordinaryItemNeverCancels() {
        var q = Queue()
        _ = q.enqueue("a")
        #expect(q.enqueue("b", preempts: false) == .none)
    }

    /// A late settle for a request that was already replaced must not free the slot the
    /// current request holds, or the next enqueue would send beside it.
    @Test("Settling a request that is not the one in flight changes nothing")
    func staleSettleIsIgnored() {
        var q = Queue()
        _ = q.enqueue("a")
        _ = q.enqueue("b")
        _ = q.settled(1)                       // request 2 is now in flight
        #expect(q.settled(1) == .none)
        #expect(q.enqueue("c") == .none, "request 2 still holds the slot")
    }

    @Test("The queue is idle only when nothing is in flight and nothing waits")
    func idleness() {
        var q = Queue()
        #expect(q.isIdle)
        _ = q.enqueue("a")
        #expect(!q.isIdle)
        _ = q.settled(1)
        #expect(q.isIdle)
    }
}
