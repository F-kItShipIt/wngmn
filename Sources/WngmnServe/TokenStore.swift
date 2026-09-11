import Foundation

/// A LAN access token that survives restarts.
///
/// `AccessToken.generate()` per run is the safest thing and the most annoying: the URL
/// changes every session, so reading the transcript on a phone means re-copying 32
/// characters before every call. A short memorable token fixes the annoyance by removing
/// the protection — `?t=me` is one guess.
///
/// Persisting a generated token gets both. The URL is stable enough to bookmark once and
/// never think about again, and the token is still eight CSPRNG characters — about 40 bits,
/// which `AccessToken.generateReadable` explains is impractical to guess against a server on
/// your own wifi, and short enough to type on a phone.
public struct TokenStore: Sendable {
    public let directory: URL

    /// Defaults to Application Support rather than a dotfile in `$HOME`: it is machine
    /// state, not configuration a user is expected to edit.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSHomeDirectory())
            self.directory = base.appendingPathComponent("wngmn", isDirectory: true)
        }
    }

    public var url: URL { directory.appendingPathComponent("token") }

    /// The stored token, creating and persisting one on first use.
    public func loadOrCreate() throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if AccessToken.isPlausibleStoredToken(trimmed) { return trimmed }
        }
        return try write(AccessToken.generateReadable())
    }

    /// Replaces the stored token. Every bookmarked URL stops working, which is the point.
    @discardableResult
    public func rotate() throws -> String {
        try write(AccessToken.generateReadable())
    }

    private func write(_ token: String) throws -> String {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try token.write(to: url, atomically: true, encoding: .utf8)
        // Set after the write: `atomically` replaces the file, and with it any permissions
        // set beforehand, so doing this first would silently leave it world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
