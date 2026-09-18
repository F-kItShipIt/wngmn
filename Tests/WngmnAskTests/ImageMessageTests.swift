import Foundation
import Testing
@testable import WngmnAsk

/// What a conversation looks like on the wire.
///
/// Nothing pinned the multi-message request body before this: `CachingTests` covers the
/// one-shot ask and the system prompt, and the conversation path — which every auto answer
/// takes — was asserted nowhere. It is pinned here first, as it stands, so that teaching a
/// message to carry a picture can be shown to change nothing for a conversation without one.
@Suite("Conversation wire format")
struct ConversationWireFormatTests {
    typealias Message = ClaudeClient.Message
    let client = ClaudeClient(configuration: .init())

    func wire(_ messages: [Message]) throws -> [[String: Any]] {
        let body = client.requestBody(system: "", messages: messages)
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test("Every message but the last goes as a bare string")
    func earlierMessagesAreBareStrings() throws {
        let sent = try wire([
            Message(role: "user", text: "Caller: What is your burn rate?"),
            Message(role: "assistant", text: "About 400k a month."),
            Message(role: "user", text: "Caller: And your runway?"),
        ])
        #expect(sent[0]["content"] as? String == "Caller: What is your burn rate?")
        #expect(sent[1]["content"] as? String == "About 400k a month.")
        #expect(sent.map { $0["role"] as? String } == ["user", "assistant", "user"])
    }

    /// The breakpoint caches the whole prefix up to and including this turn, so the next turn
    /// reads the history back instead of paying for it again.
    @Test("The last message of a conversation is one text block carrying the cache breakpoint")
    func lastMessageCarriesTheBreakpoint() throws {
        let sent = try wire([
            Message(role: "user", text: "Caller: What is your burn rate?"),
            Message(role: "user", text: "Caller: And your runway?"),
        ])
        let blocks = try #require(sent[1]["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "Caller: And your runway?")
        let control = try #require(blocks[0]["cache_control"] as? [String: Any])
        #expect(control["type"] as? String == "ephemeral")
    }

    /// No prefix worth caching yet, and it keeps the one-shot ask byte-identical to what it
    /// always sent.
    @Test("A conversation of one message carries no breakpoint")
    func singleMessageIsPlain() throws {
        let sent = try wire([Message(role: "user", text: "Caller: Hello?")])
        #expect(sent[0]["content"] as? String == "Caller: Hello?")
    }
}
