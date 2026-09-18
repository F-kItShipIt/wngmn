//  Core Audio host time -> CMTime / stream seconds.
//
//  Every number in this file was measured on this machine rather than assumed:
//  mach_timebase_info is 125/3, i.e. a 24 MHz host clock at 41.666…ns per tick, so
//  AudioTimeStamp.mHostTime is in TICKS, not nanoseconds — treating it as nanoseconds is
//  wrong by a factor of 24. Real IOProc timestamps (112 consecutive 512-frame callbacks at
//  48 kHz) showed exactly 256000 ticks between buffers with zero jitter, because host time
//  is derived from the device sample clock rather than sampled from mach_absolute_time.

import CoreAudio
import CoreMedia
import Darwin

// ==================================================================================
// MARK: - HostClock
// ==================================================================================

/// Core Audio host-time arithmetic.
///
/// `AudioTimeStamp.mHostTime` is documented in `<CoreAudioTypes/CoreAudioBaseTypes.h>`
/// as "The host machine's time base, mach_absolute_time." It is therefore in **mach
/// absolute time units (ticks)**, NOT nanoseconds. On Apple Silicon the timebase is
/// 125/3 (24 MHz), so treating `mHostTime` as nanoseconds is wrong by a factor of 24.
///
/// This clock does not advance while the machine is asleep; it is the same domain as
/// `CLOCK_UPTIME_RAW` and `SuspendingClock` (measured identical to within sampling
/// noise). It is *not* the same domain as `CLOCK_MONOTONIC_RAW` / `ContinuousClock`,
/// which have a different epoch and keep running through sleep. Never mix the two.
public enum HostClock {

    /// `mach_timebase_info` for this machine, read once.
    public static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Host ticks per second. Equals `AudioGetHostClockFrequency()`.
    public static let ticksPerSecond: Double =
        1.0e9 * Double(timebase.denom) / Double(timebase.numer)

    /// Current host time, in the same units and epoch as `AudioTimeStamp.mHostTime`.
    ///
    /// `AudioGetCurrentHostTime` is annotated `CA_REALTIME_API` (`[[clang::nonblocking]]`)
    /// and is safe to call from an IOProc. Measured identical to `mach_absolute_time()`.
    @inline(__always)
    public static func now() -> UInt64 { AudioGetCurrentHostTime() }

    /// Unsigned host ticks -> nanoseconds. Uses CoreAudio's 128-bit-intermediate
    /// implementation, so it does not overflow the way a naive `t * numer / denom` does.
    @inline(__always)
    public static func nanos(fromTicks ticks: UInt64) -> UInt64 {
        AudioConvertHostTimeToNanos(ticks)
    }

    /// Signed host ticks -> signed nanoseconds. Needed because
    /// `AudioConvertHostTimeToNanos` takes `UInt64` and a naive unsigned subtraction of
    /// two host times produces ~1.8e19 instead of a small negative number.
    @inline(__always)
    public static func nanos(fromSignedTicks ticks: Int64) -> Int64 {
        ticks >= 0
            ? Int64(bitPattern: AudioConvertHostTimeToNanos(UInt64(ticks)))
            : -Int64(bitPattern: AudioConvertHostTimeToNanos(UInt64(ticks.magnitude)))
    }

    /// Nanoseconds -> host ticks.
    ///
    /// Lossy on a 125/3 timebase: `ticks -> nanos -> ticks` can come back one tick low
    /// (~42 ns), measured. Do not use it in a round trip you need to be exact; keep
    /// canonical values in ticks.
    @inline(__always)
    public static func ticks(fromNanos ns: UInt64) -> UInt64 {
        AudioConvertNanosToHostTime(ns)
    }

    /// Signed difference `a - b` between two host times.
    /// Correct for `b > a` (yields a negative `Int64`), unlike bare `a - b` on `UInt64`.
    @inline(__always)
    public static func delta(_ a: UInt64, minus b: UInt64) -> Int64 {
        Int64(bitPattern: a &- b)
    }
}

extension AudioTimeStamp {
    /// The host time, or `nil` when the device did not mark it valid.
    /// Swift imports the flags as `AudioTimeStampFlags.hostTimeValid`, *not* as the C
    /// name `kAudioTimeStampHostTimeValid` (which does not exist in Swift).
    @inline(__always)
    public var validHostTime: UInt64? {
        mFlags.contains(.hostTimeValid) ? mHostTime : nil
    }
}

// ==================================================================================
// MARK: - MonotonicStopwatch
// ==================================================================================

/// Monotonic elapsed-time measurement for the JSON `ms` latency field.
///
/// Immune to wall-clock (NTP, user, timezone) changes: it is backed by
/// `mach_absolute_time` via `AudioGetCurrentHostTime`, i.e. exactly the clock domain of
/// `AudioTimeStamp.mHostTime`. Because the domains match, a stopwatch started from a
/// buffer's `mHostTime` measures true capture-to-emit latency with no cross-clock error.
///
/// Does not advance while the machine is asleep, which is the correct behaviour for
/// audio latency. If you ever need elapsed time that *includes* system sleep, use
/// `ContinuousClock` — but never subtract one clock's instant from the other's.
public struct MonotonicStopwatch: Sendable {
    public let startTicks: UInt64

    /// Start now.
    public init() { startTicks = HostClock.now() }

    /// Start from a Core Audio host time, e.g. a buffer's `mHostTime`.
    public init(sinceHostTime hostTime: UInt64) { startTicks = hostTime }

    /// Signed: negative when the reference host time is in the future
    /// (which is normal for an *output* IOProc timestamp).
    public var elapsedNanos: Int64 {
        HostClock.nanos(fromSignedTicks: HostClock.delta(HostClock.now(), minus: startTicks))
    }
    public var elapsedMillisecondsDouble: Double { Double(elapsedNanos) / 1_000_000.0 }
    /// Rounded, for an integer `ms` JSON field.
    public var elapsedMilliseconds: Int {
        let ns = elapsedNanos
        return Int(ns >= 0 ? (ns + 500_000) / 1_000_000 : (ns - 500_000) / 1_000_000)
    }
    public var elapsedSeconds: Double { Double(elapsedNanos) / 1_000_000_000.0 }
}

// ==================================================================================
// MARK: - AudioStreamClock
// ==================================================================================

/// Turns per-buffer Core Audio host times into a monotonic, sample-accurate stream
/// timeline anchored at the FIRST buffer.
///
/// **Why anchor on host time rather than count frames.** A process tap stops delivering
/// buffers entirely while the tapped process is silent, so an accumulated frame count
/// under-reports elapsed time. Host time is a real clock and survives the hole.
///
/// **Why not use host time alone for every buffer.** Host time can jitter, and a raw
/// host-derived start can go backwards or overlap by a sample. So inside a contiguous
/// run the timeline advances by exactly `frameCount` samples (integer math, provably
/// drift-free), and it *resyncs* to host time only when the two disagree by more than
/// `resyncToleranceSamples` — that is, when a real gap happened.
///
/// Measured on real `AudioDeviceIOProc` input timestamps (48 kHz, 512-frame buffers,
/// 112 consecutive callbacks): `mHostTime` deltas were exactly 256000 ticks every time,
/// zero jitter, and host-derived and count-derived sample indices never diverged by a
/// single sample. The tolerance exists for aggregate/tap devices and rate drift.
///
/// Not thread-safe; own it on one serial context (the tap callback, or an actor).
public struct AudioStreamClock {

    // ---- configuration ----
    public let sampleRate: Int32
    /// A disagreement larger than this forces a resync to host time (a detected gap).
    public let resyncToleranceSamples: Int64

    // ---- exact rational: host ticks -> samples ----
    private let tickNum: Int64
    private let tickDen: Int64

    // ---- state ----
    public private(set) var anchorHostTime: UInt64? = nil
    public private(set) var nextExpectedSample: Int64 = 0
    public private(set) var resyncCount: Int = 0

    /// - Parameters:
    ///   - sampleRate: stream rate, e.g. 48000. Also used as the `CMTime` timescale, so
    ///     every emitted `CMTime` is exact and never sets `.hasBeenRounded`.
    ///   - resyncToleranceMilliseconds: how far host time may disagree with the frame
    ///     count before a gap is declared. 30 ms comfortably exceeds IO jitter while
    ///     still catching any hole a listener would perceive.
    public init(sampleRate: Int32 = 48_000, resyncToleranceMilliseconds: Double = 30.0) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
        self.resyncToleranceSamples =
            max(1, Int64((resyncToleranceMilliseconds / 1000.0 * Double(sampleRate)).rounded()))
        // samples = ticks * (numer * sampleRate) / (denom * 1e9), reduced to lowest terms.
        // At 125/3 and 48 kHz this reduces to ticks / 500 — exact integer math.
        var n = Int64(HostClock.timebase.numer) * Int64(sampleRate)
        var d = Int64(HostClock.timebase.denom) * 1_000_000_000
        let g = AudioStreamClock.gcd(n, d)
        n /= g; d /= g
        self.tickNum = n
        self.tickDen = d
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    /// Exact host-tick delta -> sample delta. Integer math, round-half-away-from-zero.
    ///
    /// Always pass a delta *relative to the anchor*, never an absolute `mHostTime`:
    /// absolute host times are large enough that `ticks * tickNum` can overflow.
    @inline(__always)
    public func samples(fromTickDelta ticks: Int64) -> Int64 {
        let mag = ticks.magnitude
        let (prod, overflow) = mag.multipliedReportingOverflow(by: UInt64(tickNum))
        let q: UInt64 = overflow
            ? UInt64((Double(mag) * Double(tickNum) / Double(tickDen)).rounded())
            : (prod + UInt64(tickDen) / 2) / UInt64(tickDen)
        return ticks >= 0 ? Int64(q) : -Int64(q)
    }

    /// The result of admitting one buffer.
    public struct BufferTiming: Sendable {
        /// Sample-accurate start of this buffer on the stream timeline.
        public let startSample: Int64
        /// Hand this to `AnalyzerInput(buffer:bufferStartTime:)`.
        /// `value = startSample`, `timescale = sampleRate`, `epoch = 0`: exact, never rounded.
        public let startTime: CMTime
        /// Exclusive end of this buffer. Suitable as a `finalize(through:)` boundary.
        public let endTime: CMTime
        /// Monotonic seconds since the first buffer — the JSON `t` / `t0` / `t1` value.
        public let streamSeconds: Double
        /// True when host time disagreed with the frame count by more than the tolerance
        /// and the timeline jumped, i.e. the tap stalled.
        public let didResync: Bool
        /// Size of the jump in seconds when `didResync`, else 0.
        public let gapSeconds: Double
    }

    /// Admit one buffer. Call once per tap/IOProc callback, in delivery order.
    ///
    /// - Parameters:
    ///   - hostTime: `inInputTime.pointee.validHostTime`. Pass `nil` when the device did
    ///     not set `kAudioTimeStampHostTimeValid`; the clock then falls back to pure
    ///     frame counting (correct within a run, blind to gaps).
    ///   - frameCount: frames in this buffer.
    @discardableResult
    public mutating func admit(hostTime: UInt64?, frameCount: Int64) -> BufferTiming {
        // The first buffer defines the origin of the stream timeline.
        if anchorHostTime == nil {
            anchorHostTime = hostTime ?? HostClock.now()
            nextExpectedSample = 0
        }

        var start = nextExpectedSample
        var didResync = false
        var gapSeconds = 0.0

        if let ht = hostTime, let anchor = anchorHostTime {
            let hostSample = samples(fromTickDelta: HostClock.delta(ht, minus: anchor))
            let disagreement = hostSample - nextExpectedSample
            if disagreement.magnitude > UInt64(resyncToleranceSamples) {
                start = hostSample
                didResync = true
                gapSeconds = Double(disagreement) / Double(sampleRate)
                resyncCount += 1
            }
        }

        // Never let the timeline go backwards, whatever the hardware reports.
        if start < nextExpectedSample { start = nextExpectedSample }

        nextExpectedSample = start + frameCount

        return BufferTiming(
            startSample: start,
            startTime: CMTime(value: start, timescale: sampleRate),
            endTime: CMTime(value: start + frameCount, timescale: sampleRate),
            streamSeconds: Double(start) / Double(sampleRate),
            didResync: didResync,
            gapSeconds: gapSeconds
        )
    }

    /// Project any host time (e.g. "now") onto the stream timeline, in seconds.
    /// `nil` before the first buffer has been admitted.
    public func streamSeconds(forHostTime ht: UInt64) -> Double? {
        guard let anchor = anchorHostTime else { return nil }
        return Double(samples(fromTickDelta: HostClock.delta(ht, minus: anchor)))
             / Double(sampleRate)
    }

    /// Project any host time onto the stream timeline as a `CMTime` — e.g. to build a
    /// `finalize(through:)` boundary that does not fall on a buffer edge.
    /// `nil` before the first buffer has been admitted.
    public func cmTime(forHostTime ht: UInt64) -> CMTime? {
        guard let anchor = anchorHostTime else { return nil }
        return CMTime(value: samples(fromTickDelta: HostClock.delta(ht, minus: anchor)),
                      timescale: sampleRate)
    }

    /// The exclusive end of everything admitted so far — the safe default
    /// `finalize(through:)` boundary.
    public var currentEndTime: CMTime {
        CMTime(value: nextExpectedSample, timescale: sampleRate)
    }

    /// Stream seconds for an arbitrary `CMTime` on this timeline.
    /// Prefer this over `CMTimeGetSeconds` when you want exact rational division.
    public func seconds(_ t: CMTime) -> Double {
        t.timescale == sampleRate
            ? Double(t.value) / Double(sampleRate)
            : CMTimeGetSeconds(t)
    }
}
