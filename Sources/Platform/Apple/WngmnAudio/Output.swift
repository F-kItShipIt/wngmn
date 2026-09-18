import Foundation
import WngmnCore
import Synchronization

/// Writes the JSON Lines stream to stdout, and diagnostics to stderr.
///
/// Line buffering is set explicitly with `setvbuf` rather than flushed per write.
/// `FileHandle.standardOutput.synchronizeFile()` is the obvious alternative and it
/// **crashes when stdout is a pipe** — `NSFileHandleOperationException, Invalid argument` —
/// while working fine on a TTY, so it passes an interactive smoke test and dies the moment
/// anyone runs `wngmn | jq`.
public final class EventWriter: Sendable {
    private let encoder = EventEncoder()
    private let lock = Mutex<Bool>(false)  // true once the reader has gone away
    private let sink: (@Sendable (Event) -> Void)?
    private let observer: (@Sendable (Event, String) -> Void)?

    /// - Parameters:
    ///   - sink: when supplied, events go here instead of to stdout. Used by tests to run
    ///     the real pipeline and assert on what it emitted.
    ///   - observer: receives every event and its encoded line, *in addition* to the normal
    ///     output. The event comes with the line so the observer can tell durable events
    ///     from superseded ones without parsing the JSON back out. This is
    ///     how the transcript server sees the stream without a second write path — the
    ///     EPIPE and SIGPIPE handling below is subtle enough that having one copy of it
    ///     matters more than the indirection costs.
    public init(
        lineBuffered: Bool = true,
        sink: (@Sendable (Event) -> Void)? = nil,
        observer: (@Sendable (Event, String) -> Void)? = nil
    ) {
        self.sink = sink
        self.observer = observer
        if lineBuffered, sink == nil { setvbuf(stdout, nil, _IOLBF, 0) }
        // SIGPIPE's default disposition kills the process outright — measured exit 141 when
        // piping into `head -1` — which skips every teardown path and leaks the private
        // aggregate device. Ignoring it turns the same event into an EPIPE we can handle.
        signal(SIGPIPE, SIG_IGN)
    }

    public func emit(_ event: Event) {
        if let sink {
            sink(event)
            if let observer { observer(event, encoder.line(event)) }
            return
        }
        let line = encoder.line(event)
        // Before the stdout write, so a browser still receives events after the reader on
        // the pipe has gone away.
        observer?(event, line)
        let closed = lock.withLock { closed -> Bool in
            if closed { return true }
            if !EventWriter.write(line + "\n") {
                closed = true
                return true
            }
            return false
        }
        if closed, case .error = event { EventWriter.note(encoder.line(event)) }
    }

    /// True once stdout's reader has gone away. The caller should shut down cleanly rather
    /// than keep transcribing into a closed pipe.
    public var readerIsGone: Bool { lock.withLock { $0 } }

    /// Diagnostics, so `wngmn | jq` stays clean.
    public static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                fwrite(raw.baseAddress!.advanced(by: offset), 1, bytes.count - offset, stdout)
            }
            if written <= 0 {
                // EPIPE rather than a fatal signal, because SIGPIPE is ignored above.
                return !(errno == EPIPE || ferror(stdout) != 0)
            }
            offset += written
        }
        return true
    }
}
