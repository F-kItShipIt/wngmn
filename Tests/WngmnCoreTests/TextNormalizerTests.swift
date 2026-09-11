import Testing
import Foundation
@testable import WngmnCore

@Suite("TextNormalizer")
struct TextNormalizerTests {
    @Test("Leading punctuation left by a forced finalisation is stripped")
    func stripsForcedFinalizationArtifact() {
        // Verbatim shape observed from finalize(through:) firing mid-stream.
        #expect(
            TextNormalizer.stripArtifacts(#"",... And what is next for the company?"#)
                == "And what is next for the company?"
        )
        #expect(TextNormalizer.stripArtifacts(". So tell me about it.") == "So tell me about it.")
        #expect(TextNormalizer.stripArtifacts("…  and then?") == "and then?")
        #expect(TextNormalizer.stripArtifacts("   ,  ") == "")
    }

    @Test("Whitespace is collapsed and space-before-punctuation removed")
    func collapsesWhitespace() {
        #expect(TextNormalizer.stripArtifacts("So   tell\nme  about\tit .") == "So tell me about it.")
    }

    @Test("An opening quote is not mistaken for an artifact")
    func keepsIntentionalOpeners() {
        #expect(TextNormalizer.stripArtifacts("\"Move fast\" — is that still true?")
                == "\"Move fast\" — is that still true?")
    }

    @Test("Explicit aliases repair errors that fuzzy matching cannot reach")
    func explicitAliases() {
        let terms = TermList(text: """
        # jargon
        ARR | the air | a r r
        Series A | series 8 | series eight
        """)
        #expect(TextNormalizer.correct("what is your the air today", terms: terms)
                == "what is your ARR today")
        #expect(TextNormalizer.correct("you raised a series 8 round", terms: terms)
                == "you raised a Series A round")
        #expect(TextNormalizer.correct("you raised a series eight round", terms: terms)
                == "you raised a Series A round")
    }

    @Test("Fuzzy matching repairs unpredictable mis-transcriptions of a canonical term")
    func fuzzyMatching() {
        let terms = TermList(text: "Mixstream")
        // Observed error: Mixstream -> "Mixedream".
        #expect(TextNormalizer.correct("tell me about Mixedream", terms: terms)
                == "tell me about Mixstream")
        #expect(TextNormalizer.correct("tell me about mixstream", terms: terms)
                == "tell me about Mixstream")
    }

    @Test("Ordinary words are not rewritten into terms")
    func noFalsePositives() {
        let terms = TermList(text: """
        Mixstream
        ARR | the air
        Series A
        """)
        let sentence = "That is a serious mainstream question about the airline industry."
        #expect(TextNormalizer.correct(sentence, terms: terms) == sentence)
    }

    @Test("An empty term list is a no-op")
    func emptyTermList() {
        #expect(TermList.empty.isEmpty)
        let s = "Nothing here should change at all."
        #expect(TextNormalizer.normalizeFinal(s, terms: .empty) == s)
    }

    @Test("Comments and blank lines are ignored when parsing terms")
    func parsesTermsFile() {
        let terms = TermList(text: """

        # a comment
        Mixstream

        ARR | the air |
        """)
        #expect(terms.terms.count == 2)
        #expect(terms.terms.map(\.canonical) == ["Mixstream", "ARR"])
        #expect(terms.maxTokens == 2)
    }

    @Test("Longest match wins when terms overlap")
    func longestMatchWins() {
        let terms = TermList(text: """
        Series A
        Series A Extension | series 8 extension
        """)
        #expect(TextNormalizer.correct("the series 8 extension closed", terms: terms)
                == "the Series A Extension closed")
    }

    @Test("The full pass strips artifacts before correcting jargon")
    func fullPass() {
        let terms = TermList(text: "ARR | the air")
        #expect(
            TextNormalizer.normalizeFinal(#",... so what is the air now?"#, terms: terms)
                == "So what is ARR now?"
        )
    }

    @Test("Edit distance abandons early past the budget")
    func editDistanceBudget() {
        #expect(TextNormalizer.editDistance("mixstream", "mixedream", limit: 3) == 2)
        #expect(TextNormalizer.editDistance("mixstream", "banana", limit: 3) == nil)
        #expect(TextNormalizer.editDistance("abc", "abc", limit: 0) == 0)
        #expect(TextNormalizer.fuzzyBudget(3) == 1)
        #expect(TextNormalizer.fuzzyBudget(9) == 2)
    }

    @Test("Match keys fold case, punctuation and numerals together")
    func matchKeys() {
        #expect(TextNormalizer.matchKey("Series A") == "series a")
        #expect(TextNormalizer.matchKey("series 8") == "series 8")
        #expect(TextNormalizer.matchKey("Series Eight!") == "series 8")
        #expect(TextNormalizer.matchKey("  ...  ") == "")
    }
}

@Suite("Continuation seams")
struct ContinuationSeamTests {
    @Test("Sentence-initial capitalisation is restored after a forced final")
    func capitalises() {
        #expect(TextNormalizer.normalizeFinal("and what is next?") == "And what is next?")
        #expect(TextNormalizer.normalizeFinal("What is next?") == "What is next?")
    }

    @Test("A deliberately lower-case term keeps its spelling")
    func keepsLowercaseTerms() {
        let terms = TermList(text: "iPhone\nfintech")
        #expect(TextNormalizer.normalizeFinal("fintech is crowded.", terms: terms) == "fintech is crowded.")
    }

    @Test("Joining the halves of a hesitated question repairs the seam")
    func joinsHalves() {
        // A forced boundary leaves a full stop the speaker never made, and capitalises the
        // resumption. Both are artifacts, and the result is read aloud off a screen.
        #expect(
            TextNormalizer.joinContinuation(
                "So tell me a bit about.", "The funding round you just closed.", terms: .empty
            ) == "So tell me a bit about the funding round you just closed."
        )
    }

    @Test("A real question mark is not treated as a seam artifact")
    func keepsRealTerminators() {
        #expect(
            TextNormalizer.joinContinuation("Why now?", "And why you?", terms: .empty)
                == "Why now? And why you?"
        )
    }

    @Test("An unrecognised capitalised word is left alone rather than lower-cased")
    func doesNotLowercaseProperNouns() {
        // Only a closed set of continuation words is lower-cased; guessing at names would
        // mangle them.
        #expect(
            TextNormalizer.joinContinuation("So tell me about.", "Sequoia leading it.", terms: .empty)
                == "So tell me about Sequoia leading it."
        )
    }
}

/// Regression suite for false-positive corrections.
///
/// A wngmn shows these words to a person who reads them aloud on camera. A missed jargon
/// repair is a small cost; rewriting an ordinary word is a visible error in a live interview,
/// so this suite exists to keep the matcher conservative.
@Suite("Jargon false positives")
struct JargonFalsePositiveTests {
    /// The same shape as the shipped terms.txt: short acronyms plus a long product name.
    let terms = TermList(text: """
    Mixstream | mix stream | mixed stream | mixed ream
    ARR | the air | a r r
    MRR | the mrr
    Series A | series 8 | series eight
    """)

    @Test("Common words near a short acronym are never rewritten")
    func shortAcronymsDoNotSwallowCommonWords() {
        // One edit on a three-letter term is a third of the word, so an unrestricted fuzzy
        // match turns "are" — one of the commonest words in an interview question — into
        // "ARR". Short terms are matched by alias only, which is what fixes this.
        for sentence in [
            "What are your margins on that?",
            "Where are the biggest costs right now?",
            "How far are we from profitability?",
            "What art does the office have on the walls?",
            "Mrs Chen led the round, is that right?",
        ] {
            #expect(TextNormalizer.correct(sentence, terms: terms) == sentence, "corrupted: \(sentence)")
        }
    }

    @Test("An alias that is also an ordinary phrase is replaced wherever it appears")
    func explicitAliasesAreLiteral() {
        // Documenting a trade-off rather than a bug. `ARR -> "the air"` is the error the
        // recogniser actually makes, and the founder will be asked about ARR all day, so the
        // alias earns its place. The cost is that "the air quality" becomes "ARR quality".
        // Aliases are matched literally and always; that is what makes them useful and what
        // makes an alias that is also a real phrase a deliberate choice.
        #expect(
            TextNormalizer.correct("Is the air quality in the office a problem?", terms: terms)
                == "Is ARR quality in the office a problem?"
        )
        // Removing the alias removes the cost, and the repair with it.
        let without = TermList(text: "ARR | a r r")
        #expect(
            TextNormalizer.correct("Is the air quality in the office a problem?", terms: without)
                == "Is the air quality in the office a problem?"
        )
    }

    @Test("A canonical short enough to be an ordinary word is not case-rewritten")
    func shortCanonicalsDoNotCaseRewrite() {
        let risky = TermList(text: "SAFE\nARR")
        #expect(TextNormalizer.correct("Is the data safe here?", terms: risky) == "Is the data safe here?")
        #expect(TextNormalizer.correct("we use a safe structure", terms: risky) == "we use a safe structure")
    }

    @Test("A long canonical is still case-corrected")
    func longCanonicalsStillCaseCorrect() {
        #expect(TextNormalizer.correct("tell me about mixstream", terms: terms) == "tell me about Mixstream")
        #expect(TextNormalizer.correct("you raised a series a round", terms: terms) == "you raised a Series A round")
    }

    @Test("Explicit aliases still repair short acronyms")
    func aliasesStillWork() {
        #expect(TextNormalizer.correct("what is the air now", terms: terms) == "what is ARR now")
        #expect(TextNormalizer.correct("tell me about mixed stream", terms: terms) == "tell me about Mixstream")
        #expect(TextNormalizer.correct("a series 8 round", terms: terms) == "a Series A round")
    }

    /// The list the README documents, run over sentences full of the ordinary words its
    /// short canonicals resemble. This used to read a `terms.txt` from the working
    /// directory, which no longer exists, so it passed by never checking anything.
    @Test("The documented term list is free of these false positives")
    func documentedTermListIsSafe() {
        let documented = TermList(text: """
        # the README's example
        Mixstream | mix stream | mixed stream
        ARR | the air | a r r
        Series A | series 8 | series eight
        SAFE
        """)
        for sentence in [
            "So tell me, what are your margins, and how safe is the data you collect?",
            "How far are we from profitability, and is the data safe?",
        ] {
            #expect(TextNormalizer.correct(sentence, terms: documented) == sentence)
        }
    }
}

@Suite("Punctuation-run artifacts")
struct PunctuationRunTests {
    // The last line of defence: when no volatile survives to rescue the region, the user
    // must not be shown the debris. A wngmn is read aloud under time pressure.
    @Test("An interior run of full stops is removed rather than shown")
    func stripsInteriorRun() {
        #expect(TextNormalizer.stripArtifacts("that.......... such that they add up")
                == "that such that they add up")
    }

    @Test("Ordinary punctuation and a deliberate ellipsis are left alone")
    func leavesOrdinaryPunctuation() {
        #expect(TextNormalizer.stripArtifacts("So, tell me... why now?") == "So, tell me... why now?")
        #expect(TextNormalizer.stripArtifacts("How big is the team?") == "How big is the team?")
    }
}
