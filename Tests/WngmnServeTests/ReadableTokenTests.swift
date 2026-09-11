import Testing
@testable import WngmnServe

/// The token gets typed into a phone, so it has to be typeable — but it is still the only
/// thing standing between the transcript and everyone else on the wifi.
@Suite("Readable token")
struct ReadableTokenTests {
    @Test("Short enough to type, long enough not to be guessed")
    func length() {
        let token = AccessToken.generateReadable()
        #expect(token.count == 8)
    }

    /// Characters that look alike are the whole reason a token gets mistyped. Dropping
    /// them costs a fraction of a bit each and removes the commonest failure.
    @Test("Ambiguous characters never appear")
    func noAmbiguousCharacters() {
        // 400 tokens is 3200 characters — enough that any allowed character shows up.
        let all = (0..<400).map { _ in AccessToken.generateReadable() }.joined()
        for character in "01loiIO" {
            #expect(!all.contains(character), "'\(character)' is too easy to mistype")
        }
        #expect(all.allSatisfy { $0.isLowercase || $0.isNumber })
    }

    @Test("Tokens differ from one another")
    func distinct() {
        let tokens = Set((0..<200).map { _ in AccessToken.generateReadable() })
        #expect(tokens.count > 190, "got \(tokens.count) distinct out of 200")
    }

    /// A truncated file must not become a two-character token that authenticates.
    @Test("Stored tokens are validated by shape, not just by length")
    func validation() {
        #expect(AccessToken.isPlausibleStoredToken("k7m2xq4h"))
        #expect(AccessToken.isPlausibleStoredToken("ff276e211d7fc26f1ae4312dedfc7437"))
        #expect(!AccessToken.isPlausibleStoredToken(""))
        #expect(!AccessToken.isPlausibleStoredToken("abc"))
        #expect(!AccessToken.isPlausibleStoredToken("has space"))
        #expect(!AccessToken.isPlausibleStoredToken("has/slash"))
    }
}
