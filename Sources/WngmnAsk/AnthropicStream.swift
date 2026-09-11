import Foundation

/// Decoding for the Messages API's Server-Sent Events stream.
///
/// The decoder is separated from the transport so every branch — including the two that
/// arrive as HTTP 200 and would otherwise look like a normal ending — can be tested without
/// a network call or an API key.
public enum AnthropicStream {
    public enum Event: Sendable, Equatable {
        case text(String)
        /// Token accounting from `message_start`. Carried so a cache that is silently never
        /// read can be seen rather than assumed: an invalidated prefix produces a request
        /// that looks identical and costs full price.
        case usage(input: Int, cacheCreated: Int, cacheRead: Int)
        case stop
        /// An error delivered *inside* a 200 response. Reading this as "no more text" would
        /// show a silently truncated answer instead of saying what went wrong.
        case failed(String)
        /// A policy decline: HTTP 200, `stop_reason: "refusal"`, not an error event.
        case refused
        /// The answer hit the token cap and stopped mid-sentence. Reported because it is
        /// otherwise indistinguishable from a finished answer: the stream ends normally and
        /// the last thing on screen is a half-written clause the reader may say aloud.
        case truncated
    }

    /// Decodes one `data:` payload. Returns nil for frames that carry nothing to show —
    /// block starts and stops, pings, thinking deltas, and anything malformed.
    public static func event(from dataLine: String) -> Event? {
        let line = dataLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line == "[DONE]" { return .stop }
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String
        else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = root["delta"] as? [String: Any] else { return nil }
            // Thinking deltas share this envelope. Rendering them would put reasoning on
            // screen where the answer belongs.
            guard delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_start":
            guard let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return nil }
            return .usage(
                input: usage["input_tokens"] as? Int ?? 0,
                cacheCreated: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
            )
        case "message_delta":
            switch (root["delta"] as? [String: Any])?["stop_reason"] as? String {
            case "refusal": return .refused
            case "max_tokens": return .truncated
            default: return nil
            }
        case "message_stop":
            return .stop
        case "error":
            let error = root["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? "unknown API error")
        default:
            return nil
        }
    }
}
