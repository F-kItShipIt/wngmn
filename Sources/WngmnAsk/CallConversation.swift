import Foundation
import WngmnCore

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
    private var messages: [ClaudeClient.Message] = []

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
        for turn in turns {
            messages.append(ClaudeClient.Message(role: "user", text: Self.userMessage(for: turn)))
        }
        return (system, messages)
    }

    /// Commits an answer to the ledger. A `NONE` reply leaves only the turn behind, as
    /// context; a real answer is appended so later turns can see what was already said.
    public func finishTurn(answer: String) {
        guard !Self.isNone(answer) else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ClaudeClient.Message(role: "assistant", text: trimmed))
    }

    /// The request for end-of-call notes: the whole conversation plus one summary turn.
    /// Not committed — the summary is a leaf, never itself context for anything.
    public func summaryRequest() -> (system: String, messages: [ClaudeClient.Message]) {
        (system, messages + [ClaudeClient.Message(role: "user", text: Self.summaryInstruction)])
    }

    public var isEmpty: Bool { messages.isEmpty }

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
        including a question or problem I am reading out or repeating back. Answer the most \
        recent turn from the material when it, read in that context, calls for an answer — a \
        question, a request, a problem to solve, something I would need to respond to. When it \
        does not — small talk, an aside, filler — reply with exactly NONE and nothing else. \
        Never explain a NONE.
        """
        return system
    }

    /// One turn as a labelled user message.
    static func userMessage(for turn: TurnBatcher.Turn) -> String {
        let who = turn.speaker == .caller ? "Caller" : "You"
        return "\(who): \(turn.text)"
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
