import Foundation

public extension String {
    /// Whether this token is short enough to be guessed rather than found.
    ///
    /// Not a refusal — it is the user's network and their call — but the binary says so at
    /// startup, because the transcript on that port carries someone else's words as well as
    /// their own, and "t=me" is one guess.
    var isWeakToken: Bool { count < 16 }
}
