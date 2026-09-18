import Foundation

/// Server-Sent Events framing.
///
/// SSE rather than a WebSocket: the traffic is one-way, the browser reconnects on its own,
/// and it is plain HTTP — which matters when the server is 200 hand-rolled lines and every
/// additional protocol is another thing to get wrong on a live call.
public enum SSE {
    /// Wraps a payload as one event frame.
    ///
    /// Each line of the payload becomes its own `data:` line. A raw newline inside a frame
    /// would otherwise terminate it early and desynchronise every later event on that
    /// connection — the JSON Lines encoder escapes newlines, but this layer must not depend
    /// on that guarantee holding for text it did not produce.
    /// An `id` makes the frame resumable: the browser echoes the last one it saw back in
    /// `Last-Event-ID` when it reconnects, which is the only way the server can tell what
    /// a returning page already has. Only frames worth replaying get one.
    public static func frame(_ payload: String, id: Int? = nil) -> String {
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        let head = id.map { "id: \($0)\n" } ?? ""
        return head + lines.map { "data: \($0)\n" }.joined() + "\n"
    }

    /// A comment frame. Browsers ignore it, but it keeps an idle connection from being
    /// reaped by the OS during a quiet stretch of interview.
    public static let keepAlive = ": keep-alive\n\n"
}
