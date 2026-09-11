import Foundation
import Testing
@testable import WngmnCore

@Suite("Profile source", .serialized)
struct ProfileSourceTests {
    func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The point of the feature: edit the file mid-call, the next Ask uses it.
    @Test("An edited profile is picked up without a restart")
    func reloadsOnChange() throws {
        let url = try temporaryFile("## Style\nBe brief.")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ProfileSource(url: url, initial: try Profile.load(from: url))
        #expect(source.current().style == "Be brief.")

        // Modification dates have second granularity on some filesystems, so the timestamp
        // is moved explicitly rather than relying on the write to land in a later second.
        try "## Style\nBe expansive.".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        #expect(source.current().style == "Be expansive.")
    }

    /// An editor writing the file in two steps must not blank the profile mid-call.
    @Test("A profile that cannot be read keeps the last good one")
    func keepsLastGoodOnFailure() throws {
        let url = try temporaryFile("## Context\nA fact.")
        let source = ProfileSource(url: url, initial: try Profile.load(from: url))
        #expect(source.current().context == "A fact.")

        try FileManager.default.removeItem(at: url)
        #expect(source.current().context == "A fact.", "material was lost when the file vanished")
    }

    @Test("A fixed profile never touches the disk")
    func fixedProfile() {
        let source = ProfileSource(profile: Profile(text: "## Context\nStatic."))
        #expect(source.url == nil)
        #expect(source.current().context == "Static.")
    }
}
