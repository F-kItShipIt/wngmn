import Testing
@testable import WngmnAudio

/// The watchdog that decides whether a silent tap is a quiet room or a dead capture graph.
///
/// Regression suite for an observed failure: two multi-hour runs stalled with
/// `deviceAlive=true ioProcRegistered=true`, warned once, and then delivered nothing for
/// the rest of the session while the page kept showing a green "capturing" pill.
@Suite("Capture health")
struct CaptureHealthTests {
    let warnAfter = 90.0
    let rebuildAfter = 240.0

    let maximum = 3600.0

    func action(
        idle: Double, alive: Bool = true, registered: Bool = true, warned: Bool = false,
        rebuilds: Int = 0
    ) -> Pipeline.CaptureHealthAction {
        Pipeline.captureHealthAction(
            idleSeconds: idle, alive: alive, registered: registered,
            alreadyWarned: warned, consecutiveRebuilds: rebuilds,
            warnAfter: warnAfter, rebuildAfter: rebuildAfter, maximumInterval: maximum
        )
    }

    @Test("A tap delivering buffers is left alone")
    func healthyIsUntouched() {
        #expect(action(idle: 0) == .nothing)
        #expect(action(idle: 89) == .nothing)
    }

    @Test("A short silence warns once rather than repeating")
    func warnsOnce() {
        #expect(action(idle: 91) == .warn)
        #expect(action(idle: 120, warned: true) == .nothing)
    }

    /// The bug. A running IOProc delivers buffers *of* silence, so zero buffers for minutes
    /// is a stalled graph, not a quiet room — and it is exactly the state that previously
    /// escaped every rebuild trigger.
    @Test("A tap that is alive, registered and still silent is eventually rebuilt")
    func rebuildsTheHealthyLookingStall() {
        #expect(action(idle: 241, alive: true, registered: true) == .rebuild)
        #expect(
            action(idle: 4250, alive: true, registered: true, warned: true) == .rebuild,
            "the warn latch must not suppress escalation — this is the observed 4250 s stall"
        )
    }

    /// The existing behaviour, which was correct as far as it went.
    @Test("A dead device or unregistered IOProc rebuilds as soon as it is noticed")
    func rebuildsObviousBreakage() {
        #expect(action(idle: 91, alive: false) == .rebuild)
        #expect(action(idle: 91, registered: false) == .rebuild)
        #expect(action(idle: 91, alive: false, warned: true) == .rebuild)
    }

    /// Below the warn window nothing is wrong yet, however broken the probes look: the tap
    /// is legitimately silent whenever the tapped device is not clocking.
    @Test("Breakage below the warning window is not acted on")
    func quietWindowIsRespected() {
        #expect(action(idle: 10, alive: false, registered: false) == .nothing)
    }
}

/// Backoff for a graph that cannot be fixed by rebuilding it.
///
/// A rebuild tears down a capture graph that might have been about to recover, so retrying
/// every four minutes forever is its own failure mode when the cause is permanent —
/// permission revoked mid-session, an interface unplugged. It must keep trying, but not at
/// the same rate.
@Suite("Rebuild backoff")
struct RebuildBackoffTests {
    let base = 240.0
    let maximum = 3600.0

    func threshold(_ rebuilds: Int) -> Double {
        Pipeline.rebuildThreshold(base: base, consecutiveRebuilds: rebuilds, maximum: maximum)
    }

    @Test("The first rebuild happens at the base interval")
    func firstIsUnchanged() {
        #expect(threshold(0) == 240)
    }

    @Test("Each rebuild that changes nothing doubles the wait")
    func doubles() {
        #expect(threshold(1) == 480)
        #expect(threshold(2) == 960)
        #expect(threshold(3) == 1920)
    }

    /// Capped rather than unbounded: a session left running overnight should still be
    /// retrying in the morning, not waiting days.
    @Test("The wait is capped so retrying never stops entirely")
    func capped() {
        #expect(threshold(4) == 3600)
        #expect(threshold(50) == 3600, "a large count must not overflow or exceed the cap")
    }
}

extension CaptureHealthTests {
    /// The point of the backoff: after a rebuild that changed nothing, the same idle time
    /// that triggered the first rebuild must not immediately trigger another.
    @Test("A rebuild that changed nothing defers the next one")
    func backoffDefersTheNextRebuild() {
        #expect(action(idle: 241, warned: true, rebuilds: 1) == .nothing)
        #expect(action(idle: 481, warned: true, rebuilds: 1) == .rebuild)
    }

    /// Backoff applies to visibly broken graphs too, or a dead device would be rebuilt every
    /// 90 seconds for the rest of the session.
    @Test("A dead device is also backed off after a failed rebuild")
    func backoffAppliesToBrokenGraphs() {
        #expect(action(idle: 91, alive: false, warned: true, rebuilds: 1) == .nothing)
        #expect(action(idle: 181, alive: false, warned: true, rebuilds: 1) == .rebuild)
    }
}

/// What a rebuild that fails says about itself.
extension CaptureHealthTests {
    /// A failed rebuild is retried on the next watchdog window, so the process keeps
    /// running. The event contract says `error` means the binary is about to exit non-zero,
    /// and the page reads it that way — it showed "error" over a session still going.
    @Test("A failed rebuild is reported as a warning, not an error")
    func failedRebuildIsAWarning() {
        let event = Pipeline.rebuildFailedEvent(detail: "boom")
        #expect(event == .warning(code: "rebuild_failed", detail: "boom"))
    }
}

/// What asks for a rebuild in the first place.
extension CaptureHealthTests {
    /// A Bluetooth link dropping into duplex changes the clock device's *rate* without
    /// changing which device it is, so neither existing trigger fires. It needs its own.
    @Test("Every device-watcher change maps to a rebuild")
    func watcherChangesRebuild() {
        #expect(Pipeline.rebuildReason(for: .defaultOutputDeviceChanged) == .defaultOutputDeviceChanged)
        #expect(Pipeline.rebuildReason(for: .clockDeviceDied) == .clockDeviceDied)
        #expect(Pipeline.rebuildReason(for: .clockRateChanged) == .clockRateChanged)
    }
}
