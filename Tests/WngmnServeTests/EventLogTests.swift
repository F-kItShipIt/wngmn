import Foundation
import Testing
@testable import WngmnServe

/// The on-disk transcript, and picking one back up after a restart.
///
/// The replay buffer lives in memory, so a wngmn that dies mid-interview takes the
/// transcript with it and every connected page is caught up from nothing. Writing the same
/// durable lines to a file makes that recoverable, and costs almost nothing to do: only
/// replayable events are written, so the rate is a few lines a minute rather than the
/// several a second speech-in-progress arrives at.
@Suite("Event log")
struct EventLogTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-log-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("A new session starts empty and numbers from one")
    func newSession() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir)
        #expect(log.restored.isEmpty)
        #expect(log.nextID == 1)
    }

    /// The file is the same JSON Lines the tool already writes to stdout, so anything that
    /// reads one reads the other. That rules out a wrapper carrying the id.
    @Test("The file is plain JSON Lines, one event per line")
    func writesJSONLines() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir)
        log.append(id: 1, line: #"{"type":"question","text":"First"}"#)
        log.append(id: 2, line: #"{"type":"question","text":"Second"}"#)
        log.flush()

        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == #"{"type":"question","text":"First"}"#)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
                    "not parseable as JSON: \(line)")
        }
    }

    /// The id is the line's position in the file. That is what lets the file stay free of a
    /// wrapper, and it holds because only events that are given an id are ever written.
    @Test("Resuming restores the previous session and continues its numbering")
    func resumes() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        first.append(id: 1, line: #"{"type":"question","text":"Before the crash"}"#)
        first.append(id: 2, line: #"{"type":"question","text":"Also before"}"#)
        first.flush()

        let resumed = try EventLog(directory: dir, resuming: true)
        #expect(resumed.restored.map(\.id) == [1, 2])
        #expect(resumed.restored.first?.line.contains("Before the crash") == true)
        #expect(resumed.nextID == 3, "a resumed session must not reissue ids")
        #expect(resumed.url.resolvingSymlinksInPath() == first.url.resolvingSymlinksInPath(),
                "resuming should continue the same file")
    }

    /// Restarting deliberately is how a new interview begins, and inheriting the previous
    /// one's transcript would be worse than losing it.
    @Test("Without resuming, a new file starts and the old one is left alone")
    func doesNotResumeByDefault() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        first.append(id: 1, line: #"{"type":"question","text":"Yesterday"}"#)
        first.flush()

        let second = try EventLog(directory: dir)
        #expect(second.restored.isEmpty)
        #expect(second.nextID == 1)
        #expect(second.url.resolvingSymlinksInPath() != first.url.resolvingSymlinksInPath())
        #expect(try String(contentsOf: first.url, encoding: .utf8).contains("Yesterday"))
    }

    /// The file may grow all call; what is read back into the replay buffer must not. The
    /// ids still have to describe where the tail sat in the whole file, or a page resuming
    /// from an id in the middle would be sent the wrong events.
    @Test("Restoring is capped, and the ids still match the file")
    func restoreIsCapped() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        for i in 1...50 {
            first.append(id: i, line: #"{"type":"question","text":"Q\#(i)"}"#)
        }
        first.flush()

        let resumed = try EventLog(directory: dir, resuming: true, restoreLimit: 10)
        #expect(resumed.restored.count == 10)
        #expect(resumed.restored.map(\.id) == Array(41...50))
        #expect(resumed.restored.last?.line.contains("Q50") == true)
        #expect(resumed.nextID == 51, "numbering continues from the file, not from the tail")
    }

    /// Nothing to resume is the normal case on a first ever run, and it must not be an error.
    @Test("Resuming with no previous session is not a failure")
    func resumeWithNothingThere() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir, resuming: true)
        #expect(log.restored.isEmpty)
        #expect(log.nextID == 1)
    }

    /// Stopping and restarting from a shell takes well under a second, so this is the
    /// ordinary case rather than a race. Sharing a file would break the id-is-position
    /// invariant for good, because the second run numbers from 1 into a file that is not.
    @Test("Two sessions started in the same second do not share a file")
    func sameSecondSessionsAreDistinct() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        first.append(id: 1, line: #"{"type":"question","text":"First run"}"#)
        first.flush()
        let second = try EventLog(directory: dir)
        second.append(id: 1, line: #"{"type":"question","text":"Second run"}"#)
        second.flush()

        #expect(second.url.resolvingSymlinksInPath() != first.url.resolvingSymlinksInPath())
        let firstText = try String(contentsOf: first.url, encoding: .utf8)
        #expect(firstText.contains("First run"))
        #expect(!firstText.contains("Second run"), "the second run appended to the first's file")
    }

    /// The disambiguating suffix must sort AFTER the name it disambiguates. Compared as
    /// whole filenames it does not: "-" is 0x2D and "." is 0x2E, so "…42-02.jsonl" sorts
    /// before "…42.jsonl" and --resume would pick up the OLDER of two same-second sessions.
    @Test("A suffixed session is newer than the one it disambiguates")
    func suffixedSessionSortsLast() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Named by hand rather than by the clock. Left to the clock, the two only collided
        // when both opened inside one second, and on a loaded CI runner they did not: the
        // test failed for want of its own premise, having checked nothing about sorting.
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        for (name, text) in [("2020-01-01T00-00-00", "Older"), ("2020-01-01T00-00-00-02", "Newer")] {
            let log = try EventLog(directory: dir)
            log.append(id: 1, line: #"{"type":"question","text":"\#(text)"}"#)
            log.flush()
            try FileManager.default.moveItem(
                at: log.url, to: sessions.appendingPathComponent("\(name).jsonl"))
        }

        let resumed = try EventLog(directory: dir, resuming: true)
        #expect(resumed.restored.first?.line.contains("Newer") == true,
                "resumed the older of two same-second sessions: \(resumed.url.lastPathComponent)")
    }

    /// Power loss can leave a half-written final line. Appending after it would splice the
    /// next event onto the fragment, producing a line that is not JSON and shifting every id
    /// after it by one — permanently, in a file whose whole format is position-is-id.
    @Test("A truncated final line is dropped rather than appended to")
    func repairsATruncatedTail() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        first.append(id: 1, line: #"{"type":"question","text":"Complete"}"#)
        first.flush()
        first.close()
        // A fragment with no newline, as an interrupted write would leave.
        let handle = try FileHandle(forWritingTo: first.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"question","tex"#.utf8))
        try handle.close()

        let resumed = try EventLog(directory: dir, resuming: true)
        // The fragment must be gone from what is replayed as well as from the file. Repairing
        // one and not the other serves a page a frame that is not JSON, and leaves the next
        // id one past the line it will actually occupy.
        #expect(resumed.restored.count == 1, "the fragment was restored as an event: \(resumed.restored)")
        #expect(resumed.nextID == 2, "numbering counted the fragment: nextID \(resumed.nextID)")
        for entry in resumed.restored {
            #expect((try? JSONSerialization.jsonObject(with: Data(entry.line.utf8))) != nil,
                    "restored a line that is not JSON: \(entry.line)")
        }
        resumed.append(id: resumed.nextID, line: #"{"type":"question","text":"After"}"#)
        resumed.flush()

        let lines = try String(contentsOf: resumed.url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
                    "not valid JSON after resuming a truncated file: \(line)")
        }
        #expect(lines.count == 2, "expected the fragment dropped and one new line: \(lines)")
    }

    /// A run that fails to bind its port opens its log before it finds out and exits,
    /// leaving a zero-byte file with the newest name. Adopting that as "the most recent
    /// session" made --resume continue an empty stub while the real transcript — which the
    /// flag exists to recover — became unreachable through the tool.
    @Test("An empty session is not what --resume continues")
    func emptySessionIsNotResumed() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try EventLog(directory: dir)
        real.append(id: 1, line: #"{"type":"question","text":"The real transcript"}"#)
        real.flush()
        // The stub a failed bind leaves behind: newer name, nothing in it.
        let stub = try EventLog(directory: dir)
        stub.close()
        try #require(FileManager.default.fileExists(atPath: stub.url.path))

        let resumed = try EventLog(directory: dir, resuming: true)
        #expect(resumed.restored.first?.line.contains("The real transcript") == true,
                "resumed the empty stub instead of the transcript: \(resumed.url.lastPathComponent)")
    }

    /// And the stub should not be left lying there in the first place.
    @Test("An untouched log removes itself")
    func discardsAnEmptyLog() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir)
        let path = log.url.path
        log.discardIfEmpty()
        #expect(!FileManager.default.fileExists(atPath: path), "an empty session file was left behind")

        let used = try EventLog(directory: dir)
        used.append(id: 1, line: #"{"type":"status","state":"starting"}"#)
        used.flush()
        used.discardIfEmpty()
        #expect(FileManager.default.fileExists(atPath: used.url.path), "a written log was deleted")
    }

    /// Opening a log creates this run's file straight away, so "is there anything to
    /// resume?" has to discount it. Without that, a first ever run offers to resume itself.
    @Test("The session being written does not count as one to resume")
    func previousExcludesTheCurrentSession() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try EventLog(directory: dir)
        #expect(EventLog.previousSession(in: dir, excluding: first.url) == nil)

        let second = try EventLog(directory: dir)
        #expect(EventLog.previousSession(in: dir, excluding: second.url)?.resolvingSymlinksInPath()
                == first.url.resolvingSymlinksInPath())
    }

    /// So the startup line can offer `--resume` only when there is in fact something recent
    /// to resume, rather than advertising it into an empty directory.
    @Test("The most recent session can be found without opening a log")
    func findsTheLatestSession() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EventLog.mostRecentSession(in: dir) == nil)

        let log = try EventLog(directory: dir)
        log.append(id: 1, line: #"{"type":"question","text":"Hi"}"#)
        log.flush()
        #expect(EventLog.mostRecentSession(in: dir)?.resolvingSymlinksInPath()
                == log.url.resolvingSymlinksInPath())
    }

    /// Found while sweeping for side effects that land before the port bind. The tail repair
    /// decoded the whole file with `String(contentsOf:encoding:.utf8)` and fell back to `""`
    /// when that failed. A crash mid-append can stop inside a multi-byte character, which is
    /// exactly what makes a file invalid UTF-8 — so the fallback set `keep` to zero and
    /// truncated an entire good transcript to nothing. On the resume path the file being
    /// destroyed belongs to an earlier run, and `discardIfEmpty` then deletes the remains.
    @Test("A resumed transcript that was torn mid-character keeps its finished lines")
    func tornMultibyteTailDoesNotDestroyTheTranscript() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // Five finished lines, then an append that died halfway through an em dash.
        var bytes = Data()
        for i in 1...5 {
            bytes.append(Data(#"{"id":\#(i),"type":"question","text":"line \#(i)"}"# .utf8))
            bytes.append(0x0A)
        }
        let complete = bytes.count
        bytes.append(Data(#"{"id":6,"type":"question","text":"tore here "# .utf8))
        bytes.append(contentsOf: [0xE2, 0x80])   // first two bytes of an em dash, no third

        let file = sessions.appendingPathComponent("2026-01-01T00-00-00.jsonl")
        try bytes.write(to: file)
        #expect((try? String(contentsOf: file, encoding: .utf8)) == nil,
                "the fixture has to actually be invalid UTF-8 for this to test anything")

        let log = try EventLog(directory: dir, resuming: true)

        let after = try Data(contentsOf: file)
        #expect(after.count == complete,
                "the five finished lines must survive a torn multi-byte tail")
        #expect(log.restored.count == 5, "all five finished events should be restored")
        #expect(log.nextID == 6)

        // And the failed-bind path must not then delete somebody else's transcript.
        log.discardIfEmpty()
        #expect(FileManager.default.fileExists(atPath: file.path),
                "a transcript with content in it must survive discardIfEmpty")
    }
}

/// How often a durability sync is actually asked for.
///
/// `F_FULLFSYNC` measures 2.9 ms on this machine against 0.04 ms for plain `fsync`, so the
/// rate matters in a way it would not otherwise. It is not the question rate that makes it
/// matter: `Pipeline.consumeAudio` emits a `feed_failed` warning per iteration of a 5 ms
/// poll loop, and warnings are replayable, so a persistent feed failure asks for roughly 200
/// syncs a second — 580 ms of syncing per second of wall clock, which never drains.
///
/// Coalescing by in-flight backpressure rather than by a timer: a timer has to guess an
/// interval, and the classic way it goes wrong is leaving the tail unsynced, which would
/// strand precisely the last question of the interview.
@Suite("Sync coalescing")
struct SyncCoalescerTests {
    /// `#expect` takes an autoclosure, so a mutating call cannot happen inside one; every
    /// step is taken first and asserted after.
    @Test("The first request dispatches, the rest ride along")
    func firstRequestDispatches() {
        var c = SyncCoalescer()
        let first = c.request(), second = c.request(), third = c.request()
        #expect(first, "the first append must start a sync")
        #expect(second == false, "a second dispatch would run two syncs concurrently")
        #expect(third == false)
    }

    /// Everything that arrived while a sync was running is covered by one more pass, not by
    /// one pass each.
    @Test("Appends during a sync collapse into a single further pass")
    func collapsesIntoOnePass() {
        var c = SyncCoalescer()
        let dispatched = c.request()
        let firstPass = c.takeWork()
        _ = c.request(); _ = c.request(); _ = c.request()
        let secondPass = c.takeWork()
        let thirdPass = c.takeWork()
        #expect(dispatched)
        #expect(firstPass, "the dispatched pass has work")
        #expect(secondPass, "the three that arrived mid-sync need one more pass")
        #expect(thirdPass == false, "and only one")
    }

    /// The bug a timer-based version has: whatever arrives after the last tick is never
    /// synced. Here the pass that finds nothing left is the one that stands down.
    @Test("Draining fully lets the next append dispatch again")
    func drainsAndRearms() {
        var c = SyncCoalescer()
        _ = c.request()
        let work = c.takeWork()
        let drained = c.takeWork()
        let rearmed = c.request()
        #expect(work)
        #expect(drained == false)
        #expect(rearmed, "a later append must start a new sync, not be swallowed")
    }

    /// The `feed_failed` storm at its real rate. The count is the specification: too many and
    /// the sync queue never drains, none at all and the log is not durable.
    @Test("A 200-append storm asks for a handful of syncs, not two hundred")
    func stormIsBounded() {
        var c = SyncCoalescer()
        var syncs = 0
        for i in 1...200 {
            _ = c.request()
            // A slow device: the sync queue only gets to run every fiftieth append.
            if i % 50 == 0 { while c.takeWork() { syncs += 1 } }
        }
        while c.takeWork() { syncs += 1 }
        #expect(syncs == 4, "200 appends asked for \(syncs) syncs")
    }

    /// Whatever the interleaving, the last thing written is on disk once the dust settles.
    @Test("The final append is always covered")
    func neverStrandsTheTail() {
        var c = SyncCoalescer()
        _ = c.request()
        _ = c.takeWork()
        _ = c.request()          // arrives while that pass is running: the tail
        var passes = 0
        while c.takeWork() { passes += 1 }
        #expect(passes == 1, "the last append was left unsynced")
    }

}
