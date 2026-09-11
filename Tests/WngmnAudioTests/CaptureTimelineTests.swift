import Testing
@testable import WngmnAudio

/// Two capture devices, one timeline. These assert the properties the interleaved
/// two-speaker transcript depends on.
@Suite("Capture timeline")
struct CaptureTimelineTests {
    @Test("Nothing is measurable before something anchors")
    func nilBeforeAnchor() {
        let timeline = CaptureTimeline()
        #expect(timeline.originHostTime == 0)
        #expect(timeline.seconds(forHostTime: 12345) == nil)
    }

    /// Whichever source receives its first buffer first defines the origin. The other must
    /// adopt it rather than overwrite it, or the two halves of the conversation would each
    /// start at zero and interleave in the wrong order.
    @Test("The first anchor wins and later callers are told the winner")
    func firstAnchorWins() {
        let timeline = CaptureTimeline()
        let first = timeline.anchor(1_000)
        let second = timeline.anchor(9_000)
        #expect(first == 1_000)
        #expect(second == 1_000, "a later source must adopt the existing origin")
        #expect(timeline.originHostTime == 1_000)
    }

    @Test("Seconds are measured from the shared origin")
    func measuresFromOrigin() throws {
        let timeline = CaptureTimeline()
        timeline.anchor(HostClock.now())
        let origin = timeline.originHostTime
        let oneSecondLater = origin &+ UInt64(HostClock.ticksPerSecond)
        let seconds = try #require(timeline.seconds(forHostTime: oneSecondLater))
        #expect(abs(seconds - 1.0) < 0.001)
    }

    /// A device that did not mark its host time valid reports zero. Anchoring on that would
    /// put the origin at the epoch and make every timestamp enormous.
    @Test("An invalid host time never becomes the origin")
    func zeroNeverAnchors() {
        let timeline = CaptureTimeline()
        #expect(timeline.anchor(0) == 0)
        #expect(timeline.originHostTime == 0)
        timeline.anchor(500)
        #expect(timeline.originHostTime == 500)
        #expect(timeline.seconds(forHostTime: 0) == nil)
    }
}
