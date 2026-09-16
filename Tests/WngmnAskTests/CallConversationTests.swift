import Foundation
import Testing
import WngmnCore
@testable import WngmnAsk

/// The conversation ledger: turns and answers accumulate so later answers see earlier ones.
@Suite("CallConversation")
struct CallConversationTests {
    func turn(_ text: String, speaker: Speaker = .caller) -> TurnBatcher.Turn {
        TurnBatcher.Turn(text: text, t0: 0, t1: 1, lineCount: 1, speaker: speaker)
    }

    func profile(style: String = "s", context: String = "c") -> Profile {
        Profile(text: "## Style\n\(style)\n\n## Context\n\(context)")
    }

    @Test("The system turn carries style, material, and the answer-or-NONE protocol")
    func systemPrompt() {
        let system = CallConversation.buildSystem(
            profile: profile(style: "Be brief.", context: "We sell robots."))
        #expect(system.contains("Be brief."))
        #expect(system.contains("We sell robots."))
        #expect(system.contains("NONE"))
        #expect(system.contains("Caller"))
    }

    @Test("A turn is committed as a labelled message and returned in the request")
    func startTurnLabels() async {
        let convo = CallConversation(profile: profile())
        let (_, messages) = await convo.startTurn(turn("What is your burn rate?"))
        #expect(messages.count == 1)
        #expect(messages[0].role == "user")
        #expect(messages[0].text == "Caller: What is your burn rate?")
    }

    @Test("A real answer becomes context for the next turn")
    func answerCarriesForward() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startTurn(turn("What is your burn rate?"))
        await convo.finishTurn(answer: "About 400k a month.")
        let (_, messages) = await convo.startTurn(turn("And your runway?"))
        #expect(messages.count == 3)
        #expect(messages[1].role == "assistant")
        #expect(messages[1].text == "About 400k a month.")
        #expect(messages[2].text == "Caller: And your runway?")
    }

    @Test("A NONE reply keeps the turn as context but adds no answer")
    func noneKeepsTurnOnly() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startTurn(turn("Nice weather today."))
        await convo.finishTurn(answer: "NONE")
        let (_, messages) = await convo.startTurn(turn("What is your burn rate?"))
        #expect(messages.count == 2, "the small-talk turn stayed; no assistant message was added")
        #expect(messages[0].text == "Caller: Nice weather today.")
        #expect(messages[1].text == "Caller: What is your burn rate?")
    }

    @Test("Your own question is labelled You")
    func ownQuestionLabelled() async {
        let convo = CallConversation(profile: profile())
        let (_, messages) = await convo.startTurn(turn("How do I reverse a list?", speaker: .you))
        #expect(messages[0].text == "You: How do I reverse a list?")
    }

    @Test("The summary request appends a summary turn without committing it")
    func summaryRequest() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startTurn(turn("What is your burn rate?"))
        await convo.finishTurn(answer: "400k.")
        let (_, messages) = await convo.summaryRequest()
        #expect(messages.count == 3)
        #expect(messages.last?.text.contains("meeting notes") == true)
        // Not committed: a later start still sees only the two real turns.
        let (_, after) = await convo.startTurn(turn("Anything else?"))
        #expect(after.count == 3)
    }

    @Test("NONE is recognised regardless of case and trailing punctuation")
    func noneShapes() {
        #expect(CallConversation.isNone("NONE"))
        #expect(CallConversation.isNone("none"))
        #expect(CallConversation.isNone("None."))
        #expect(CallConversation.isNone("  NONE  "))
        #expect(!CallConversation.isNone("There is none left."))
        #expect(!CallConversation.isNone("The answer is 400k."))
    }
}
