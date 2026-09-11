import Testing
@testable import WngmnCore

/// A stable token, so one bookmarked URL keeps working across runs instead of a fresh
/// 32-character string having to be retyped on a phone every session.
@Suite("Serve token")
struct ServeTokenTests {
    @Test("No token is fixed by default, so each run still generates its own")
    func defaultsToGenerated() throws {
        #expect(try Options.parse([]).serveToken == nil)
        #expect(try Options.parse(["--listen"]).serveToken == nil)
    }

    /// A token only means anything once the port is on the network, so asking for one is
    /// asking to serve on it.
    @Test("Setting a token implies listening on the network")
    func tokenImpliesListen() throws {
        let o = try Options.parse(["--token", "me"])
        #expect(o.serveToken == "me")
        #expect(o.serveOnLAN)
        #expect(o.serve)
    }

    /// The token is pasted into a query string, so anything needing escaping would produce a
    /// URL that silently does not match.
    @Test("A token that would not survive a URL is rejected")
    func rejectsUnsafeTokens() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["--token", ""]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--token", "a b"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--token", "a&b=c"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--token", "a/b"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--token"]) }
    }

    @Test("Ordinary word and hex tokens are accepted")
    func acceptsUsableTokens() throws {
        #expect(try Options.parse(["--token", "me"]).serveToken == "me")
        #expect(try Options.parse(["--token", "sami-laptop_2"]).serveToken == "sami-laptop_2")
        #expect(try Options.parse(["--token", "0043fd2fb90f86988a5da620f94c3aec"]).serveToken?.count == 32)
    }

    /// Short tokens are guessable, and the transcript carries someone else's words. Allowed,
    /// because it is the user's network and their call — but the binary says so out loud.
    @Test("A guessable token is flagged as weak without being refused")
    func flagsWeakTokens() throws {
        #expect(try #require(Options.parse(["--token", "me"]).serveToken).isWeakToken)
        #expect(try !#require(Options.parse(["--token", "0043fd2fb90f86988a5da620f94c3aec"]).serveToken).isWeakToken)
    }
}
