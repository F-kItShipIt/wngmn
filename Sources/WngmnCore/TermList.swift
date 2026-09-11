import Foundation

/// A user-supplied vocabulary used to repair jargon the on-device recogniser gets wrong.
///
/// There is no vocabulary-biasing lever on this path — `AnalysisContext.contextualStrings`
/// is a proven no-op for `SpeechTranscriber` — so correction is necessarily post-hoc, and
/// is applied to finalised text only.
///
/// File format (`terms.txt`), one term per line:
/// ```
/// # comments start with a hash
/// Kubernetes
/// ARR | the air | a r r
/// Series A | series 8 | series eight
/// ```
/// The first field is the canonical spelling that gets emitted. Later fields are explicit
/// aliases matched exactly (case- and numeral-insensitively). The canonical spelling is
/// additionally matched fuzzily, which is what catches unpredictable errors like
/// `Mixstream -> "Mixedream"`.
public struct TermList: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let canonical: String
        /// The canonical spelling's own match key. Kept separate from `aliases` because it
        /// is matched under a stricter rule: a canonical that is itself an ordinary English
        /// word (`SAFE`) would otherwise rewrite every occurrence of that word.
        public let canonicalKey: String
        /// Normalised forms the user listed explicitly. These are always matched — the user
        /// asked for them by name.
        public let aliases: [String]
        /// Widest n-gram this term can match, across the canonical and every alias.
        public let tokenCount: Int
        /// Token count of the canonical spelling alone. Fuzzy matching compares against the
        /// canonical, so it sizes its window from this rather than from a longer alias.
        public let canonicalTokenCount: Int

        public init(
            canonical: String, canonicalKey: String, aliases: [String],
            tokenCount: Int, canonicalTokenCount: Int
        ) {
            self.canonical = canonical
            self.canonicalKey = canonicalKey
            self.aliases = aliases
            self.tokenCount = tokenCount
            self.canonicalTokenCount = canonicalTokenCount
        }
    }

    public let terms: [Term]
    /// Widest n-gram any term needs. Zero when the list is empty.
    public let maxTokens: Int

    public init(terms: [Term]) {
        self.terms = terms
        self.maxTokens = terms.map(\.tokenCount).max() ?? 0
    }

    public static let empty = TermList(terms: [])

    public var isEmpty: Bool { terms.isEmpty }

    public init(text: String) {
        var parsed: [Term] = []
        // Normalise line endings first: a file saved with classic-Mac or Windows endings
        // would otherwise parse as a single enormous term that matches nothing and quietly
        // disables jargon correction for the whole interview.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard let canonical = fields.first else { continue }

            let canonicalKey = TextNormalizer.matchKey(canonical)
            guard !canonicalKey.isEmpty else { continue }
            let canonicalTokens = TextNormalizer.tokens(in: canonical).count
            var widest = canonicalTokens

            var forms = Set<String>()
            for field in fields.dropFirst() {
                let key = TextNormalizer.matchKey(field)
                let fieldTokens = TextNormalizer.tokens(in: field).count
                // An alias wider than the scan window could never be matched; skipping it
                // keeps `tokenCount` honest instead of sizing the window for a form that
                // will never be tried.
                guard !key.isEmpty, fieldTokens <= TextNormalizer.maxTermTokens else { continue }
                forms.insert(key)
                widest = max(widest, fieldTokens)
            }
            guard widest > 0, canonicalTokens <= TextNormalizer.maxTermTokens else { continue }

            parsed.append(Term(
                canonical: canonical,
                canonicalKey: canonicalKey,
                aliases: forms.sorted { $0.count > $1.count },
                tokenCount: min(widest, TextNormalizer.maxTermTokens),
                canonicalTokenCount: min(canonicalTokens, TextNormalizer.maxTermTokens)
            ))
        }
        self.init(terms: parsed)
    }

    /// Loads `terms.txt`. A missing file is not an error — the list is simply empty.
    public static func load(from url: URL) throws -> TermList {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return TermList(text: try String(contentsOf: url, encoding: .utf8))
    }
}
