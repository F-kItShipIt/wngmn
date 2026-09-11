import Foundation

/// Cleans up finalised transcript text before it is emitted as a question.
///
/// Two jobs, both driven by observed failures rather than by theory:
///
/// * Forced finalisation (`finalize(through:)` fired by the VAD rather than by the
///   framework's own endpoint) leaves punctuation artifacts at the head of the string —
///   observed: `",... And what is next for the company?"`.
/// * The on-device recogniser mangles domain jargon and there is no biasing API to prevent
///   it — observed: `ARR -> "the air"`, `Series A -> "series 8"`, `Mixstream -> "Mixedream"`.
///
/// Correction runs on finalised text only. Volatile text is never repaired: it is replaced
/// milliseconds later anyway, and rewriting it would make the partial stream flicker.
public enum TextNormalizer {
    /// Upper bound on the n-gram window, so a pathological terms file cannot make
    /// correction quadratic in a long sentence.
    public static let maxTermTokens = 6

    /// Full pass: whitespace, leading-punctuation artifacts, jargon repair, then sentence
    /// capitalisation.
    public static func normalizeFinal(_ text: String, terms: TermList = .empty) -> String {
        let cleaned = stripArtifacts(text)
        let corrected = terms.isEmpty ? cleaned : correct(cleaned, terms: terms)
        return capitalizeFirst(corrected, terms: terms)
    }

    /// A forced finalisation mid-conversation returns text that starts lowercase, because
    /// the recogniser did not think it was starting a sentence. On a wngmn the user is
    /// reading these, so the first letter gets fixed.
    static func capitalizeFirst(_ text: String, terms: TermList) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        // Leave a deliberately lower-cased term alone.
        if let token = tokens(in: text).first, token.range.lowerBound == text.startIndex {
            let key = matchKey(token.text)
            if terms.terms.contains(where: { matchKey($0.canonical) == key && $0.canonical.first?.isLowercase == true }) {
                return text
            }
        }
        return text.replacingCharacters(
            in: text.startIndex..<text.index(after: text.startIndex),
            with: String(first).uppercased()
        )
    }

    /// Joins the two halves of a question the journalist paused in the middle of.
    ///
    /// Both halves carry artifacts from being finalised at a point that was not a sentence
    /// boundary: the first ends with a full stop the speaker never made, and the second
    /// begins with a capital. Fixing the seam matters because the result is read aloud from
    /// the screen under time pressure.
    public static func joinContinuation(_ previous: String, _ next: String, terms: TermList) -> String {
        var head = previous
        // A comma or full stop at a forced boundary is an artifact. A question or
        // exclamation mark is not — the speaker really did finish a clause there.
        while let last = head.last, last == "." || last == "," {
            head.removeLast()
            head = head.trimmingCharacters(in: .whitespaces)
        }

        // If a real sentence terminator survived the trim, the speaker did finish a
        // sentence there and the resumption genuinely starts a new one.
        let headEndsSentence = head.last.map { $0 == "?" || $0 == "!" } ?? false

        var tail = next
        if !headEndsSentence,
           let token = tokens(in: tail).first,
           token.range.lowerBound == tail.startIndex,
           continuationWords.contains(token.text.lowercased()),
           token.text.first?.isUppercase == true {
            tail = tail.replacingCharacters(
                in: token.range,
                with: token.text.lowercased()
            )
        }

        guard !head.isEmpty else { return capitalizeFirst(tail, terms: terms) }
        guard !tail.isEmpty else { return head }
        return head + " " + tail
    }

    /// A closed set, deliberately. Lower-casing an arbitrary capitalised word would mangle
    /// a name; these are the words a half-finished question actually resumes with.
    private static let continuationWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "that", "this", "these", "those",
        "your", "you", "their", "they", "it", "its", "our", "we", "i",
        "in", "on", "at", "for", "with", "about", "from", "to", "of", "into", "over",
        "how", "what", "when", "where", "why", "who", "which", "whether",
        "is", "are", "was", "were", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "might", "may",
        "if", "so", "as", "by", "after", "before", "since", "because", "while", "than",
        "then", "just", "really", "actually", "maybe", "sort", "kind", "like", "back",
    ]

    /// Whitespace and punctuation cleanup, without jargon repair.
    public static func stripArtifacts(_ text: String) -> String {
        // Collapse all whitespace runs, including the newlines the recogniser sometimes emits.
        var s = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // Drop leading punctuation left behind by a forced finalisation. Stop at the first
        // character that could legitimately start a sentence.
        while let first = s.first, isLeadingArtifact(first, rest: s.dropFirst()) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }

        // An *interior* run of full stops or commas is never real text either: it is what a
        // forced finalisation leaves where it dropped a phrase. Measured on a seven-second
        // question — `"that.......... such that they add up"`, six words gone.
        //
        // This runs after the leading-artifact loop on purpose. Ahead of it, a leading
        // `",...` collapses to a bare quote, and the opener rule then sees a letter next
        // and keeps it — turning one artifact into a subtler one.
        //
        // Four or more, so a deliberate three-dot ellipsis survives untouched. This is the
        // last line of defence, not the repair: when a volatile survives for the region the
        // whole clause is recovered instead. It exists because the user reads this aloud
        // under time pressure and must never be handed the debris.
        s = s.replacingOccurrences(of: "[.,]{4,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // A space before terminal punctuation is another forced-finalisation artifact.
        s = s.replacingOccurrences(
            of: " ([,.;:!?])", with: "$1", options: .regularExpression
        )
        return s
    }

    private static func isLeadingArtifact(_ c: Character, rest: Substring) -> Bool {
        if c.isLetter || c.isNumber { return false }
        // An opening quote or bracket is intentional only when content follows it directly.
        // Forced finalisation produces runs like `",... And what is next` — the quote there
        // is as much an artifact as the comma that follows it.
        let next = rest.drop(while: { $0.isWhitespace }).first
        if openers.contains(c) {
            guard let next else { return true }
            return !(next.isLetter || next.isNumber)
        }
        // A currency symbol introducing a number is part of the sentence, not debris:
        // "$50 million" must not become "50 million" on a question about a raise.
        if c.isCurrencySymbol, let next, next.isNumber { return false }
        return c.isPunctuation || c.isSymbol || c.isWhitespace
    }

    private static let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "[", "{"]

    // MARK: - Jargon repair

    /// Replaces recognised aliases and near-misses with their canonical spellings.
    public static func correct(_ text: String, terms: TermList) -> String {
        guard !terms.isEmpty, terms.maxTokens > 0 else { return text }
        let toks = tokens(in: text)
        guard !toks.isEmpty else { return text }

        // Left-to-right, longest match wins. Replacements are collected and applied from the
        // end so that earlier ranges stay valid.
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0
        while i < toks.count {
            var matched = false
            let widest = min(terms.maxTokens, toks.count - i)
            var n = widest
            while n >= 1 {
                let window = toks[i..<(i + n)]
                let key = matchKey(window.map(\.text).joined(separator: " "))
                if !key.isEmpty, let term = bestTerm(for: key, tokenCount: n, in: terms) {
                    let range = window.first!.range.lowerBound..<window.last!.range.upperBound
                    // Rewrite unless the span is already exactly the canonical spelling.
                    // A case-only difference is still a correction worth making.
                    if String(text[range]) != term.canonical {
                        replacements.append((range, term.canonical))
                    }
                    i += n
                    matched = true
                    break
                }
                n -= 1
            }
            if !matched { i += 1 }
        }

        guard !replacements.isEmpty else { return text }
        var out = text
        for (range, canonical) in replacements.reversed() {
            out.replaceSubrange(range, with: canonical)
        }
        return out
    }

    private static func bestTerm(for key: String, tokenCount: Int, in terms: TermList) -> TermList.Term? {
        // An explicitly listed alias always wins: the user asked for it by name.
        for term in terms.terms where term.tokenCount >= tokenCount {
            if term.aliases.contains(key) { return term }
        }
        // The canonical matching itself only fixes capitalisation, and is restricted to
        // terms long enough not to be an ordinary word. Without the length rule, a canonical
        // like `SAFE` rewrites every "safe" in the interview.
        for term in terms.terms where term.canonicalTokenCount == tokenCount {
            if term.canonicalKey == key, term.canonicalKey.count >= minimumFuzzyLength {
                return term
            }
        }
        // Then fuzzy, but only against terms whose canonical spans the same number of tokens.
        var best: (term: TermList.Term, distance: Int)?
        for term in terms.terms where term.canonicalTokenCount == tokenCount {
            let canonicalKey = term.canonicalKey
            // Short terms are never matched fuzzily. One edit on a three-letter acronym is
            // a third of the word, so `ARR` swallows "are", "art" and "air" — and "are" is
            // one of the commonest words in an interview question. Short acronyms are what
            // the alias list is for.
            guard canonicalKey.count >= minimumFuzzyLength else { continue }
            let budget = fuzzyBudget(canonicalKey.count)
            guard let d = editDistance(key, canonicalKey, limit: budget) else { continue }
            // A recognition error preserves the onset: "Mixstream" comes back as
            // "Mixedream", not as "mainstream" — yet those are both two edits away, so
            // distance alone cannot separate them. Requiring a shared prefix can.
            // Applied for any edit at all, not just two: a recognition error preserves the
            // onset, and requiring three shared characters is what separates "mixedream"
            // (a real error) from "mainstream" (a real word).
            if d > 0 && commonPrefixLength(key, canonicalKey) < minimumSharedPrefix { continue }
            if best == nil || d < best!.distance { best = (term, d) }
        }
        return best?.term
    }

    /// Deliberately tight. A budget of three edits on a nine-character term rewrites
    /// "mainstream" into "Mixstream"; two catches the errors actually observed
    /// ("Mixedream", "series 8") while leaving ordinary words alone. An error further away
    /// than this belongs in the alias list, not behind a wider radius.
    static func fuzzyBudget(_ length: Int) -> Int {
        length <= 7 ? 1 : 2
    }

    /// How much of the onset an approximate match must keep. Three characters is what
    /// distinguishes "mixedream" (a real error) from "mainstream" (a real word).
    static let minimumSharedPrefix = 3

    /// Shortest canonical spelling eligible for approximate or case-only matching. Anything
    /// shorter must be listed as an explicit alias.
    static let minimumFuzzyLength = 6

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            n += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return n
    }

    // MARK: - Tokenising and match keys

    public struct Token: Sendable, Equatable {
        public let text: String
        public let range: Range<String.Index>
    }

    /// Maximal runs of letters, digits and internal apostrophes.
    public static func tokens(in text: String) -> [Token] {
        var out: [Token] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isLetter || text[idx].isNumber {
                let start = idx
                while idx < text.endIndex, text[idx].isLetter || text[idx].isNumber
                    || (text[idx] == "'" && text.index(after: idx) < text.endIndex
                        && (text[text.index(after: idx)].isLetter)) {
                    idx = text.index(after: idx)
                }
                out.append(Token(text: String(text[start..<idx]), range: start..<idx))
            } else {
                idx = text.index(after: idx)
            }
        }
        return out
    }

    /// Case-folded, punctuation-free, numeral-normalised form used for all comparisons, so
    /// that `Series A`, `series 8` and `series eight` land in the same space.
    public static func matchKey(_ s: String) -> String {
        let words = tokens(in: s.lowercased()).map { numberWords[$0.text] ?? $0.text }
        return words.joined(separator: " ")
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
        "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
        "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000", "billion": "1000000000",
    ]

    /// Levenshtein distance, abandoning early once `limit` is exceeded. Returns nil when the
    /// strings are further apart than the budget allows.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return nil }
        if x.isEmpty { return y.count <= limit ? y.count : nil }
        if y.isEmpty { return x.count <= limit ? x.count : nil }

        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return nil }
            swap(&prev, &cur)
        }
        let d = prev[y.count]
        return d <= limit ? d : nil
    }
}
