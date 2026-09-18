import Foundation
import WngmnCore

/// Builds the request sent to Claude for one question.
///
/// Pure, so the prompt can be asserted on without spending money.
public enum AnswerPrompt {
    public struct Prompt: Sendable, Equatable {
        public let system: String
        public let user: String

        public init(system: String, user: String) {
            self.system = system
            self.user = user
        }
    }

    /// How many earlier questions to carry. Enough for a follow-up to have its referent —
    /// "and why now?" is unanswerable without the question before it — without pushing the
    /// whole interview through on every press of the button.
    public static let recentLimit = 6

    /// Assembles the system turn from a profile and the user turn from the conversation.
    ///
    /// Style first, then material: the model reads the shape of the answer before the
    /// substance it is shaping. Both halves are stable for the length of a session, which is
    /// what makes the system turn cacheable — the question deliberately stays out of it.
    ///
    /// Nothing is added that the profile does not say. A house style invented here would be
    /// indistinguishable, in the answer, from one the user chose.
    public static func build(
        question: String, recent: [String], profile: Profile
    ) -> Prompt {
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

        var user = ""
        let carried = recent.suffix(recentLimit)
        if !carried.isEmpty {
            user += "Earlier in this interview:\n"
            user += carried.map { "- \($0)" }.joined(separator: "\n")
            user += "\n\n"
        }
        user += "The question to answer now:\n\(question)"

        return Prompt(system: system, user: user)
    }

    /// A profile carrying only material, for `--notes`.
    public static func build(question: String, recent: [String], notes: String) -> Prompt {
        build(question: question, recent: recent, profile: Profile(notes: notes))
    }
}
