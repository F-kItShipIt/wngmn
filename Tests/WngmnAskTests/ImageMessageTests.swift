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

/// A message that can carry a picture.
///
/// Nothing constructs one yet. This is the shape and the encoding, so that the change which
/// does construct one has nothing left to decide about the wire.
@Suite("Image messages")
struct ImageMessageTests {
    typealias Message = ClaudeClient.Message
    let client = ClaudeClient(configuration: .init())
    /// Stands in for an image. The client never decodes it; it is carried, not read.
    let png = "iVBORw0KGgoAAAANSUhEUg=="

    func wire(_ messages: [Message]) throws -> [[String: Any]] {
        let body = client.requestBody(system: "", messages: messages)
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test("A message built from a string is one text block, and reads back as that string")
    func textConvenienceIsKept() {
        let m = Message(role: "user", text: "Caller: hello")
        #expect(m.blocks == [.text("Caller: hello")])
        #expect(m.text == "Caller: hello")
    }

    /// `text` is what the ledger's tests, the notes and every log line read. A kilobyte-long
    /// base64 string in the middle of it would be worse than useless.
    @Test("The text of a message with a picture is its words, not the picture")
    func textSkipsThePicture() {
        let m = Message(role: "user", blocks: [
            .image(mediaType: "image/png", base64: png),
            .text("Screen: a screenshot I just took of my screen."),
        ])
        #expect(m.text == "Screen: a screenshot I just took of my screen.")
    }

    /// The order of the blocks is the order on the wire. The vision documentation recommends
    /// the image before the text that refers to it, and that is the caller's to get right —
    /// an encoder that quietly reordered an ordered list would be the surprise.
    @Test("A picture goes on the wire as a base64 image block, in the order it was given")
    func imageBlockShape() throws {
        let sent = try wire([Message(role: "user", blocks: [
            .image(mediaType: "image/png", base64: png),
            .text("Screen: a screenshot I just took of my screen."),
        ])])
        let blocks = try #require(sent[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == png)
        #expect(blocks[1]["type"] as? String == "text")
        #expect(blocks[1]["text"] as? String == "Screen: a screenshot I just took of my screen.")
    }

    /// The breakpoint used to be placed by rebuilding the last message from its `text` alone.
    /// A picture is the newest message on exactly the request that is meant to answer it, so
    /// that rebuild would have dropped it there and nowhere else — silently, with a 200.
    @Test("The cache breakpoint lands on the last block, and the picture survives it")
    func breakpointKeepsThePicture() throws {
        let sent = try wire([
            Message(role: "user", text: "Caller: Let me paste this here."),
            Message(role: "user", blocks: [
                .image(mediaType: "image/png", base64: png),
                .text("Screen: a screenshot I just took of my screen."),
            ]),
        ])
        let blocks = try #require(sent[1]["content"] as? [[String: Any]])
        #expect(blocks.count == 2, "the picture was dropped from the message that carries it")
        #expect(blocks[0]["type"] as? String == "image")
        #expect(blocks[0]["cache_control"] == nil, "one breakpoint, on the last block")
        let control = try #require(blocks[1]["cache_control"] as? [String: Any])
        #expect(control["type"] as? String == "ephemeral")
    }

    /// The picture stays in the conversation, so on every later turn it is an earlier message.
    @Test("A picture earlier in the conversation is sent again, with no breakpoint of its own")
    func earlierPictureIsResent() throws {
        let sent = try wire([
            Message(role: "user", blocks: [
                .image(mediaType: "image/png", base64: png), .text("Screen: a screenshot."),
            ]),
            Message(role: "assistant", text: "It is a two-pointer merge."),
            Message(role: "user", text: "Caller: Can you do it in place?"),
        ])
        let first = try #require(sent[0]["content"] as? [[String: Any]])
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0["cache_control"] == nil })
        #expect(sent[1]["content"] as? String == "It is a two-pointer merge.")
    }
}
