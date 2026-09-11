import Foundation

/// A bearer token for the LAN-exposed transcript.
///
/// Only used with `--listen`. On loopback there is nothing to authenticate: the page is
/// already reachable only by processes on this machine. Once the port is on the wifi, the
/// transcript of a confidential press interview is on the wifi, so the token is not optional
/// there.
public enum AccessToken {
    /// 128 bits, hex-encoded. `SystemRandomNumberGenerator` is the CSPRNG.
    public static func generate() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &g)) }
            .joined()
    }

    /// Characters that cannot be confused with one another when read off a screen and typed
    /// into a phone. No `0`/`O`, no `1`/`l`/`I`. Lowercase throughout, because a shifted
    /// character on a phone keyboard is an extra tap and an extra chance to get it wrong.
    static let readableAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    /// A token short enough to type and still impractical to guess.
    ///
    /// Eight characters of a 31-symbol alphabet is a little under 40 bits — roughly 850
    /// billion possibilities. Against a service on your own wifi with no rate limiting,
    /// that is still thousands of years of guessing, while a 32-character hex string is
    /// simply not going to be typed correctly on a phone at the start of a call.
    public static func generateReadable(length: Int = 8) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            readableAlphabet[Int.random(in: 0..<readableAlphabet.count, using: &generator)]
        })
    }

    /// Whether a token read back from disk is shaped like one we wrote.
    ///
    /// A truncated or hand-edited file must not become a two-character token that
    /// nonetheless authenticates, so anything too short or carrying a character that would
    /// need escaping in a URL is rejected and replaced.
    public static func isPlausibleStoredToken(_ token: String) -> Bool {
        guard token.count >= 8 else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) }
    }

    /// Constant-time comparison.
    ///
    /// `==` on String returns as soon as two bytes differ, and the caller here is remote:
    /// the timing of the reply is observable to whoever is probing the port. Comparing every
    /// byte regardless costs nothing at this length.
    public static func matches(_ expected: String, _ candidate: String) -> Bool {
        let a = Array(expected.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
