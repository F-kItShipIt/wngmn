import Foundation
import Synchronization

/// The durable half of the transcript, written to a file as it happens.
///
/// The replay buffer that catches a late or reconnecting page up lives in memory, so a
/// wngmn that dies mid-interview takes the transcript with it: every page reconnects to
/// a server that has nothing to tell it. This is the same data on disk.
///
/// Only events worth replaying are written — see `Event.isReplayable` — which is what makes
/// it cheap. Speech in progress arrives several times a second and is superseded almost
/// immediately; questions and warnings arrive a few times a minute. The write rate follows
/// the second number, so a plain synchronous append is affordable and there is no buffering
/// machinery to lose data in.
///
/// **The id of a line is its position in the file.** That is why the file needs no wrapper
/// around each event and stays byte-for-byte the JSON Lines the tool already writes to
/// stdout, readable by anything that reads one. The invariant holds because a line is
/// written if and only if it was issued an id, under the same lock.
/// Decides how often a durability sync is actually asked for.
///
/// One sync in flight, one queued behind it, everything else riding along with whichever of
/// those has not started yet. Coalescing by backpressure rather than by a timer: a timer has
/// to guess an interval, and the classic way it goes wrong is leaving whatever arrived after
/// the last tick unsynced — which here would strand precisely the last question of the call.
/// This version has no interval to get wrong and self-tunes to the device.
struct SyncCoalescer {
    private var dirty = false
    private var inFlight = false

    /// A line was written. True when the caller should dispatch a sync pass; false when one
    /// is already running and will pick this up before it stands down.
    mutating func request() -> Bool {
        dirty = true
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Called at the top of a sync pass. True when there is something to sync; false stands
    /// the pass down, and the next `request` will dispatch a new one.
    mutating func takeWork() -> Bool {
        guard dirty else {
            inFlight = false
            return false
        }
        dirty = false
        return true
    }
}

public final class EventLog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: Int
        public let line: String
    }

    /// The file this session appends to.
    public let url: URL
    /// The tail of a resumed session, ready to seed the replay buffer. Empty otherwise.
    public let restored: [Entry]
    /// The id to issue next. Counts the whole resumed file, not just the restored tail.
    public let nextID: Int

    private let handle: Mutex<FileHandle>
    private let coalescer = Mutex(SyncCoalescer())
    /// Serial, so syncs never overlap and never run on the thread that wrote the line.
    private let syncQueue = DispatchQueue(label: "wngmn.eventlog.sync")
    /// Latched, so a failing disk produces one line rather than one per event — the storm it
    /// would otherwise cause is the same one the coalescer exists to prevent.
    private let reportedFailure = Mutex(false)

    /// - Parameters:
    ///   - directory: the parent; sessions live in `sessions/` under it.
    ///   - resuming: continue the most recent session rather than starting one. Off by
    ///     default because restarting is also how a *new* interview begins, and inheriting
    ///     the previous one's transcript is worse than losing it.
    ///   - restoreLimit: how much of a resumed file to read back into memory. The file may
    ///     grow all call; the replay buffer must not.
    public init(directory: URL, resuming: Bool = false, restoreLimit: Int = 400) throws {
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // A session with nothing in it is not a session to continue. A run that fails to bind
        // its port creates its file before it discovers that and exits, leaving a zero-byte
        // stub with the newest name; adopting it would make the real transcript unreachable
        // through `--resume`, which is the one thing `--resume` exists to prevent.
        let existing = resuming ? EventLog.mostRecentSession(in: directory) : nil
        url = existing ?? EventLog.newSessionURL(in: sessions)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let file = try FileHandle(forWritingTo: url)
        _ = try? file.seekToEnd()

        // Repaired BEFORE anything is read back, not after. Power loss can leave a final line
        // with no terminator; appending after it would splice the next event onto the
        // fragment, and counting it would put every later id one past the line it occupies.
        // Truncating the file but restoring from the text as it was before left the fragment
        // being replayed to pages as a frame that is not JSON — a repair in one place only.
        if let size = try? file.offset(), size > 0 {
            try? file.seek(toOffset: max(0, size - 1))
            if (try? file.read(upToCount: 1)) != Data("\n".utf8) {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let keep = text.lastIndex(of: "\n").map {
                    text.distance(from: text.startIndex, to: $0) + 1
                } ?? 0
                try? file.truncate(atOffset: UInt64(Data(text.prefix(keep).utf8).count))
            }
            _ = try? file.seekToEnd()
        }
        handle = Mutex(file)

        guard existing != nil, let text = try? String(contentsOf: url, encoding: .utf8) else {
            restored = []
            nextID = 1
            return
        }
        // Blank lines are kept while counting, because a line's position is its id and a
        // blank one still occupies a position; they are dropped from what is restored,
        // having nothing in them to replay.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // the terminator of the final line
        nextID = lines.count + 1
        let start = max(0, lines.count - restoreLimit)
        restored = lines[start...].enumerated().compactMap { offset, line in
            // `start` is a zero-based index and ids are one-based, so the first kept line is
            // id `start + 1`.
            line.isEmpty ? nil : Entry(id: start + offset + 1, line: line)
        }
    }

    /// Appends one event. `id` is not written — it is the line's position — but is taken so
    /// callers cannot forget that the two have to stay in step.
    ///
    /// Failures are swallowed deliberately. A full disk is not a reason to interrupt an
    /// interview, and the in-memory buffer still serves every connected page; the log simply
    /// stops being a complete record.
    public func append(id: Int, line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle.withLock { try? $0.write(contentsOf: data) }
    }

    /// Asks for the file to be made durable, soon and at most once at a time.
    ///
    /// Deliberately not part of `append`. `append` runs inside the transcript server's state
    /// lock, and strictly before the SSE frame is sent to any page, so a 2.9 ms sync there
    /// would be added to the question-to-screen latency that the page itself charts against
    /// a 700 ms budget. Durability is a property of the file rather than of one line, so it
    /// does not need to be on that path.
    public func syncSoon() {
        let dispatch = coalescer.withLock { $0.request() }
        guard dispatch else { return }
        syncQueue.async { [self] in
            while coalescer.withLock({ $0.takeWork() }) { fullSync() }
        }
    }

    /// Makes everything written so far survive power loss, synchronously.
    ///
    /// `F_FULLFSYNC`, not `fsync`. On macOS `fsync(2)` says so itself: "if the drive loses
    /// power or the OS crashes, the application may find that only some or none of their
    /// data was written", because it does not make the drive flush its own write cache.
    /// Plain `fsync` therefore buys nothing here — a process crash already loses nothing,
    /// which was measured with SIGKILL — and power loss is the only failure left to address.
    /// Measured on an Apple Silicon internal SSD: fsync 0.04 ms, F_FULLFSYNC 2.9 ms.
    ///
    /// Raw `fcntl` rather than `FileHandle.synchronize()` for two reasons: `synchronize()`
    /// is plain `fsync`, and it wraps failures in an error that loses the errno this needs.
    private func fullSync() {
        let failure: Int32? = handle.withLock { handle in
            while fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                // Documented for fsync and inherited here: a signal is not a disk failure.
                if errno == EINTR { continue }
                return errno
            }
            return nil
        }
        guard let failure else { return }
        let detail = String(cString: strerror(failure))
        let first = reportedFailure.withLock { reported -> Bool in
            if reported { return false }
            reported = true
            return true
        }
        // Reported, then dropped. A disk that cannot be synced is not a reason to interrupt
        // an interview, every connected page still has the transcript live, and appends may
        // start landing again — a partial log beats none. Written to stderr directly because
        // WngmnServe depends only on WngmnCore, so `EventWriter.note` is out of reach;
        // emitting an Event instead would re-enter the server lock this is called under.
        if first {
            FileHandle.standardError.write(
                Data("wngmn: the transcript log is no longer durable: \(detail)\n".utf8)
            )
        }
    }

    /// Drains any pending sync and makes the file durable before returning. Called on
    /// shutdown, and by tests that read the file back.
    public func flush() {
        syncQueue.sync {}                                  // let an in-flight pass finish
        coalescer.withLock { _ = $0.takeWork() }            // claim whatever is outstanding
        fullSync()
    }

    public func close() {
        handle.withLock { try? $0.close() }
    }

    /// Removes the session file if nothing was ever written to it.
    ///
    /// Opening the log happens before the server finds out it cannot bind its port, so a
    /// failed start would otherwise leave a zero-byte file carrying the newest name — litter
    /// that `--resume` then had to be taught to ignore. Cheaper to not create it.
    public func discardIfEmpty() {
        let empty: Bool = handle.withLock { handle in
            (try? handle.offset()).map { $0 == 0 } ?? false
        }
        guard empty else { return }
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The newest session file, or nil when there is none.
    ///
    /// By name rather than by modification date: the names sort chronologically by
    /// construction, and a date is whatever the last thing to touch the file decided —
    /// a backup tool restoring one would otherwise make it look like the latest session.
    public static func mostRecentSession(in directory: URL) -> URL? {
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && EventLog.hasContent($0) }
            .max { EventLog.order($0) < EventLog.order($1) }
    }

    /// Whether a session file holds anything worth continuing.
    ///
    /// A run that fails to bind its port opens its log before it finds out and exits, leaving
    /// a zero-byte file with the newest name. Treating that as the most recent session made
    /// `--resume` adopt it and the real transcript unreachable — the exact failure the flag
    /// exists to prevent, triggered by the very situation the tool warns about.
    private static func hasContent(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        return (size ?? 0) > 0
    }

    /// Sort key for session names: the name without its extension.
    ///
    /// Comparing whole filenames puts a disambiguated session BEFORE the one it
    /// disambiguates — "-" is 0x2D and "." is 0x2E, so `…42-02.jsonl` < `…42.jsonl` — and
    /// `--resume` would then continue the older of two sessions started in the same second.
    /// Dropping the extension makes the bare name a prefix of the suffixed one, which sorts
    /// the way the names were designed to read.
    private static func order(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// A name no existing session has.
    ///
    /// The suffix is not decoration. Restarting twice inside one second — which is what
    /// stopping and starting from a shell looks like — would otherwise hand the second run
    /// the first run's file, and it would append to it while numbering from 1. The invariant
    /// that a line's position is its id would then be broken for that file permanently, and
    /// silently: nothing reads it back until a `--resume` weeks later.
    private static func newSessionURL(in sessions: URL) -> URL {
        let base = stamp()
        var candidate = sessions.appendingPathComponent("\(base).jsonl")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            // Zero-padded so the names keep sorting chronologically past nine.
            candidate = sessions.appendingPathComponent("\(base)-\(String(format: "%02d", n)).jsonl")
            n += 1
        }
        return candidate
    }

    /// The newest session that is not `excluding`.
    ///
    /// Opening a log creates this run's file immediately, so asking "is there an earlier
    /// session to offer `--resume` for?" against the bare directory always answers yes — the
    /// run doing the asking. This is that question, asked correctly.
    public static func previousSession(in directory: URL, excluding: URL) -> URL? {
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil
        )) ?? []
        let current = excluding.resolvingSymlinksInPath()
        return files
            .filter { $0.pathExtension == "jsonl" && $0.resolvingSymlinksInPath() != current }
            .max { EventLog.order($0) < EventLog.order($1) }
    }

    /// Sortable as text, and legible: `2026-09-10T18-30-05`. Colons are not in it because a
    /// filename carrying one is a running argument with the rest of the toolchain.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}
