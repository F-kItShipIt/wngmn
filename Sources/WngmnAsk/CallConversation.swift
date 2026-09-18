import Foundation
import WngmnCore

/// Something that goes into the conversation: what was said, or what was shown.
public enum ConversationItem: Sendable, Equatable {
    case turn(TurnBatcher.Turn)
    case shot(Shot)
}

/// The shared context ledger for one call, as a Messages-API conversation.
///
/// Every answered turn becomes a message and every answer Claude's reply, so a later answer
/// sees the earlier ones for free — they are literally the prior messages. The profile is
/// the cached system prefix; `ClaudeClient` caches the growing conversation on top of it, so
/// the history is nearly free to carry.
///
/// An actor: turns close on one task and answers stream on another, and the message list is
/// the state both touch. The message-building itself is static and pure, so it is asserted
/// without spending money or standing up an actor.
public actor CallConversation {
    private let system: String
    /// A message, and the key of the screenshot it carries if it carries one — which is how a
    /// rejected picture is found again to be taken out.
    private struct Entry {
        var message: ClaudeClient.Message
        var shotKey: String?
    }
    private var entries: [Entry] = []
    private var messages: [ClaudeClient.Message] { entries.map(\.message) }

    /// Past 20 images in one request the API holds every image in it to 2000 px on both sides,
    /// and images resent from earlier turns count towards the 20. A shot is kept at up to
    /// 2576 px, so a 21st would fail its own request and — because it stays in the conversation
    /// — every request after it.
    static let maximumPictures = 20

    public init(profile: Profile) {
        system = Self.buildSystem(profile: profile)
    }

    /// Opens a turn: appends it to the ledger and returns the request to send.
    ///
    /// The turn is committed immediately rather than on success, so it is context for the
    /// next turn even if this answer fails or is `NONE` — the other person did say it. The
    /// answer is committed separately once it arrives.
    public func startTurn(_ turn: TurnBatcher.Turn) -> (system: String, messages: [ClaudeClient.Message]) {
        startBatch([turn])
    }

    /// Opens several turns as one request: everything that waited while the last answer was
    /// streaming, delivered together.
    ///
    /// One call, so one actor hop. Appending turn by turn across awaits would let something
    /// else land between two turns of what goes out as a single request. Each turn stays its
    /// own message — consecutive user messages are already what a `NONE` leaves behind, and
    /// keeping them separate keeps each one's speaker label.
    public func startBatch(_ turns: [TurnBatcher.Turn]) -> (system: String, messages: [ClaudeClient.Message]) {
        startBatch(turns.map(ConversationItem.turn))
    }

    /// The same, for a batch that may hold a screenshot among the speech.
    public func startBatch(_ items: [ConversationItem]) -> (system: String, messages: [ClaudeClient.Message]) {
        for item in items {
            switch item {
            case let .turn(turn):
                entries.append(Entry(
                    message: ClaudeClient.Message(role: "user", text: Self.userMessage(for: turn)),
                    shotKey: nil))
            case let .shot(shot):
                makeRoomForAPicture()
                entries.append(Entry(message: Self.message(for: shot), shotKey: shot.key))
            }
        }
        return (system, messages)
    }

    /// Takes screenshots back out. Speech is committed before it is sent and never rolled back,
    /// deliberately — the other person did say it. A picture differs: one the API rejects would
    /// be sent again, and rejected again, on every later turn for the rest of the call.
    public func removeShots(keys: [String]) {
        entries.removeAll { entry in entry.shotKey.map(keys.contains) ?? false }
    }

    /// The oldest picture gives up its image and keeps its place: the label says so, and the
    /// answer that was given about it is still the next message, so a later "the first one you
    /// showed me" still has something to refer to.
    private func makeRoomForAPicture() {
        let pictures = entries.indices.filter { Self.hasPicture(entries[$0].message) }
        guard pictures.count >= Self.maximumPictures, let oldest = pictures.first else { return }
        entries[oldest].message = ClaudeClient.Message(
            role: "user", text: "Screen: an earlier screenshot, no longer attached.")
    }

    static func hasPicture(_ message: ClaudeClient.Message) -> Bool {
        message.blocks.contains { if case .image = $0 { true } else { false } }
    }

    /// Commits an answer to the ledger. A `NONE` reply leaves only the turn behind, as
    /// context; a real answer is appended so later turns can see what was already said.
    public func finishTurn(answer: String) {
        guard !Self.isNone(answer) else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(Entry(
            message: ClaudeClient.Message(role: "assistant", text: trimmed), shotKey: nil))
    }

    /// The request for end-of-call notes: the whole conversation plus one summary turn.
    /// Not committed — the summary is a leaf, never itself context for anything.
    public func summaryRequest() -> (system: String, messages: [ClaudeClient.Message]) {
        (system, messages + [ClaudeClient.Message(role: "user", text: Self.summaryInstruction)])
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Pure message building

    /// The system turn: the profile's style and material, then the live-call protocol.
    ///
    /// The protocol is what makes a per-turn call cheap: the model answers only when the turn
    /// calls for it and replies `NONE` otherwise, so the "does this need an answer?" decision
    /// rides on the same call as the answer rather than a second one.
    static func buildSystem(profile: Profile) -> String {
        var system = profile.style.trimmingCharacters(in: .whitespacesAndNewlines)

        let material = profile.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !material.isEmpty {
            if !system.isEmpty { system += "\n\n" }
            system += """
            Prepared material — this is the substance to draw on. Prefer it over anything \
            else you know:

            \(material)
            """
        }

        if !system.isEmpty { system += "\n\n" }
        system += """
        You are drafting answers for me during a live call, in real time. Each message is \
        one turn of the conversation, labelled Caller (the other side) or You (me). The turns \
        are live speech-to-text: words are clipped (often the opening "Can you…" or "Write…"), \
        misheard, or split across turns, and question marks go missing. Read the whole \
        conversation so far, from both sides, to work out what is actually being asked — \
        including a question or problem I am reading out or repeating back. Turns are held \
        while you are writing an answer, so several can arrive at once: look at everything \
        since your last reply, not only the final message. Answer, from the material, the \
        latest turn among them that, read in that context, calls for an answer — a question, a \
        request, a problem to solve, something I would need to respond to — even when small \
        talk or filler came after it. When none of them does — small talk, an aside, filler — \
        reply with exactly NONE and nothing else. Never explain a NONE. A message may instead be \
        labelled Screen: that is a picture I just took of my own screen, usually something the \
        other side has put in front of me — a problem, a document, a diagram. Treat what it \
        shows as part of the conversation. Taking it is me asking you about it now, so work out \
        what it calls for and answer that, and never reply NONE to a Screen message.
        """
        return system
    }

    /// One turn as a labelled user message.
    static func userMessage(for turn: TurnBatcher.Turn) -> String {
        let who = turn.speaker == .caller ? "Caller" : "You"
        return "\(who): \(turn.text)"
    }

    /// The picture, then the words that refer to it — the order the vision documentation
    /// recommends. The encoder keeps whatever order it is given, so this is where it is decided.
    static func message(for shot: Shot) -> ClaudeClient.Message {
        ClaudeClient.Message(role: "user", blocks: [
            .image(mediaType: "image/png", base64: shot.base64),
            .text("Screen: a screenshot I just took of my screen."),
        ])
    }

    static let summaryInstruction = """
    The call has ended. Write meeting notes from the whole conversation above: the key \
    points, the questions that were asked and how they were answered, decisions reached, \
    and any open items. Be concise and specific; use short sections or bullets.
    """

    /// Whether a reply is the "nothing to answer" sentinel.
    ///
    /// Lenient on punctuation and case — a model that says `None.` or `none` means the same
    /// thing — but it must be the whole reply, so an answer that merely mentions the word
    /// is never mistaken for a decline.
    static func isNone(_ answer: String) -> Bool {
        let stripped = answer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        return stripped.uppercased() == "NONE"
    }
}
