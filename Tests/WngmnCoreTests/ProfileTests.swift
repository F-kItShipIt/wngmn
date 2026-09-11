import Foundation
import Testing
@testable import WngmnCore

/// One file per domain: what to say, and how to say it.
@Suite("Profile")
struct ProfileTests {
    static let investor = """
    # Investor panel — Series B

    ## Style
    Three to five bullets, each a sentence I can say as written.
    Lead with the number, then the reason.

    ## Context
    Raised $12M Series A March 2026.
    ARR $4.1M as of Q3, up 3.2x year over year.

    ## Terms
    Mixstream | mix stream
    ARR | the air
    """

    @Test("The three sections are read into their own fields")
    func parsesSections() {
        let profile = Profile(text: Self.investor)
        #expect(profile.name == "Investor panel — Series B")
        #expect(profile.style.contains("Three to five bullets"))
        #expect(profile.style.contains("Lead with the number"))
        #expect(profile.context.contains("Raised $12M Series A March 2026."))
        #expect(profile.context.contains("ARR $4.1M"))
        // A heading is a delimiter, not content.
        #expect(!profile.style.contains("## Context"))
        #expect(!profile.context.contains("Three to five bullets"))
    }

    /// An investor call and a technical one mangle different words, which is the whole
    /// reason the vocabulary belongs to the profile rather than to one global file.
    @Test("Terms become a usable term list")
    func parsesTerms() {
        let profile = Profile(text: Self.investor)
        #expect(!profile.terms.isEmpty)
        #expect(TextNormalizer.correct("what is the air now", terms: profile.terms) == "what is ARR now")
        #expect(TextNormalizer.correct("tell me about mix stream", terms: profile.terms)
            == "tell me about Mixstream")
    }

    @Test("Headings are recognised whatever their case")
    func headingCaseInsensitive() {
        let profile = Profile(text: "## STYLE\nBe brief.\n\n## context\nA fact.")
        #expect(profile.style == "Be brief.")
        #expect(profile.context == "A fact.")
    }

    @Test("Missing sections are empty rather than an error")
    func missingSections() {
        let profile = Profile(text: "# Just a title\n\n## Context\nOnly context here.")
        #expect(profile.style.isEmpty)
        #expect(profile.context == "Only context here.")
        #expect(profile.terms.isEmpty)
    }

    /// A misspelled heading would otherwise vanish silently, and the user would be left
    /// wondering why material they wrote never reaches the model.
    @Test("Unrecognised sections are reported, not swallowed")
    func reportsUnknownSections() {
        let profile = Profile(text: "## Stlye\nOops.\n\n## Background\nAlso oops.")
        #expect(profile.unknownSections == ["Stlye", "Background"])
        #expect(profile.style.isEmpty)
    }

    /// Context is markdown the user wrote; nested structure has to survive intact.
    @Test("Markdown inside a section is preserved verbatim")
    func preservesInnerMarkdown() {
        let profile = Profile(text: """
        ## Context
        ### Funding
        - $12M Series A
        - **Lead:** Someone

        A closing line.
        """)
        #expect(profile.context.contains("### Funding"))
        #expect(profile.context.contains("- **Lead:** Someone"))
        #expect(profile.context.hasSuffix("A closing line."))
    }

    @Test("An empty file yields an empty profile rather than failing")
    func emptyFile() {
        let profile = Profile(text: "")
        #expect(profile.style.isEmpty)
        #expect(profile.context.isEmpty)
        #expect(profile.name.isEmpty)
    }
}

@Suite("Profile resolution")
struct ProfileResolutionTests {
    /// A bare word is the common case — `--profile investor`, not a path.
    @Test("A bare name resolves inside the profiles directory")
    func bareName() {
        let url = Profile.resolve("investor", relativeTo: URL(fileURLWithPath: "/work"))
        #expect(url.path == "/work/profiles/investor.md")
    }

    @Test("Anything path-shaped is taken as written")
    func explicitPaths() {
        #expect(Profile.resolve("/abs/thing.md", relativeTo: URL(fileURLWithPath: "/work")).path
            == "/abs/thing.md")
        #expect(Profile.resolve("./here.md", relativeTo: URL(fileURLWithPath: "/work")).lastPathComponent
            == "here.md")
        #expect(Profile.resolve("sub/dir.md", relativeTo: URL(fileURLWithPath: "/work")).path
            == "/work/sub/dir.md")
    }
}

/// `--notes` wraps a plain file as the context of a profile.
extension ProfileTests {
    /// A notes file is written without the profile's three sections in mind, so a `##`
    /// heading in it is the writer's own structure, not a section boundary. Treated as one,
    /// everything under it fell into an unknown section and never reached the model — with
    /// no message, since the notes path never reported unknown sections.
    @Test("Notes keep their own headings as part of the context")
    func notesKeepTheirHeadings() {
        let profile = Profile(notes: "Intro line.\n## Funding\nRaised $12M.\n### Detail\nIn March.")
        #expect(profile.context.contains("Raised $12M."))
        #expect(profile.context.contains("In March."))
        #expect(profile.context.contains("### Funding"), "the heading was dropped rather than kept")
        #expect(profile.unknownSections.isEmpty)
        #expect(profile.style.isEmpty)
        #expect(profile.terms.isEmpty)
    }

    /// The profile parser trims every kind of space before it looks for `## `, so the
    /// demotion has to see the same line it does — a heading behind a non-breaking space
    /// was missed, opened an unknown section, and dropped everything under it.
    @Test("A heading indented with a non-breaking space is still kept")
    func nbspIndentedHeadingIsKept() {
        let profile = Profile(notes: "\u{00A0}## Funding\nRaised $12M.")
        #expect(profile.unknownSections.isEmpty, "the heading opened a section: \(profile.unknownSections)")
        #expect(profile.context.contains("Raised $12M."))
    }

    @Test("Empty notes make an empty profile")
    func emptyNotes() {
        #expect(Profile(notes: "").isEmpty)
        #expect(Profile(notes: "   \n").isEmpty)
    }
}
