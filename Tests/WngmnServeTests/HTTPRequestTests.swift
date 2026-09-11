import Foundation
import Testing
@testable import WngmnServe

@Suite("HTTPRequest")
struct HTTPRequestTests {
    @Test("A well-formed request line yields method and path")
    func parsesRequestLine() {
        let r = HTTPRequest(raw: "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(r?.method == "GET")
        #expect(r?.path == "/events")
    }

    @Test("A query string is split off the path and decoded")
    func parsesQuery() {
        let r = HTTPRequest(raw: "GET /events?t=abc123&x=1 HTTP/1.1\r\n\r\n")
        #expect(r?.path == "/events")
        #expect(r?.query["t"] == "abc123")
        #expect(r?.query["x"] == "1")
    }

    @Test("Percent-encoded query values are decoded")
    func decodesPercentEncoding() {
        let r = HTTPRequest(raw: "GET /?t=a%2Fb HTTP/1.1\r\n\r\n")
        #expect(r?.query["t"] == "a/b")
    }

    // A partial read must not be mistaken for a complete request: the listener would
    // answer a request whose path it has not finished reading.
    @Test("A request with no header terminator is incomplete")
    func rejectsUnterminatedRequest() {
        #expect(HTTPRequest(raw: "GET /events HTTP/1.1\r\nHost: 127") == nil)
    }

    @Test("Garbage is rejected rather than parsed into a path")
    func rejectsGarbage() {
        #expect(HTTPRequest(raw: "\r\n\r\n") == nil)
        #expect(HTTPRequest(raw: "GET\r\n\r\n") == nil)
    }
}

@Suite("Server-Sent Events framing")
struct SSETests {
    @Test("A frame is a data line terminated by a blank line")
    func framesData() {
        #expect(SSE.frame(#"{"type":"partial"}"#) == "data: {\"type\":\"partial\"}\n\n")
    }

    // A JSON Lines payload can legally contain an escaped newline, but a raw one would
    // split the frame and desynchronise every later event on the connection.
    @Test("An embedded newline is split across data lines, never breaking the frame")
    func handlesEmbeddedNewline() {
        #expect(SSE.frame("a\nb") == "data: a\ndata: b\n\n")
    }
}

@Suite("Access token")
struct AccessTokenTests {
    @Test("Tokens are long enough not to be guessed and differ between runs")
    func generatesDistinctTokens() {
        let a = AccessToken.generate(), b = AccessToken.generate()
        #expect(a.count >= 32)
        #expect(a != b)
    }

    // Comparing with == short-circuits on the first differing byte. The comparison is
    // remote-visible here, so it uses a constant-time path instead.
    @Test("Matching accepts the right token and rejects everything else")
    func matches() {
        let t = AccessToken.generate()
        #expect(AccessToken.matches(t, t))
        #expect(!AccessToken.matches(t, ""))
        #expect(!AccessToken.matches(t, String(t.dropLast())))
    }
}

@Suite("HTTP request bodies")
struct RequestBodyTests {
    @Test("A POST body is available once Content-Length bytes have arrived")
    func parsesCompleteBody() {
        let raw = "POST /ask HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let r = HTTPRequest(raw: raw)
        #expect(r?.body == #"{"a":1}"#)
    }

    // Answering before the body is complete would send a truncated question to the model.
    @Test("A short body is incomplete rather than truncated")
    func waitsForShortBody() {
        #expect(HTTPRequest(raw: "POST /ask HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\"") == nil)
    }

    @Test("A missing Content-Length means an empty body, not a wait forever")
    func noContentLengthIsEmpty() {
        #expect(HTTPRequest(raw: "POST /ask HTTP/1.1\r\n\r\n")?.body == "")
    }
}

/// Malformed requests, which arrive unauthenticated and before any token is checked.
///
/// The parser runs on bytes off the network before anything has been authorised, so a
/// request it cannot survive is a request anyone on the LAN can end the interview with.
@Suite("Malformed requests")
struct MalformedRequestTests {
    /// A single unauthenticated request used to kill the whole process: a negative
    /// Content-Length reached `prefix(-1)`, whose precondition is a runtime trap. On a
    /// --listen server that is any device on the network, or a port scanner.
    @Test("A negative Content-Length is rejected rather than fatal")
    func negativeContentLength() {
        let raw = "POST /ask HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"
        guard case .malformed = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("a negative Content-Length must be refused outright")
            return
        }
    }

    @Test("A Content-Length that is not a number carries no body")
    func nonNumericContentLength() {
        let raw = "POST /ask HTTP/1.1\r\nHost: x\r\nContent-Length: banana\r\n\r\nxx"
        guard case let .ok(request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.body.isEmpty)
    }

    /// Completeness is judged on bytes. Measuring the decoded string instead lets a body
    /// whose last character is still arriving look long enough, and it is then routed with a
    /// mangled tail.
    @Test("A body is incomplete until its declared bytes have arrived")
    func waitsForTheWholeBody() {
        let head = "POST /ask HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n"
        guard case .incomplete = HTTPRequest.parse(Data((head + "12345").utf8)) else {
            Issue.record("half a body must not be routed")
            return
        }
        guard case let .ok(request) = HTTPRequest.parse(Data((head + "1234567890").utf8)) else {
            Issue.record("a complete body must parse")
            return
        }
        #expect(request.body == "1234567890")
    }

    /// TCP splits where it likes, so a multibyte character can straddle two reads. Decoding
    /// each read on its own turns that character into replacement characters — the question
    /// reaches the model corrupted, which is invisible until the answer is about the wrong
    /// thing. Accumulating bytes and decoding once is what makes it whole.
    @Test("A multibyte character split across reads survives")
    func multibyteAcrossReads() {
        let body = #"{"question":"What is a “token bucket” — briefly?"}"#
        let bytes = Array(Data(body.utf8))
        let head = "POST /ask HTTP/1.1\r\nHost: x\r\nContent-Length: \(bytes.count)\r\n\r\n"

        // Split mid-character: the first read ends inside the “ (three bytes in UTF-8).
        let cut = body.distance(from: body.startIndex, to: body.range(of: "“")!.lowerBound) + 1
        var accumulated = Data(head.utf8)
        accumulated.append(contentsOf: bytes[0..<cut])
        guard case .incomplete = HTTPRequest.parse(accumulated) else {
            Issue.record("a body cut mid-character must not be treated as finished")
            return
        }
        accumulated.append(contentsOf: bytes[cut...])
        guard case let .ok(request) = HTTPRequest.parse(accumulated) else {
            Issue.record("expected the reassembled request to parse")
            return
        }
        #expect(request.body == body, "the split character was corrupted: \(request.body)")
        #expect(!request.body.contains("\u{FFFD}"), "replacement character in the body")
    }
}
