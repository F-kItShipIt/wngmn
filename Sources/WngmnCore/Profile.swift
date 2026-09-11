import Foundation

/// One conversation domain: what to say, how to say it, and the words it uses.
///
/// A founder pitch, an investor panel and a product demo want different substance *and* a
/// different shape of answer, and they mangle different jargon. Keeping all three in one
/// markdown file per domain means switching domains is switching files — no flags to
/// remember, no code to touch, and nothing shared between them that could leak from one
/// call into the next.
///
/// Three headings, chosen over front-matter because YAML would be a dependency and the
/// project's setup deliberately needs no network fetch:
///
/// ```markdown
/// # Investor panel
///
/// ## Style
/// Three to five bullets, each a sentence I can say as written.
///
/// ## Context
/// Raised $12M Series A in March 2026.
///
/// ## Terms
/// Kubernetes | cuber netties
/// ```
public struct Profile: Sendable, Equatable {
    /// The `#` title, for reporting which profile is loaded. Cosmetic.
    public let name: String
    /// How answers should be shaped. Becomes the instruction half of the system prompt.
    public let style: String
    /// The substance to draw on. Becomes the material half.
    public let context: String
    /// Jargon repair for this domain only.
    public let terms: TermList
    /// Headings that are not one of the three. Almost always a typo, and a silently
    /// ignored section is material the user wrote that never reaches the model.
    public let unknownSections: [String]

    public static let empty = Profile(text: "")

    public var isEmpty: Bool { style.isEmpty && context.isEmpty && terms.isEmpty }

    public init(text: String) {
        var name = ""
        var sections: [String: [String]] = [:]
        var unknown: [String] = []
        var current: String?

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Only `##` opens a section. A `###` inside Context is the user's own structure
            // and has to survive untouched.
            if trimmed.hasPrefix("## ") {
                let heading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                switch heading.lowercased() {
                case "style", "context", "terms":
                    current = heading.lowercased()
                    sections[heading.lowercased()] = []
                default:
                    current = nil
                    unknown.append(heading)
                }
                continue
            }
            if trimmed.hasPrefix("# "), current == nil, name.isEmpty {
                name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let current { sections[current, default: []].append(String(line)) }
        }

        func body(_ key: String) -> String {
            (sections[key] ?? []).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.name = name
        style = body("style")
        context = body("context")
        terms = TermList(text: body("terms"))
        unknownSections = unknown
    }

    /// A profile made from a plain notes file: all of it is context.
    ///
    /// A notes file is written without the three sections in mind, so a `## ` heading in it
    /// is the writer's own structure, not a boundary. Wrapped under `## Context` as it
    /// stood, every such heading opened an unknown section and the material under it never
    /// reached the model — silently, because the notes path had no reason to report unknown
    /// sections. Demoting them one level keeps both the structure and the text.
    public init(notes: String) {
        let normalized = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // The same notion of leading space as the parser's `trimmingCharacters(in:
        // .whitespaces)`, or a heading behind a non-breaking space would slip past this and
        // still open a section there.
        let demoted = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let body = line.drop(while: { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) })
            guard body.hasPrefix("## ") else { return String(line) }
            return String(line[line.startIndex..<body.startIndex]) + "#" + String(body)
        }
        self.init(text: "## Context\n" + demoted.joined(separator: "\n"))
    }

    private init(
        name: String, style: String, context: String, terms: TermList, unknownSections: [String]
    ) {
        self.name = name
        self.style = style
        self.context = context
        self.terms = terms
        self.unknownSections = unknownSections
    }

    /// Where `--profile <value>` points.
    ///
    /// A bare word is the common case and resolves inside `profiles/`, so switching domains
    /// is `--profile investor` rather than a path. Anything containing a separator or an
    /// extension is taken as written, so an absolute path still works.
    public static func resolve(_ value: String, relativeTo directory: URL) -> URL {
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        if value.contains("/") || value.hasSuffix(".md") {
            // `appendingPathComponent` rather than `URL(fileURLWithPath:relativeTo:)`: the
            // latter reads a base without a trailing slash as a *file* and silently discards
            // it, turning `sub/dir.md` into `/sub/dir.md` at the filesystem root.
            return directory.appendingPathComponent(value).standardizedFileURL
        }
        return directory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("\(value).md")
    }

    /// Loads a profile. A missing file is the caller's problem to report — answering with
    /// no material looks identical to answering well until the answer is read.
    public static func load(from url: URL) throws -> Profile {
        Profile(text: try String(contentsOf: url, encoding: .utf8))
    }
}
