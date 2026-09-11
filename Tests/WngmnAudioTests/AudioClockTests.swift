import Testing
import CoreMedia
@testable import WngmnAudio

/// Every latency number and every `finalize(through:)` boundary depends on this
/// arithmetic. These tests run with no audio permission and no device.
@Suite("AudioStreamClock")
struct AudioClockTests {
    /// Host ticks for `seconds`, on whatever timebase this machine actually has.
    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64((seconds * HostClock.ticksPerSecond).rounded())
    }

    @Test("The host timebase is read, never assumed")
    func timebase() {
        // Apple Silicon is 125/3; old Intel Macs were 1/1, which is where the
        // "mHostTime is nanoseconds" folklore comes from. Either must work.
        #expect(HostClock.timebase.numer > 0)
        #expect(HostClock.timebase.denom > 0)
        #expect(HostClock.ticksPerSecond > 0)
        let oneSecond = HostClock.nanos(fromTicks: UInt64(HostClock.ticksPerSecond))
        #expect(abs(Int64(oneSecond) - 1_000_000_000) < 1000)
    }

    @Test("A signed host-time difference does not wrap around")
    func signedDelta() {
        // Bare `a - b` on UInt64 yields ~1.8e19 when b > a, which would show up as an
        // absurd latency rather than as an obvious bug.
        #expect(HostClock.delta(100, minus: 200) == -100)
        #expect(HostClock.delta(200, minus: 100) == 100)
        #expect(HostClock.nanos(fromSignedTicks: -Int64(HostClock.ticksPerSecond)) < 0)
    }

    @Test("Contiguous buffers advance by exactly their frame count, with no drift")
    func contiguousBuffersDoNotDrift() {
        var clock = AudioStreamClock(sampleRate: 48_000)
        var host = UInt64(1_000_000)
        let framesPerBuffer: Int64 = 512
        let tickStep = UInt64((Double(framesPerBuffer) / 48_000 * HostClock.ticksPerSecond).rounded())

        var last = clock.admit(hostTime: host, frameCount: framesPerBuffer)
        #expect(last.startSample == 0)
        for i in 1..<20_000 {
            host &+= tickStep
            last = clock.admit(hostTime: host, frameCount: framesPerBuffer)
            #expect(last.startSample == Int64(i) * framesPerBuffer, "drifted at buffer \(i)")
            #expect(!last.didResync)
        }
        // Exact rational time: the CMTime must never have been rounded.
        #expect(!last.startTime.flags.contains(.hasBeenRounded))
        #expect(last.startTime.timescale == 48_000)
        #expect(clock.resyncCount == 0)
    }

    @Test("A stall is detected from host time and the timeline jumps across it")
    func stallResyncs() {
        // The premise the whole design rests on: when the tap stops delivering, elapsed
        // time cannot be inferred from a sample count. A five-second hole must appear as
        // five seconds, not as zero.
        var clock = AudioStreamClock(sampleRate: 48_000)
        var host = UInt64(5_000_000)
        let tickStep = UInt64((512.0 / 48_000 * HostClock.ticksPerSecond).rounded())

        for _ in 0..<10 {
            _ = clock.admit(hostTime: host, frameCount: 512)
            host &+= tickStep
        }
        host &+= Self.ticks(5.0)
        let after = clock.admit(hostTime: host, frameCount: 512)

        #expect(after.didResync)
        #expect(abs(after.gapSeconds - 5.0) < 0.02, "gap reported as \(after.gapSeconds)")
        #expect(abs(after.streamSeconds - (5.0 + 10 * 512.0 / 48_000)) < 0.02)
        #expect(clock.resyncCount == 1)
    }

    @Test("The timeline never runs backwards, whatever the hardware reports")
    func neverGoesBackwards() {
        var clock = AudioStreamClock(sampleRate: 48_000)
        let host = UInt64(9_000_000)
        _ = clock.admit(hostTime: host, frameCount: 4800)
        // A host time far in the past: a device that resets its clock must not rewind us.
        let out = clock.admit(hostTime: host &- Self.ticks(1.0), frameCount: 4800)
        #expect(out.startSample >= 4800)
        #expect(out.streamSeconds >= 0.1)
    }

    @Test("Falls back to frame counting when the device marks host time invalid")
    func missingHostTimeFallsBackToCounting() {
        var clock = AudioStreamClock(sampleRate: 48_000)
        _ = clock.admit(hostTime: nil, frameCount: 480)
        let second = clock.admit(hostTime: nil, frameCount: 480)
        #expect(second.startSample == 480)
        #expect(abs(second.streamSeconds - 0.01) < 1e-9)
        #expect(!second.didResync)
    }

    @Test("An arbitrary host time projects onto the same timeline")
    func projectsArbitraryHostTimes() {
        var clock = AudioStreamClock(sampleRate: 48_000)
        let host = UInt64(3_000_000)
        _ = clock.admit(hostTime: host, frameCount: 480)

        // The endpointer fires between buffers, so finalize(through:) needs a boundary
        // that does not fall on a buffer edge.
        let projected = try! #require(clock.streamSeconds(forHostTime: host &+ Self.ticks(0.25)))
        #expect(abs(projected - 0.25) < 1e-4)

        let t = try! #require(clock.cmTime(forHostTime: host &+ Self.ticks(0.25)))
        #expect(t.timescale == 48_000)
        #expect(abs(CMTimeGetSeconds(t) - 0.25) < 1e-4)
        #expect(clock.streamSeconds(forHostTime: host) == 0)
    }

    @Test("currentEndTime is the exclusive end of everything admitted")
    func currentEndTime() {
        var clock = AudioStreamClock(sampleRate: 48_000)
        _ = clock.admit(hostTime: 1_000, frameCount: 480)
        _ = clock.admit(hostTime: 1_000 &+ Self.ticks(0.01), frameCount: 480)
        #expect(clock.currentEndTime == CMTime(value: 960, timescale: 48_000))
    }

    @Test("The stopwatch measures capture-to-now without crossing clock domains")
    func stopwatch() {
        let watch = MonotonicStopwatch()
        #expect(watch.elapsedMilliseconds >= 0)
        // A reference in the future reads negative rather than as ~1.8e19.
        let future = MonotonicStopwatch(sinceHostTime: HostClock.now() &+ Self.ticks(1.0))
        #expect(future.elapsedMillisecondsDouble < 0)
    }
}
