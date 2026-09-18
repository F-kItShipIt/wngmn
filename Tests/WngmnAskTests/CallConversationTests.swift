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

    /// The batch is committed in one actor hop. Appending turn by turn across awaits would let
    /// another caller's message land between two turns of what is sent as a single request.
    @Test("A batch is committed as separate labelled messages, in order, in one request")
    func batchCommitsInOrder() async {
        let convo = CallConversation(profile: profile())
        let (_, messages) = await convo.startBatch([
            turn("What is your burn rate?"),
            turn("About four hundred thousand.", speaker: .you),
            turn("And your runway?"),
        ])
        #expect(messages.map(\.text) == [
            "Caller: What is your burn rate?",
            "You: About four hundred thousand.",
            "Caller: And your runway?",
        ])
        #expect(messages.allSatisfy { $0.role == "user" })
    }

    @Test("A batch lands after what the conversation already holds")
    func batchAppendsToTheLedger() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startTurn(turn("What is your burn rate?"))
        await convo.finishTurn(answer: "About 400k a month.")
        let (_, messages) = await convo.startBatch([turn("And your runway?"), turn("In months.")])
        #expect(messages.count == 4)
        #expect(messages[1].role == "assistant")
        #expect(messages[3].text == "Caller: In months.")
    }

    /// Turns are held while an answer is being written and delivered together, so the newest
    /// message is often not the one that needs answering: the caller asks, you stall aloud
    /// ("good question, let me think"), and both arrive at once. Told to answer "the most
    /// recent turn", the model replies NONE to the stall and the question is lost — where it
    /// used to be sent alone and answered.
    @Test("The protocol tells the model that several turns can arrive at once")
    func systemPromptCoversBatches() {
        let system = CallConversation.buildSystem(profile: profile())
        #expect(system.contains("several can arrive at once"))
        #expect(system.contains("everything since your last reply"))
        #expect(!system.contains("Answer the most recent turn"),
                "the newest message alone is no longer the unit")
    }

    func shot(_ t: Double, base64: String = "iVBORw0KGgo=") -> Shot {
        Shot(base64: base64, t: t, mode: .region, width: 1500, height: 900, byteCount: 9)
    }

    /// The picture first, then the words that refer to it, which is the order the vision
    /// documentation recommends. The encoder keeps whatever order it is given, so this is the
    /// one place that order is decided.
    @Test("A screenshot is one user message: the picture, then its label")
    func shotMessageShape() async {
        let convo = CallConversation(profile: profile())
        let (_, messages) = await convo.startBatch([.shot(shot(83.412))])
        #expect(messages.count == 1)
        #expect(messages[0].role == "user")
        #expect(messages[0].blocks == [
            .image(mediaType: "image/png", base64: "iVBORw0KGgo="),
            .text("Screen: a screenshot I just took of my screen."),
        ])
    }

    @Test("Speech and a screenshot in one batch keep their arrival order")
    func mixedBatchKeepsOrder() async {
        let convo = CallConversation(profile: profile())
        let (_, messages) = await convo.startBatch([
            .turn(turn("Let me paste this here.")), .shot(shot(10)), .turn(turn("Take your time.")),
        ])
        #expect(messages.map(\.text) == [
            "Caller: Let me paste this here.",
            "Screen: a screenshot I just took of my screen.",
            "Caller: Take your time.",
        ])
    }

    /// Pressing the key is asking. A model that replies NONE to a screenshot leaves the page
    /// saying "Asking…" over nothing, after a deliberate act.
    @Test("The protocol names Screen, and says a screenshot is never answered NONE")
    func systemPromptCoversScreenshots() {
        let system = CallConversation.buildSystem(profile: profile())
        #expect(system.contains("labelled Screen"))
        #expect(system.contains("never reply NONE to a Screen message"))
    }

    /// Speech is committed before it is sent and never taken back — the other person did say
    /// it. A picture differs: one the API rejects would be sent again, and rejected again, on
    /// every later turn for the rest of the call.
    @Test("A rejected screenshot is taken out, and the rest of the conversation stays")
    func removesARejectedShot() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startBatch([.turn(turn("Let me paste this here.")), .shot(shot(10))])
        await convo.removeShots(keys: [shot(10).key])
        let (_, messages) = await convo.startTurn(turn("Can you see it?"))
        #expect(messages.map(\.text) == ["Caller: Let me paste this here.", "Caller: Can you see it?"])
    }

    @Test("Removing a screenshot that is not there changes nothing")
    func removingAnUnknownShotIsHarmless() async {
        let convo = CallConversation(profile: profile())
        _ = await convo.startBatch([.shot(shot(10))])
        await convo.removeShots(keys: ["screen@999"])
        let (_, messages) = await convo.startTurn(turn("Still there?"))
        #expect(messages.count == 2)
    }

    /// Past 20 images in one request the API holds every image in it to 2000 px on both sides,
    /// and images from earlier turns count. A shot is kept at up to 2576 px, so a 21st would
    /// fail its own request — and, staying in the conversation, every request after it.
    @Test("The conversation keeps twenty pictures; the oldest loses its picture, not its place")
    func capsThePictures() async {
        let convo = CallConversation(profile: profile())
        for i in 1...20 { _ = await convo.startBatch([.shot(shot(Double(i)))]) }
        let (_, messages) = await convo.startBatch([.shot(shot(21))])

        let withPicture = messages.filter { $0.blocks.contains { if case .image = $0 { true } else { false } } }
        #expect(withPicture.count == 20)
        #expect(messages.count == 21, "the oldest keeps its place in the conversation")
        #expect(messages[0].blocks == [.text("Screen: an earlier screenshot, no longer attached.")])
        #expect(messages[20].blocks.count == 2, "the newest has its picture")
    }
}
