import Foundation
import Synchronization

/// The shared origin every capture source measures its timestamps from.
///
/// With one source, "seconds since capture started" is unambiguous. With two it is not: the
/// tap and the microphone are separate devices with separate clock domains, and each would
/// otherwise start its own timeline at zero whenever it happened to receive its first
/// buffer. Questions from the two sides would then interleave in the wrong order, by
/// however far apart the devices started — and the tap's timeline additionally advances
/// artificially across a `capture_gap`, so the two would drift further apart the longer a
/// call ran.
///
/// Host time is a single system-wide monotonic clock shared by every device, so anchoring
/// both sources to the first host time *either* of them sees makes their emitted `t0`/`t1`
/// directly comparable without the devices sharing a clock.
public final class CaptureTimeline: Sendable {
    private let origin = Atomic<UInt64>(0)

    public init() {}

    /// Records the origin on first call and returns whatever the origin actually is.
    ///
    /// Idempotent and race-free: whichever source anchors first wins, and a later caller
    /// gets that value back rather than overwriting it. Returning the winner is what lets a
    /// caller compute its own offset against a timeline someone else started.
    @discardableResult
    public func anchor(_ hostTime: UInt64) -> UInt64 {
        guard hostTime != 0 else { return origin.load(ordering: .relaxed) }
        let (exchanged, original) = origin.compareExchange(
            expected: 0, desired: hostTime, ordering: .relaxed
        )
        return exchanged ? hostTime : original
    }

    /// Seconds from the shared origin, or nil before anything has anchored.
    public func seconds(forHostTime hostTime: UInt64) -> Double? {
        let origin = self.origin.load(ordering: .relaxed)
        guard origin != 0, hostTime != 0 else { return nil }
        let ticks = HostClock.delta(hostTime, minus: origin)
        return Double(HostClock.nanos(fromSignedTicks: ticks)) / 1_000_000_000
    }

    /// The origin, or zero when nothing has anchored yet.
    public var originHostTime: UInt64 { origin.load(ordering: .relaxed) }
}
