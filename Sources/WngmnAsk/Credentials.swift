import Foundation

/// How this machine authenticates to the Claude API.
///
/// Resolved in the same order the official SDKs use, so whichever way the user has already
/// set Claude up on this machine simply works: an exported API key, an OAuth token, or the
/// profile written by `ant auth login` — which is how a Claude subscription is reached from
/// a language with no SDK.
public enum Credentials: Sendable, Equatable {
    case apiKey(String)
    /// An OAuth access token. Different header *and* a beta flag — sending one as
    /// `x-api-key` fails with a 401 that reads like a bad key rather than a wrong scheme.
    case bearer(String)

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Credentials? {
        // An exported-but-empty variable is the usual shape of a half-written shell
        // profile. Treating it as a credential produces a 401 instead of the much more
        // useful "no credentials found".
        func value(_ key: String) -> String? {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            return raw
        }
        if let key = value("ANTHROPIC_API_KEY") { return .apiKey(key) }
        if let token = value("ANTHROPIC_AUTH_TOKEN") { return .bearer(token) }
        return nil
    }

    /// Resolve, falling back to the `ant` CLI's active OAuth profile.
    ///
    /// Shelling out is how a language with no SDK reaches a subscription login. Kept out of
    /// `resolve` so the pure resolution order stays testable without a process launch.
    public static func resolveIncludingCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Credentials? {
        if let found = resolve(environment: environment) { return found }
        guard let token = antAccessToken(), !token.isEmpty else { return nil }
        return .bearer(token)
    }

    private static func antAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `--access-token` prints the bare token; without it the CLI prints JSON.
        process.arguments = ["ant", "auth", "print-credentials", "--access-token"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Auth headers, including the beta flag an OAuth token requires.
    public func headers() -> [String: String] {
        switch self {
        case let .apiKey(key):
            return ["x-api-key": key]
        case let .bearer(token):
            return ["authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]
        }
    }

    public var describedSource: String {
        switch self {
        case .apiKey: "ANTHROPIC_API_KEY"
        case .bearer: "OAuth token (ANTHROPIC_AUTH_TOKEN or `ant auth login`)"
        }
    }
}
