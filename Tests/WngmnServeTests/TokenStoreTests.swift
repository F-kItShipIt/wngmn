import Foundation
import Testing
@testable import WngmnServe

/// A token that survives restarts, so one bookmark keeps working without being guessable.
@Suite("Token store")
struct TokenStoreTests {
    func temporaryStore() -> TokenStore {
        TokenStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-token-\(UUID().uuidString)"))
    }

    @Test("A token is created on first use and written down")
    func createsOnFirstUse() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let token = try store.loadOrCreate()
        #expect(token.count == 8, "expected a typeable token, got \(token.count) characters")
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    /// The entire point: the URL bookmarked on a phone last week still opens this session.
    @Test("The same token comes back on every later run")
    func stableAcrossRuns() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(try store.loadOrCreate() == store.loadOrCreate())
    }

    @Test("Rotating replaces it and the new one persists")
    func rotates() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = try store.loadOrCreate()
        let second = try store.rotate()
        #expect(first != second)
        #expect(try store.loadOrCreate() == second)
    }

    /// It is a credential sitting in the user's home directory, not a preference.
    @Test("The file is readable only by its owner")
    func ownerOnlyPermissions() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try store.loadOrCreate()
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600, "got \(String(permissions.int16Value, radix: 8))")
    }

    /// A truncated or hand-edited file must not become a one-character token that happens to
    /// authenticate. Replaced rather than trusted.
    @Test("An empty or corrupt file is replaced rather than used")
    func replacesCorruptFile() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "  \n".write(to: store.url, atomically: true, encoding: .utf8)
        let token = try store.loadOrCreate()
        #expect(token.count == 8)
    }
}
