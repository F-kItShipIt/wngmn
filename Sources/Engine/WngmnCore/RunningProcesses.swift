#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Finding the other copies of wngmn that are still running.
///
/// A capture graph left behind holds the audio device and the port, so the next run either
/// fails to bind or quietly competes for the tap. `Ctrl-C` covers the common case; this
/// covers the ones that got away — a detached run, a session closed without stopping it, a
/// crash.
public enum RunningProcesses {
    /// Which of these should be signalled.
    ///
    /// Pure, so the matching rule can be asserted without spawning anything. Matched
    /// exactly and case-sensitively: `wngmnd` or `mywngmn` belongs to somebody else,
    /// and killing a stranger's daemon is not a recoverable mistake.
    public static func stoppable(
        _ running: [(pid: Int32, name: String)], excluding own: Int32
    ) -> [Int32] {
        running.filter { $0.name == "wngmn" && $0.pid != own }.map(\.pid)
    }

    /// Every process on the machine, as (pid, executable name).
    ///
    /// Read from the kernel rather than by spawning `ps`: this runs while tearing down
    /// audio, and shelling out to parse text is both slower and one more thing to get
    /// wrong. `p_comm` is truncated to 16 characters, which "wngmn" fits inside.
    public static func all() -> [(pid: Int32, name: String)] {
        #if canImport(Darwin)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, UInt32(name.count - 1), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        // The table can grow between sizing and reading, so ask for headroom rather than
        // silently truncating the list and missing the process we came to stop.
        size += size / 4
        let count = size / MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&name, UInt32(name.count - 1), &entries, &size, nil, 0) == 0 else {
            return []
        }

        let actual = size / MemoryLayout<kinfo_proc>.stride
        return entries.prefix(actual).map { entry in
            var proc = entry.kp_proc
            let command = withUnsafeBytes(of: &proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (pid: entry.kp_proc.p_pid, name: command)
        }
        #elseif os(Linux)
        // Linux has no sysctl for this; `/proc/<pid>/comm` is the same name, truncated to 15
        // characters as `p_comm` is to 16, which "wngmn" fits inside either way.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { entry in
            guard let pid = Int32(entry),
                  let comm = try? String(contentsOfFile: "/proc/\(entry)/comm", encoding: .utf8)
            else { return nil }
            return (pid: pid, name: comm.trimmingCharacters(in: .newlines))
        }
        #else
        return []
        #endif
    }
}
