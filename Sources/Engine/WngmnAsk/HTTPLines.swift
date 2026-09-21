import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// A response read a line at a time, as it arrives.
///
/// This was `URLSession.bytes(for:)` and `.lines`, which the open-source Foundation that
/// Linux and Windows use does not have, and which kept the whole Claude client on Apple
/// platforms. A data delegate is the same thing built from parts every Foundation has, and
/// it is used on macOS too, so the path the Linux build runs is the path CI tests on both.
///
/// One session for every request, so one connection is opened and kept. The first version of
/// this opened a session per request, which is a TCP and a TLS handshake per answer; on the
/// Wi-Fi of a real call on 21 September, 80 of that call's 272 requests failed as TLS errors
/// and dropped connections, where the call before, on a shared session, lost 6 of 356.
final class HTTPLines: @unchecked Sendable {
    /// The one every answer goes through.
    static let shared = HTTPLines()

    private let session: URLSession
    private let router: Router

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let router = Router()
        self.router = router
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, any Error>) {
        let (lines, sink) = AsyncThrowingStream<String, any Error>.makeStream()
        let task = session.dataTask(with: request)
        let reader = Reader(lines: sink)
        router.add(reader, for: task.taskIdentifier)
        // A reader that stops reading — auto cancelling an answer a screenshot has overtaken —
        // stops the request with it, or the answer goes on streaming, and being paid for,
        // into nothing. Cancelling a request does not close the shared connection.
        sink.onTermination = { _ in task.cancel() }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.awaitStatus(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (status, lines)
    }

    /// The session's one delegate, handing each task's callbacks to that task's reader.
    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let readers = Mutex<[Int: Reader]>([:])

        func add(_ reader: Reader, for task: Int) { readers.withLock { $0[task] = reader } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let reader = readers.withLock { $0[dataTask.taskIdentifier] }
            reader?.received(data, on: dataTask)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let reader = readers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
            reader?.completed(task, error: error)
        }
    }

    private final class Reader: @unchecked Sendable {
        private struct State {
            var status: CheckedContinuation<Int, any Error>?
            var buffer = LineBuffer()
        }
        private let state = Mutex(State())
        private let lines: AsyncThrowingStream<String, any Error>.Continuation

        init(lines: AsyncThrowingStream<String, any Error>.Continuation) {
            self.lines = lines
        }

        func awaitStatus(_ continuation: CheckedContinuation<Int, any Error>) {
            state.withLock { $0.status = continuation }
        }

        /// The status is read off the task at the first byte, not from the response callback:
        /// that callback's signature differs between the two Foundations, and a method that
        /// only nearly matches an optional requirement is silently never called.
        func received(_ data: Data, on task: URLSessionTask) {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let (waiting, complete) = state.withLock { state in
                (state.status.take(), state.buffer.append(data))
            }
            waiting?.resume(returning: status)
            for line in complete { lines.yield(line) }
        }

        func completed(_ task: URLSessionTask, error: (any Error)?) {
            let (waiting, rest) = state.withLock { state in
                (state.status.take(), state.buffer.finish())
            }
            if let error {
                waiting?.resume(throwing: error)
                lines.finish(throwing: error)
            } else {
                waiting?.resume(returning: (task.response as? HTTPURLResponse)?.statusCode ?? 0)
                if let rest { lines.yield(rest) }
                lines.finish()
            }
        }
    }
}

/// Bytes in, whole lines out, however the bytes were cut up on the way.
///
/// Split on the byte, not the character: 0x0A is never part of a multi-byte UTF-8 sequence,
/// so a character that straddles two reads is decoded whole. Pure, so that how a stream is
/// cut — which a transport decides and a test cannot — can be tested cut by cut.
struct LineBuffer {
    private var pending = Data()

    /// The lines this completes, without their endings.
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var found: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            found.append(Self.decode(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return found
    }

    /// What is left when the stream ends: a last line with no newline after it, if any.
    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    /// Server-Sent Events end a line with LF, CRLF or CR; the first two are all this API sends.
    private static func decode(_ bytes: Data) -> String {
        var line = bytes
        if line.last == 0x0D { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
}
