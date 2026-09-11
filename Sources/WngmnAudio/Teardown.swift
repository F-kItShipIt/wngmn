import Dispatch
import Foundation
import Synchronization

/// Runs cleanup exactly once, from whichever path gets there first.
///
/// `atexit` is not enough on its own: measured, it does **not** run on SIGTERM (exit 143)
/// or SIGKILL (exit 137). For a program that creates a private aggregate device, that means
/// every Ctrl-C, every supervisor restart and every crash leaks one — and a private
/// aggregate is invisible to `system_profiler` by construction, so nobody notices.
///
/// The signal path uses `DispatchSourceSignal` rather than a `sigaction` handler because a
/// signal handler body must be async-signal-safe: no allocation, no locks, and certainly no
/// Core Audio. A dispatch source's handler runs on an ordinary GCD thread where real
/// teardown is legal.
public final class TeardownCoordinator: @unchecked Sendable {
    private let hasRun = Atomic<Bool>(false)
    private let work = Mutex<[@Sendable () -> Void]>([])
    private var sources: [DispatchSourceSignal] = []
    private let onSignal: @Sendable (Int32) -> Void

    public init(onSignal: @escaping @Sendable (Int32) -> Void = { _ in }) {
        self.onSignal = onSignal
    }

    /// Handlers run in reverse registration order, innermost resource first.
    public func onTeardown(_ block: @escaping @Sendable () -> Void) {
        work.withLock { $0.append(block) }
    }

    public func installSignalHandlers(_ signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]) {
        for sig in signals {
            // Required: the dispatch source only *observes* delivery, it does not change the
            // kernel disposition. Without this, SIGTERM still terminates the process (exit
            // 143) and the handler never runs.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.run()
                self?.onSignal(sig)
            }
            source.resume()
            // The source must be retained or it is cancelled immediately.
            sources.append(source)
        }
    }

    /// Idempotent.
    public func run() {
        guard !hasRun.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let blocks = work.withLock { blocks -> [@Sendable () -> Void] in
            let copy = blocks
            blocks.removeAll()
            return copy
        }
        for block in blocks.reversed() { block() }
    }
}
