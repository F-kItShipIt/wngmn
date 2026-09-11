import Foundation
import Testing
@testable import WngmnAsk

/// Prompt caching for the prepared-notes prefix.
///
/// The notes are identical on every ask in a session and the question is not, so the notes
/// are exactly the kind of prefix caching exists for: re-sending them each time is paid for
/// twice over, in tokens and in time-to-first-token — and latency is the binding constraint
/// on a live call.
@Suite("Prompt caching")
struct CachingTests {
    func body(system: String, user: String = "Why now?") -> [String: Any] {
        ClaudeClient(configuration: .init())
            .requestBody(for: AnswerPrompt.Prompt(system: system, user: user))
    }

    /// Long enough to be worth caching: the system field becomes a content block carrying a
    /// cache breakpoint rather than a bare string.
    @Test("Substantial notes are sent as a cacheable block")
    func cachesSubstantialNotes() throws {
        let notes = String(repeating: "Prepared material about the company. ", count: 400)
        let blocks = try #require(body(system: notes)["system"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == notes)
        let control = try #require(blocks[0]["cache_control"] as? [String: Any])
        #expect(control["type"] as? String == "ephemeral")
    }

    /// Below the model's minimum cacheable prefix a breakpoint does nothing at all — it is
    /// silently ignored rather than rejected. Sending a plain string keeps the request
    /// honest about what it is asking for.
    @Test("A short system prompt is sent plainly, with no pointless breakpoint")
    func skipsCachingShortPrompts() throws {
        #expect(body(system: "Answer briefly.")["system"] as? String == "Answer briefly.")
    }

    @Test("An empty system prompt is omitted rather than sent empty")
    func omitsEmptySystem() throws {
        #expect(body(system: "")["system"] == nil)
    }

    /// The question must stay outside the cached prefix. Caching is a prefix match, so a
    /// question folded into the cached region would invalidate it on every single ask —
    /// producing a cache that never once gets read.
    @Test("The question stays out of the cached prefix")
    func questionIsNotCached() throws {
        let notes = String(repeating: "Prepared material. ", count: 400)
        let sent = body(system: notes, user: "How big is the team?")
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "How big is the team?")
        let blocks = try #require(sent["system"] as? [[String: Any]])
        let cached = try #require(blocks.first?["text"] as? String)
        #expect(!cached.contains("How big is the team?"))
    }
}

@Suite("Usage decoding")
struct UsageDecodingTests {
    /// Without this the cache is unverifiable: a silent invalidator produces a request that
    /// looks identical and costs full price every time.
    @Test("message_start carries the cache counters")
    func decodesCacheCounters() {
        let line = #"""
        {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_creation_input_tokens":8000,"cache_read_input_tokens":0}}}
        """#
        #expect(
            AnthropicStream.event(from: line)
                == .usage(input: 12, cacheCreated: 8000, cacheRead: 0)
        )
    }

    @Test("A later ask reads the prefix back from cache")
    func decodesCacheHit() {
        let line = #"""
        {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":8000}}}
        """#
        #expect(
            AnthropicStream.event(from: line)
                == .usage(input: 12, cacheCreated: 0, cacheRead: 8000)
        )
    }
}


/// Truncation, which used to be invisible.
///
/// Observed: a long answer stopped mid-sentence ("...happens before any lock is taken,
/// because") and the page showed it as complete. The stream had reported `max_tokens` and
/// the decoder dropped it on the floor.
@Suite("Truncation")
struct TruncationTests {
    @Test("Hitting the token cap is reported, not swallowed")
    func decodesTruncation() {
        let line = #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        #expect(AnthropicStream.event(from: line) == .truncated)
    }

    @Test("A normal ending is not mistaken for truncation")
    func normalEnding() {
        #expect(AnthropicStream.event(from: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) == nil)
        #expect(AnthropicStream.event(from: #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) == .refused)
    }

    /// A cap this low truncates any structured answer, and the failure is silent, so the
    /// value is worth pinning rather than leaving to whoever edits the struct next.
    @Test("The token cap leaves room for a long structured answer")
    func generousTokenCap() {
        #expect(ClaudeClient.Configuration().maxTokens >= 32_000)
    }
}
