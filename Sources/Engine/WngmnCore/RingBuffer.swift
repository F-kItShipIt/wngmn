import Synchronization

/// Metadata for one contiguous run of frames delivered by a single IOProc callback.
///
/// The host time is carried alongside the audio because the tap **elides silence rather
/// than zero-filling it**: it stops delivering buffers entirely when nothing is rendering.
/// Any code that infers elapsed time from an accumulated sample count is therefore wrong.
/// All timing in this program derives from these stamps.
public struct AudioSegment: Sendable, Equatable {
    /// Mach absolute time of the first frame, straight from `AudioTimeStamp.mHostTime`.
    public let hostTime: UInt64
    /// Monotonic position of the first frame within the sample ring.
    public let startPosition: UInt64
    public let frameCount: Int

    public init(hostTime: UInt64, startPosition: UInt64, frameCount: Int) {
        self.hostTime = hostTime
        self.startPosition = startPosition
        self.frameCount = frameCount
    }
}

/// Lock-free single-producer / single-consumer ring buffer for Float32 audio.
///
/// The producer is a Core Audio IOProc running on a real-time thread. Real-time safety is a
/// correctness requirement, not an optimisation: allocating, locking or calling `write()` on
/// that thread stalls it when the consumer falls behind, and a stalled IOProc produces
/// **audible dropouts on the live call**. `write` therefore does nothing but two `memcpy`s
/// and three atomic stores — no allocation, no locks, no syscalls, no Swift runtime calls
/// that could allocate.
///
/// Overrun policy is drop-newest-and-count. Blocking is not an option on the audio thread,
/// and dropping is preferable to stalling: a dropped buffer costs a few milliseconds of
/// transcript, a stalled IOProc costs the call.
public final class AudioRingBuffer: @unchecked Sendable {
    private let samples: UnsafeMutablePointer<Float>
    private let sampleCapacity: Int
    private let sampleMask: UInt64

    private let segments: UnsafeMutablePointer<AudioSegment>
    private let segmentCapacity: Int
    private let segmentMask: UInt64

    private let writePosition = Atomic<UInt64>(0)
    private let readPosition = Atomic<UInt64>(0)
    private let segmentWrite = Atomic<UInt64>(0)
    private let segmentRead = Atomic<UInt64>(0)

    private let droppedFrames = Atomic<UInt64>(0)
    private let droppedSegments = Atomic<UInt64>(0)

    /// - Parameters:
    ///   - capacityFrames: rounded up to a power of two. At 48 kHz mono, 1 << 20 frames is
    ///     roughly 21 seconds of headroom — far more than the consumer should ever need, and
    ///     only 4 MB.
    ///   - maxSegments: rounded up to a power of two. One slot per IOProc callback in flight.
    public init(capacityFrames: Int = 1 << 20, maxSegments: Int = 1 << 12) {
        sampleCapacity = AudioRingBuffer.roundUpPowerOfTwo(max(capacityFrames, 1024))
        sampleMask = UInt64(sampleCapacity - 1)
        segmentCapacity = AudioRingBuffer.roundUpPowerOfTwo(max(maxSegments, 16))
        segmentMask = UInt64(segmentCapacity - 1)

        samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        samples.initialize(repeating: 0, count: sampleCapacity)
        segments = UnsafeMutablePointer<AudioSegment>.allocate(capacity: segmentCapacity)
        segments.initialize(
            repeating: AudioSegment(hostTime: 0, startPosition: 0, frameCount: 0),
            count: segmentCapacity
        )
    }

    deinit {
        samples.deinitialize(count: sampleCapacity)
        samples.deallocate()
        segments.deinitialize(count: segmentCapacity)
        segments.deallocate()
    }

    public var capacity: Int { sampleCapacity }
    public var framesDropped: UInt64 { droppedFrames.load(ordering: .relaxed) }
    public var segmentsDropped: UInt64 { droppedSegments.load(ordering: .relaxed) }

    /// Frames written but not yet consumed.
    public var count: Int {
        let w = writePosition.load(ordering: .relaxed)
        let r = readPosition.load(ordering: .relaxed)
        return Int(w &- r)
    }

    // MARK: - Producer (real-time thread)

    /// Copies `frameCount` frames into the ring. Returns false when the ring is full, in
    /// which case the frames are dropped and counted.
    ///
    /// Real-time safe. Must be called from exactly one thread.
    @inline(__always)
    public func write(_ source: UnsafePointer<Float>, frameCount: Int, hostTime: UInt64) -> Bool {
        guard frameCount > 0 else { return true }

        let w = writePosition.load(ordering: .relaxed)
        let r = readPosition.load(ordering: .acquiring)
        let free = sampleCapacity - Int(w &- r)
        guard frameCount <= free else {
            droppedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            return false
        }

        let sw = segmentWrite.load(ordering: .relaxed)
        let sr = segmentRead.load(ordering: .acquiring)
        guard Int(sw &- sr) < segmentCapacity else {
            droppedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            droppedSegments.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let offset = Int(w & sampleMask)
        let firstRun = min(frameCount, sampleCapacity - offset)
        (samples + offset).update(from: source, count: firstRun)
        if firstRun < frameCount {
            samples.update(from: source + firstRun, count: frameCount - firstRun)
        }

        segments[Int(sw & segmentMask)] = AudioSegment(
            hostTime: hostTime, startPosition: w, frameCount: frameCount
        )

        // Publish samples before the segment that describes them, and the segment before the
        // write position that makes space accounting visible.
        writePosition.store(w &+ UInt64(frameCount), ordering: .releasing)
        segmentWrite.store(sw &+ 1, ordering: .releasing)
        return true
    }

    // MARK: - Consumer

    /// Pops the next segment's metadata without consuming its samples.
    public func peekSegment() -> AudioSegment? {
        let sr = segmentRead.load(ordering: .relaxed)
        let sw = segmentWrite.load(ordering: .acquiring)
        guard sr != sw else { return nil }
        return segments[Int(sr & segmentMask)]
    }

    /// Consumes the next segment, copying its frames into `destination`.
    ///
    /// `destination` must have room for at least `segment.frameCount` frames; the required
    /// size is available from `peekSegment()` first. Returns nil when no segment is ready.
    @discardableResult
    public func readSegment(into destination: UnsafeMutablePointer<Float>, capacity: Int) -> AudioSegment? {
        let sr = segmentRead.load(ordering: .relaxed)
        let sw = segmentWrite.load(ordering: .acquiring)
        guard sr != sw else { return nil }

        let segment = segments[Int(sr & segmentMask)]
        guard segment.frameCount <= capacity else { return nil }

        let offset = Int(segment.startPosition & sampleMask)
        let firstRun = min(segment.frameCount, sampleCapacity - offset)
        destination.update(from: samples + offset, count: firstRun)
        if firstRun < segment.frameCount {
            (destination + firstRun).update(from: samples, count: segment.frameCount - firstRun)
        }

        segmentRead.store(sr &+ 1, ordering: .releasing)
        readPosition.store(segment.startPosition &+ UInt64(segment.frameCount), ordering: .releasing)
        return segment
    }

    private static func roundUpPowerOfTwo(_ n: Int) -> Int {
        var v = 1
        while v < n { v <<= 1 }
        return v
    }
}
