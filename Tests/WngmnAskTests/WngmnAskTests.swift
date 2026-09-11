import Testing
@testable import WngmnAsk
@testable import WngmnCore

@Suite("Credentials")
struct CredentialsTests {
    @Test("An API key is used directly and sent as x-api-key")
    func apiKeyWins() {
        let c = Credentials.resolve(environment: ["ANTHROPIC_API_KEY": "sk-ant-test"])
        #expect(c == .apiKey("sk-ant-test"))
        #expect(c?.headers()["x-api-key"] == "sk-ant-test")
        #expect(c?.headers()["authorization"] == nil)
    }

    // An OAuth token is a different header *and* needs a beta flag. Sending one as
    // x-api-key fails with a 401 that reads like a bad key rather than a wrong scheme.
    @Test("An OAuth token is sent as a bearer with the beta flag it requires")
    func oauthTokenUsesBearer() {
        let c = Credentials.resolve(environment: ["ANTHROPIC_AUTH_TOKEN": "oat-test"])
        #expect(c == .bearer("oat-test"))
        let headers = c?.headers() ?? [:]
        #expect(headers["authorization"] == "Bearer oat-test")
        #expect(headers["anthropic-beta"]?.contains("oauth-2025-04-20") == true)
        #expect(headers["x-api-key"] == nil)
    }

    @Test("An API key outranks an OAuth token, as the SDKs resolve them")
    func apiKeyOutranksToken() {
        let c = Credentials.resolve(environment: [
            "ANTHROPIC_API_KEY": "sk-ant-test", "ANTHROPIC_AUTH_TOKEN": "oat-test",
        ])
        #expect(c == .apiKey("sk-ant-test"))
    }

    // An exported-but-empty variable is the common shape of a broken shell profile, and
    // must not be mistaken for a credential.
    @Test("Empty or absent variables resolve to nothing")
    func emptyIsNotACredential() {
        #expect(Credentials.resolve(environment: [:]) == nil)
        #expect(Credentials.resolve(environment: ["ANTHROPIC_API_KEY": ""]) == nil)
        #expect(Credentials.resolve(environment: ["ANTHROPIC_API_KEY": "  "]) == nil)
    }
}

@Suite("Answer prompt")
struct AnswerPromptTests {
    @Test("The question being answered is carried in the user turn")
    func carriesQuestion() {
        let p = AnswerPrompt.build(question: "How big is the team?", recent: [], notes: "")
        #expect(p.user.contains("How big is the team?"))
    }

    @Test("Prepared notes are carried in the system turn")
    func carriesNotes() {
        let p = AnswerPrompt.build(
            question: "Why now?", recent: [], notes: "Raised $12M Series A in March.")
        #expect(p.system.contains("Raised $12M Series A in March."))
    }

    /// The style section is the user's own instruction to the model, so it must reach the
    /// system turn intact rather than being paraphrased or wrapped in a house voice.
    @Test("A profile's style becomes the instructions")
    func carriesStyle() {
        let profile = Profile(text: "## Style\nLead with the number.\n\n## Context\nARR is $4.1M.")
        let p = AnswerPrompt.build(question: "How is revenue?", recent: [], profile: profile)
        #expect(p.system.contains("Lead with the number."))
        #expect(p.system.contains("ARR is $4.1M."))
    }

    /// Instructions before material: the model reads the shape of the answer before the
    /// substance it is shaping.
    @Test("Style precedes context in the system turn")
    func styleComesFirst() throws {
        let profile = Profile(text: "## Style\nBe brief.\n\n## Context\nA fact.")
        let p = AnswerPrompt.build(question: "Q", recent: [], profile: profile)
        let style = try #require(p.system.range(of: "Be brief."))
        let context = try #require(p.system.range(of: "A fact."))
        #expect(style.lowerBound < context.lowerBound)
    }

    @Test("A profile with only context still works")
    func contextOnly() {
        let profile = Profile(text: "## Context\nJust the facts.")
        let p = AnswerPrompt.build(question: "Q", recent: [], profile: profile)
        #expect(p.system.contains("Just the facts."))
    }

    /// An empty profile must not produce a system turn full of empty scaffolding claiming
    /// material that is not there.
    @Test("An empty profile produces no system turn at all")
    func emptyProfile() {
        let p = AnswerPrompt.build(question: "Q", recent: [], profile: .empty)
        #expect(p.system.isEmpty)
        #expect(p.user.contains("Q"))
    }

    // Without the earlier questions, a follow-up like "and why now?" has no referent and
    // the answer is about the wrong thing.
    @Test("Earlier questions are carried so a follow-up has its referent")
    func carriesRecentContext() {
        let p = AnswerPrompt.build(
            question: "And why now?", recent: ["Tell me about the raise."], notes: "")
        #expect(p.user.contains("Tell me about the raise."))
    }

    @Test("With no notes, the system turn does not claim to have any")
    func omitsEmptyNotesSection() {
        let p = AnswerPrompt.build(question: "Why now?", recent: [], notes: "   ")
        #expect(!p.system.lowercased().contains("prepared notes"))
    }
}

@Suite("Anthropic stream decoding")
struct StreamDecodingTests {
    @Test("A text delta yields its text")
    func decodesTextDelta() {
        let line = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        #expect(AnthropicStream.event(from: line) == .text("Hello"))
    }

    // Thinking deltas share the content_block_delta envelope. Rendering them would put
    // reasoning on screen where the answer should be.
    @Test("A thinking delta is not mistaken for answer text")
    func ignoresThinkingDelta() {
        let line = #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        #expect(AnthropicStream.event(from: line) == nil)
    }

    @Test("Lifecycle events are recognised and carry no text")
    func decodesLifecycle() {
        #expect(AnthropicStream.event(from: #"{"type":"message_stop"}"#) == .stop)
        #expect(AnthropicStream.event(from: "[DONE]") == .stop)
        #expect(AnthropicStream.event(from: #"{"type":"content_block_start","index":0}"#) == nil)
    }

    // An API error arrives as HTTP 200 inside the stream. Treating it as "no more text"
    // shows the user a silently truncated answer instead of telling them what failed.
    @Test("An in-stream error is surfaced rather than read as an ending")
    func decodesError() {
        let line = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(AnthropicStream.event(from: line) == .failed("Overloaded"))
    }

    // A policy decline is HTTP 200 with stop_reason "refusal" — not an error event.
    @Test("A refusal stop reason is surfaced, not silently ended")
    func decodesRefusal() {
        let line = #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
        #expect(AnthropicStream.event(from: line) == .refused)
    }

    @Test("Malformed lines are skipped rather than crashing the stream")
    func skipsGarbage() {
        #expect(AnthropicStream.event(from: "{not json") == nil)
        #expect(AnthropicStream.event(from: "") == nil)
    }
}
