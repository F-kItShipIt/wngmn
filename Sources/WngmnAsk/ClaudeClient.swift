import Foundation

/// Streaming client for the Claude Messages API.
///
/// Raw HTTP rather than an SDK because there is no official Anthropic SDK for Swift. The
/// surface used here is deliberately small: one streaming POST, no tools, no history.
public struct ClaudeClient: Sendable {
    public struct Configuration: Sendable {
        public var model = "claude-opus-5"
        /// Deliberately small. The answer is read aloud between two sentences of an
        /// interview, so a long one is a failure even when it is correct.
        /// Deliberately generous. The request streams, so this is a ceiling rather than an
        /// allocation and costs nothing until it is reached — while a low cap silently
        /// truncates a structured answer mid-sentence, which is what 4096 was doing.
        public var maxTokens = 64_000
        /// Latency is the binding constraint on a live call, and composing prepared
        /// material is not an intelligence-sensitive task. Thinking stays on — disabling it
        /// on this model risks leaked `<thinking>` tags — and effort carries the saving.
        public var effort = "low"
        public var timeout: TimeInterval = 90

        public init() {}
    }

    public var configuration: Configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// One message in a conversation. `role` is "user" or "assistant".
    public struct Message: Sendable, Equatable {
        public let role: String
        public let text: String
        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noCredentials
        case http(status: Int, detail: String)
        case refused

        public var description: String {
            switch self {
            case .noCredentials:
                "no Claude credentials found — export ANTHROPIC_API_KEY, or run `ant auth login`"
            case let .http(status, detail):
                "Claude API returned \(status): \(detail)"
            case .refused:
                "Claude declined to answer this one"
            }
        }
    }

    /// Below this the API ignores a cache breakpoint entirely — the minimum cacheable
    /// prefix is model-dependent and in the low thousands of tokens. Estimated from
    /// characters rather than counted: an exact count would cost a `count_tokens` round trip
    /// per ask to decide something whose only consequence is whether we ask for a cache we
    /// might not get.
    static let minimumCacheableCharacters = 4_000

    /// The request body, separated out so the cache placement can be asserted without
    /// spending money.
    ///
    /// The prepared notes are identical across every ask in a session and the question is
    /// not, so the notes go in `system` behind a cache breakpoint and the question stays in
    /// `messages` after it. Caching is a prefix match: anything volatile inside the cached
    /// region invalidates it on every request, producing a cache that is written each time
    /// and never once read.
    func requestBody(for prompt: AnswerPrompt.Prompt) -> [String: Any] {
        requestBody(system: prompt.system, messages: [Message(role: "user", text: prompt.user)])
    }

    /// The request body for a multi-turn conversation.
    ///
    /// The profile goes in `system` behind a cache breakpoint, as for a single question. The
    /// conversation adds a second: a breakpoint on the last message caches the whole prefix
    /// up to and including this turn, so the next turn reads all of it back rather than
    /// re-paying for the growing history on every answer. A single-message conversation
    /// carries no message breakpoint — there is no prefix worth caching yet, and it keeps the
    /// one-shot ask byte-identical to what it always sent.
    func requestBody(system: String, messages: [Message]) -> [String: Any] {
        var wire: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.text] }
        if messages.count > 1, let last = wire.indices.last {
            wire[last]["content"] = [[
                "type": "text",
                "text": messages[last].text,
                "cache_control": ["type": "ephemeral"],
            ]]
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "stream": true,
            "messages": wire,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": configuration.effort],
            "fallbacks": "default",
        ]
        if system.isEmpty {
            return body
        }
        if system.count >= Self.minimumCacheableCharacters {
            body["system"] = [[
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"],
            ]]
        } else {
            // Short enough that a breakpoint would be ignored; sending a plain string keeps
            // the request honest about what it is actually asking for.
            body["system"] = system
        }
        return body
    }

    /// Streams an answer to a single question, calling `onText` with each fragment.
    public func stream(
        prompt: AnswerPrompt.Prompt,
        credentials: Credentials,
        onUsage: (@Sendable (Int, Int, Int) -> Void)? = nil,
        onTruncated: (@Sendable () -> Void)? = nil,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        try await stream(
            body: requestBody(for: prompt), credentials: credentials,
            onUsage: onUsage, onTruncated: onTruncated, onText: onText
        )
    }

    /// Streams an answer to a multi-turn conversation.
    public func stream(
        system: String,
        messages: [Message],
        credentials: Credentials,
        onUsage: (@Sendable (Int, Int, Int) -> Void)? = nil,
        onTruncated: (@Sendable () -> Void)? = nil,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        try await stream(
            body: requestBody(system: system, messages: messages), credentials: credentials,
            onUsage: onUsage, onTruncated: onTruncated, onText: onText
        )
    }

    private func stream(
        body: [String: Any],
        credentials: Credentials,
        onUsage: (@Sendable (Int, Int, Int) -> Void)?,
        onTruncated: (@Sendable () -> Void)?,
        onText: @escaping @Sendable (String) -> Void
    ) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (key, value) in credentials.headers() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Server-side refusal fallbacks, recommended by default on this model: on a policy
        // decline the API re-runs the request on a fallback model inside the same call
        // rather than simply stopping. Joined with any beta the credentials already need.
        var betas = ["server-side-fallback-2026-07-01"]
        if let existing = credentials.headers()["anthropic-beta"] { betas.append(existing) }
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // The body is the error JSON, not a stream. Read it so the user sees the actual
            // reason rather than a bare status code.
            var detail = ""
            for try await line in bytes.lines where detail.count < 500 { detail += line }
            throw Failure.http(status: status, detail: Self.errorMessage(from: detail))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count))
            switch AnthropicStream.event(from: payload) {
            case let .text(text): onText(text)
            case let .usage(input, created, read): onUsage?(input, created, read)
            case .stop: return
            case .refused: throw Failure.refused
            case .truncated: onTruncated?()
            case let .failed(message): throw Failure.http(status: 200, detail: message)
            case nil: continue
            }
        }
    }

    static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return body.isEmpty ? "no detail" : body }
        return message
    }
}
