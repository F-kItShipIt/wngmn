import Foundation

/// Holds the active profile and re-reads it when the file changes.
///
/// Lives in Core rather than beside the Claude client because both halves of the tool need
/// it: the answer path reads `## Style` and `## Context`, and the transcription path reads
/// `## Terms`. One watched file and one reload means the two can never disagree about which
/// version of the profile is in force.
///
/// Reloaded on modification date rather than at startup only: swapping domains otherwise
/// means restarting mid-call, and the moment you want to change how answers are shaped is
/// usually the moment you have just discovered the current shape is wrong. Checked when an
/// answer is requested rather than by a file watcher — an `Ask` happens a handful of times
/// a call, so a `stat` is cheaper and has nothing to leak or tear down.
public final class ProfileSource: @unchecked Sendable {
    private struct Loaded {
        var profile: Profile
        var modified: Date?
    }

    public let url: URL?
    /// Called when a reload happens. A closure rather than a direct `EventWriter` call:
    /// this module depends on WngmnCore only, and reversing that to reach the writer
    /// would put the transcript's output path behind the Claude client.
    private let onReload: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var loaded: Loaded

    /// A fixed profile that never reloads, for `--notes` and for tests.
    public init(profile: Profile) {
        url = nil
        onReload = nil
        loaded = Loaded(profile: profile, modified: nil)
    }

    public init(url: URL, initial: Profile, onReload: (@Sendable (String) -> Void)? = nil) {
        self.url = url
        self.onReload = onReload
        loaded = Loaded(profile: initial, modified: Self.modificationDate(of: url))
    }

    /// The current profile, re-reading the file first if it has changed.
    ///
    /// A read that fails keeps the profile already in memory: losing prepared material
    /// mid-call because the file was momentarily half-written by an editor would be worse
    /// than answering from a version a few seconds stale.
    public func current() -> Profile {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return loaded.profile }

        let modified = Self.modificationDate(of: url)
        guard modified != loaded.modified else { return loaded.profile }
        loaded.modified = modified
        guard let reloaded = try? Profile.load(from: url) else { return loaded.profile }

        loaded.profile = reloaded
        onReload?(url.lastPathComponent)
        return reloaded
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
