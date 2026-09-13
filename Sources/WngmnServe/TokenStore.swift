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

    /// What this run should authenticate with, decided without writing anything.
    ///
    /// Rotation is the reason this is split from `commit`. The token has to exist before the
    /// server can be built, and the server can still fail to take its port; rotating during
    /// construction meant an occupied port destroyed the bookmarked token and exited, leaving
    /// the user with a dead bookmark and no URL to replace it. Deciding here and writing after
    /// the bind makes a failed start leave the machine exactly as it found it.
    public func plan(fixed: String?, rotate: Bool) throws -> TokenPlan {
        if let fixed { return .fixed(fixed) }
        if rotate { return .pendingRotation(AccessToken.generateReadable()) }
        return .stored(try loadOrCreate())
    }

    /// Writes a planned rotation down. Everything else has nothing to write.
    ///
    /// Returns whether the stored token actually changed, so the caller can say so only when
    /// it is true.
    @discardableResult
    public func commit(_ plan: TokenPlan) throws -> Bool {
        guard case let .pendingRotation(token) = plan else { return false }
        _ = try write(token)
        return true
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

/// The token a run will use, and whether anything still has to reach the disk.
public enum TokenPlan: Sendable, Equatable {
    /// Supplied with `--token`. The user owns it; we never write it down.
    case fixed(String)
    /// Loaded from disk, or created there on first use. Already persisted.
    case stored(String)
    /// Freshly generated for `--new-token`, deliberately not yet written.
    case pendingRotation(String)

    public var value: String {
        switch self {
        case let .fixed(t), let .stored(t), let .pendingRotation(t): t
        }
    }
}
