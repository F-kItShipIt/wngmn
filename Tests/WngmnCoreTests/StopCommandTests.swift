import Testing
@testable import WngmnCore

@Suite("Stop command")
struct StopCommandTests {
    @Test("`stop` is a command like the others")
    func parsesCommand() throws {
        #expect(try Options.parse(["stop"]).command == .stop)
    }

    /// Killing the process that is doing the killing would leave the rest running and the
    /// user with no output explaining why.
    @Test("Its own process is never in the list")
    func excludesSelf() {
        let running = [(pid: Int32(100), name: "wngmn"), (pid: Int32(200), name: "wngmn")]
        #expect(RunningProcesses.stoppable(running, excluding: 100) == [200])
    }

    @Test("Only wngmn processes are selected")
    func onlyWngmn() {
        let running = [
            (pid: Int32(10), name: "wngmn"),
            (pid: Int32(11), name: "Wngmn"),
            (pid: Int32(12), name: "zsh"),
            (pid: Int32(13), name: "wngmnd"),
            (pid: Int32(14), name: "mywngmn"),
        ]
        // Matched exactly, case-sensitively: `wngmnd` and `mywngmn` are somebody
        // else's process, and killing a stranger's daemon is not a recoverable mistake.
        #expect(RunningProcesses.stoppable(running, excluding: 1) == [10])
    }

    @Test("Nothing running is not an error")
    func noneRunning() {
        #expect(RunningProcesses.stoppable([], excluding: 1).isEmpty)
        #expect(RunningProcesses.stoppable([(pid: Int32(5), name: "zsh")], excluding: 1).isEmpty)
    }
}
