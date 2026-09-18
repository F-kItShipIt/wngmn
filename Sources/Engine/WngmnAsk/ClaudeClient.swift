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
    /// One message of a conversation: a role, and an ordered list of blocks.
    ///
    /// It was a role and a string until a message had to be able to carry a picture. The
    /// string initialiser and `text` are kept, so every call site and test that thinks of a
    /// message as words still reads as it did.
    public struct Message: Sendable, Equatable {
        public enum Block: Sendable, Equatable {
            case text(String)
            /// `base64` is the encoded bytes, as the API takes them. `mediaType` has to be one
            /// of the four it accepts — image/jpeg, image/png, image/gif, image/webp — which is
            /// the capturing side's business: this type carries a picture, it never reads one.
            case image(mediaType: String, base64: String)
        }

        public let role: String
        /// In wire order. The vision documentation recommends a picture before the words that
        /// refer to it; that is for whoever builds the message, not for the encoder to enforce
        /// by quietly reordering a list the caller was told is ordered.
        public let blocks: [Block]

        public init(role: String, blocks: [Block]) {
            self.role = role
            self.blocks = blocks
        }

        public init(role: String, text: String) {
            self.init(role: role, blocks: [.text(text)])
        }

        /// The words, without the pictures. This is what the ledger's tests, the notes and a
        /// log line read, and a megabyte of base64 in the middle of it would help none of them.
        public var text: String {
            blocks.compactMap { block -> String? in
                if case let .text(text) = block { return text }
                return nil
            }.joined(separator: "\n")
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
        var wire: [[String: Any]] = messages.map { ["role": $0.role, "content": Self.content(of: $0)] }
        if messages.count > 1, let last = wire.indices.last {
            // On the last block of the message as it is, not on a message rebuilt from its
            // text. A picture is the newest message on exactly the request meant to answer it,
            // so rebuilding from `text` would drop it there and nowhere else — with a 200.
            var blocks = Self.blocks(of: messages[last])
            if let end = blocks.indices.last {
                blocks[end]["cache_control"] = ["type": "ephemeral"]
            }
            wire[last]["content"] = blocks
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

    /// A message that is only words goes as a bare string, which is what every request made
    /// before a message could carry a picture looked like — so a conversation without one is
    /// byte-identical to what it always was, and its cached prefix is not disturbed.
    static func content(of message: Message) -> Any {
        if message.blocks.count == 1, case let .text(text) = message.blocks[0] { return text }
        return blocks(of: message)
    }

    static func blocks(of message: Message) -> [[String: Any]] {
        message.blocks.map { block -> [String: Any] in
            switch block {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .image(mediaType, base64):
                return [
                    "type": "image",
                    "source": ["type": "base64", "media_type": mediaType, "data": base64],
                ]
            }
        }
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
