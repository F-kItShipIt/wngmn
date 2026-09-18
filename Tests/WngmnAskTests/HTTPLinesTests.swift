#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import WngmnAsk

/// A server in the test process: each request is answered from a script registered under its
/// path, so tests running in parallel never read each other's.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status = 200
        var chunks: [Data] = []
    }

    private static let scripts = Mutex<[String: Script]>([:])

    static func serve(_ script: Script) -> URL {
        let path = "/\(UUID().uuidString)"
        scripts.withLock { $0[path] = script }
        return URL(string: "https://stub.test\(path)")!
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = Self.scripts.withLock({ $0[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Reading a streamed response a line at a time, on every platform.
///
/// It was `URLSession.bytes(for:)` and `.lines`, which the open-source Foundation does not
/// have — the one thing that kept the Claude client off Linux. Nothing tested it then: every
/// answer went through it and no test did.
@Suite("Streamed lines")
struct HTTPLinesTests {
    func read(_ script: StubProtocol.Script) async throws -> (status: Int, lines: [String]) {
        let url = StubProtocol.serve(script)
        let (status, stream) = try await HTTPLines.send(URLRequest(url: url), configuration: StubProtocol.configuration)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        return (status, lines)
    }

    @Test("Lines arrive as lines, with their endings off")
    func lines() async throws {
        let read = try await read(.init(chunks: [Data("data: one\r\n\ndata: two\n".utf8), Data("last".utf8)]))
        #expect(read.status == 200)
        #expect(read.lines.filter { !$0.isEmpty } == ["data: one", "data: two", "last"])
    }

    /// An error comes back as a status and a body, and the body is the reason.
    @Test("A refused request reports the server's status, and its body is still readable")
    func errorStatus() async throws {
        let read = try await read(.init(status: 429, chunks: [Data(#"{"error":{"message":"slow down"}}"#.utf8)]))
        #expect(read.status == 429)
        #expect(read.lines.joined().contains("slow down"))
    }

    @Test("A response with no body at all still reports its status")
    func emptyBody() async throws {
        let read = try await read(.init(status: 204))
        #expect(read.status == 204)
        #expect(read.lines.filter { !$0.isEmpty }.isEmpty)
    }

    /// The whole point of streaming. Nothing here can tell a transport that streams from one
    /// that waits for the end — URLSession holds a stub's data back until it finishes — so
    /// this is a real socket, holding the response open after one line.
    @Test("A line arrives while the response is still open")
    func streams() async throws {
        let server = try OneLineServer()
        let (status, stream) = try await HTTPLines.send(URLRequest(url: server.url))
        #expect(status == 200)
        var lines = stream.makeAsyncIterator()
        let first = try await lines.next()
        #expect(first == "data: first")
        #expect(!server.peerClosed, "the premise: the response is still open")
    }

    /// Auto cancels a request that a screenshot has overtaken. A reader that stops reading
    /// must stop the request with it, or the answer goes on streaming, and being paid for,
    /// into nothing.
    @Test("Walking away from the lines closes the connection")
    func cancellation() async throws {
        let server = try OneLineServer()
        let readOne = Mutex(false)
        let reader = Task {
            let (_, stream) = try await HTTPLines.send(URLRequest(url: server.url))
            for try await _ in stream { readOne.withLock { $0 = true } }
        }
        // Walked away from mid-body, after the status and a line: the request is under way
        // and only the lines are left to stop it.
        for _ in 0..<500 where !readOne.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(readOne.withLock { $0 })
        #expect(!server.peerClosed, "the premise: nothing has closed it yet")
        reader.cancel()
        for _ in 0..<500 where !server.peerClosed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.peerClosed)
    }
}

/// One connection on a loopback port: an event-stream response, one line, and then nothing,
/// held open until the other end hangs up. Plain sockets, so it runs wherever the tests do.
final class OneLineServer: @unchecked Sendable {
    let url: URL
    private let listener: Int32
    private let closed = Mutex(false)
    var peerClosed: Bool { closed.withLock { $0 } }

    init() throws {
        #if os(Linux)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(listener, raw, length) == 0 && listen(listener, 1) == 0
                    && getsockname(listener, raw, &length) == 0
            }
        }
        guard bound else { close(listener); throw URLError(.cannotConnectToHost) }
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/")!

        Thread.detachNewThread { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection); close(listener) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = [UInt8]()
            while !request.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) {
                let n = recv(connection, &buffer, buffer.count, 0)
                guard n > 0 else { return }
                request += buffer[0..<n]
            }
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\ndata: first\n\n"
            _ = reply.utf8CString.withUnsafeBufferPointer { send(connection, $0.baseAddress, $0.count - 1, 0) }
            // Held open until the reader hangs up, which is the thing under test.
            while recv(connection, &buffer, buffer.count, 0) > 0 {}
            self.closed.withLock { $0 = true }
        }
    }
}

/// How the bytes arrive is the transport's business, and URLSession will not be told: it
/// hands a stub's separate chunks to the delegate as one read. So the cutting is tested here,
/// cut by cut.
@Suite("Line buffer")
struct LineBufferTests {
    func lines(_ chunks: [[UInt8]]) -> [String] {
        var buffer = LineBuffer()
        var out = chunks.flatMap { buffer.append(Data($0)) }
        if let rest = buffer.finish() { out.append(rest) }
        return out
    }

    @Test("A line split across two reads arrives whole")
    func splitLine() {
        #expect(lines([Array("data: {\"a\":".utf8), Array("1}\n\ndata: two\n".utf8)])
                == [#"data: {"a":1}"#, "", "data: two"])
    }

    @Test("CRLF endings are stripped, as Server-Sent Events allow either")
    func crlf() {
        #expect(lines([Array("one\r\ntwo\r".utf8), Array("\n".utf8)]) == ["one", "two"])
    }

    @Test("A last line with no newline after it is not lost, and nothing is left behind")
    func unterminated() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("one\ntwo".utf8)) == ["one"])
        #expect(buffer.finish() == "two")
        #expect(buffer.finish() == nil)
    }

    /// A character that straddles two reads must not come out as two replacement characters.
    @Test("A character split across two reads is decoded whole")
    func splitCharacter() {
        #expect(lines([[0x63, 0x61, 0x66, 0xC3], [0xA9, 0x0A]]) == ["café"])
    }
}

@Suite("Claude client stream")
struct ClaudeClientStreamTests {
    func client(status: Int, lines: [String]) -> ClaudeClient {
        ClaudeClient(configuration: .init()) { _ in
            let (stream, sink) = AsyncThrowingStream<String, any Error>.makeStream()
            for line in lines { sink.yield(line) }
            sink.finish()
            return (status, stream)
        }
    }

    @Test("Text arrives as it streams, and the stop ends it")
    func text() async throws {
        let seen = Mutex<[String]>([])
        try await client(status: 200, lines: [
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}"#,
            #"data: {"type":"message_stop"}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after the stop"}}"#,
        ]).stream(system: "", messages: [.init(role: "user", text: "Hi")], credentials: .apiKey("k")) { text in
            seen.withLock { $0.append(text) }
        }
        #expect(seen.withLock { $0 } == ["Hello", ", world"])
    }

    @Test("A refused request is a failure carrying the server's own reason")
    func httpError() async throws {
        do {
            try await client(status: 529, lines: [#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
                .stream(system: "", messages: [.init(role: "user", text: "Hi")], credentials: .apiKey("k")) { _ in }
            Issue.record("a 529 was taken for an answer")
        } catch let failure as ClaudeClient.Failure {
            #expect("\(failure)".contains("529"))
            #expect("\(failure)".contains("Overloaded"))
        }
    }
}
