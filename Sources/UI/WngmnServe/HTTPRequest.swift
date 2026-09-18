import Foundation

/// The sliver of HTTP/1.1 this server needs: a method, a path, and a query.
///
/// Hand-rolled rather than pulled in, because success criterion 4 is setup with no network
/// fetch and every Swift HTTP server is a package dependency. The scope is deliberately tiny
/// — two routes, GET only, served to a browser on this machine — so the correct move is to
/// parse exactly that and reject everything else, not to approximate a real server.
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// The request body. Empty when there is no `Content-Length`.
    public let body: String
    /// Header names lowercased, because HTTP header names are case-insensitive and browsers
    /// disagree about the spelling of `Last-Event-ID`.
    public let headers: [String: String]

    /// What a buffer of bytes off the socket turned out to be.
    ///
    /// Three outcomes, not two. "Not a request yet" and "not a request ever" need different
    /// answers: the first has to keep reading, the second has to hang up. Collapsing them
    /// into nil left a malformed request being read from forever.
    public enum ParseOutcome: Sendable {
        /// A complete header block has not arrived, or the declared body has not.
        case incomplete
        /// It cannot become a valid request however much more arrives.
        case malformed
        case ok(HTTPRequest)
    }

    /// Parses raw socket bytes.
    ///
    /// Bytes rather than a String, because TCP splits where it likes and a multibyte
    /// character can straddle two reads. Decoding each read on its own replaces that
    /// character with U+FFFD, and the question reaches the model corrupted — invisible until
    /// the answer is about the wrong thing. Completeness is judged on bytes for the same
    /// reason: a partially-arrived character decodes to a 3-byte replacement and can make a
    /// body that is still arriving look long enough to route.
    public static func parse(_ raw: Data) -> ParseOutcome {
        let separator: Range<Data.Index>
        if let r = raw.range(of: Data("\r\n\r\n".utf8)) { separator = r }
        else if let r = raw.range(of: Data("\n\n".utf8)) { separator = r }
        else { return .incomplete }

        let headerBlock = String(decoding: raw[raw.startIndex..<separator.lowerBound], as: UTF8.self)
        let received = raw[separator.upperBound...]
        guard let line = headerBlock.split(whereSeparator: \.isNewline).first else { return .malformed }

        let body: String
        if let declared = HTTPRequest.contentLength(in: headerBlock) {
            // A negative length reached `prefix(-1)`, whose precondition is a runtime trap —
            // so one unauthenticated request killed the process. It is refused here, before
            // anything else looks at it, because this runs before the token is checked.
            guard declared >= 0 else { return .malformed }
            guard received.count >= declared else { return .incomplete }
            body = String(decoding: received.prefix(declared), as: UTF8.self)
        } else {
            body = ""
        }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return .malformed }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return .malformed }

        let path: String, query: [String: String]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            query = HTTPRequest.parseQuery(String(target[target.index(after: q)...]))
        } else {
            path = target
            query = [:]
        }
        return .ok(HTTPRequest(
            method: String(parts[0]), path: path, query: query, body: body,
            headers: HTTPRequest.parseHeaders(in: headerBlock)
        ))
    }

    private init(method: String, path: String, query: [String: String],
                 body: String, headers: [String: String]) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.headers = headers
    }

    /// Convenience for callers that only care whether a complete request is there.
    public init?(raw: String) {
        guard case let .ok(request) = HTTPRequest.parse(Data(raw.utf8)) else { return nil }
        self = request
    }

    private static func parseHeaders(in headerBlock: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in headerBlock.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func contentLength(in headerBlock: String) -> Int? {
        parseHeaders(in: headerBlock)["content-length"].flatMap(Int.init)
    }

    private static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            out[decode(String(key))] = decode(value)
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}
