import Testing
import Foundation
@testable import WngmnCore

/// The ring buffer is the boundary between a Core Audio real-time thread and everything
/// else. Corruption here shows up as garbled transcript; blocking here shows up as audible
/// dropouts on the live call.
@Suite("AudioRingBuffer")
struct RingBufferTests {
    private func drain(_ ring: AudioRingBuffer) -> [(AudioSegment, [Float])] {
        var out: [(AudioSegment, [Float])] = []
        var scratch = [Float](repeating: 0, count: 8192)
        while let peek = ring.peekSegment() {
            if peek.frameCount > scratch.count { scratch = [Float](repeating: 0, count: peek.frameCount) }
            let segment: AudioSegment? = scratch.withUnsafeMutableBufferPointer {
                ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
            }
            guard let segment else { break }
            out.append((segment, Array(scratch[0..<segment.frameCount])))
        }
        return out
    }

    private func write(_ ring: AudioRingBuffer, _ values: [Float], hostTime: UInt64) -> Bool {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: $0.count, hostTime: hostTime) }
    }

    @Test("Samples and their host time survive a round trip")
    func roundTrip() {
        let ring = AudioRingBuffer(capacityFrames: 1024, maxSegments: 16)
        #expect(write(ring, [1, 2, 3, 4], hostTime: 111))
        #expect(write(ring, [5, 6], hostTime: 222))

        let got = drain(ring)
        #expect(got.count == 2)
        #expect(got[0].1 == [1, 2, 3, 4])
        #expect(got[0].0.hostTime == 111)
        #expect(got[1].1 == [5, 6])
        #expect(got[1].0.hostTime == 222)
        #expect(ring.count == 0)
    }

    @Test("Writes that wrap the end of the storage stay contiguous to the reader")
    func wrapAround() {
        let ring = AudioRingBuffer(capacityFrames: 1024, maxSegments: 64)
        var expected: [Float] = []
        var next: Float = 0
        // Three full laps of the storage in chunks that never divide evenly into it.
        for i in 0..<30 {
            let chunk = (0..<100).map { _ -> Float in next += 1; return next }
            #expect(write(ring, chunk, hostTime: UInt64(i)))
            expected += chunk
            for (_, samples) in drain(ring) {
                let head = Array(expected.prefix(samples.count))
                #expect(samples == head)
                expected.removeFirst(samples.count)
            }
        }
        #expect(expected.isEmpty)
    }

    @Test("An overrun drops the newest frames and counts them instead of blocking")
    func overrunDropsAndCounts() {
        let ring = AudioRingBuffer(capacityFrames: 1024, maxSegments: 16)
        #expect(write(ring, [Float](repeating: 1, count: 1024), hostTime: 1))
        // Full: the next write must be refused rather than overwriting unread audio.
        #expect(write(ring, [Float](repeating: 2, count: 8), hostTime: 2) == false)
        #expect(ring.framesDropped == 8)

        // Nothing already queued was corrupted by the refused write.
        let got = drain(ring)
        #expect(got.count == 1)
        #expect(got[0].1.allSatisfy { $0 == 1 })

        // And the ring recovers once space is available.
        #expect(write(ring, [9, 9], hostTime: 3))
        #expect(drain(ring).first?.1 == [9, 9])
    }

    @Test("Exhausting the segment ring is refused rather than overwriting metadata")
    func segmentOverrun() {
        let ring = AudioRingBuffer(capacityFrames: 1 << 16, maxSegments: 16)
        for i in 0..<16 { #expect(write(ring, [Float(i)], hostTime: UInt64(i))) }
        #expect(write(ring, [99], hostTime: 99) == false)
        #expect(ring.segmentsDropped == 1)
        #expect(drain(ring).count == 16)
    }

    @Test("Capacities are rounded up to a power of two")
    func capacityRounding() {
        #expect(AudioRingBuffer(capacityFrames: 1000).capacity == 1024)
        #expect(AudioRingBuffer(capacityFrames: 1 << 20).capacity == 1 << 20)
        // Below the floor, the minimum is used.
        #expect(AudioRingBuffer(capacityFrames: 1).capacity == 1024)
    }

    @Test("Concurrent producer and consumer never corrupt or reorder the stream", .timeLimit(.minutes(1)))
    func producerConsumerStress() async {
        let ring = AudioRingBuffer(capacityFrames: 1 << 14, maxSegments: 1 << 10)
        let totalFrames = 400_000

        // Every frame carries its own index, so any reordering, duplication or tearing is
        // detectable by the consumer without coordination.
        let producer = Task.detached(priority: .userInitiated) {
            var produced = 0
            var chunkSize = 31
            var hostTime: UInt64 = 0
            while produced < totalFrames {
                let n = min(chunkSize, totalFrames - produced)
                let chunk = (0..<n).map { Float(produced + $0) }
                let ok = chunk.withUnsafeBufferPointer {
                    ring.write($0.baseAddress!, frameCount: n, hostTime: hostTime)
                }
                if ok {
                    produced += n
                    hostTime &+= 1
                } else {
                    await Task.yield()
                    continue
                }
                chunkSize = chunkSize == 31 ? 512 : (chunkSize == 512 ? 137 : 31)
            }
            return produced
        }

        let consumer = Task.detached(priority: .userInitiated) {
            var expected: Float = 0
            var scratch = [Float](repeating: 0, count: 4096)
            var gaps = 0
            while Int(expected) < totalFrames {
                let segment: AudioSegment? = scratch.withUnsafeMutableBufferPointer {
                    ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
                }
                guard let segment else {
                    gaps += 1
                    await Task.yield()
                    continue
                }
                for i in 0..<segment.frameCount {
                    if scratch[i] != expected { return (false, expected, gaps) }
                    expected += 1
                }
            }
            return (true, expected, gaps)
        }

        let produced = await producer.value
        let (ordered, seen, _) = await consumer.value
        #expect(produced == totalFrames)
        #expect(ordered, "frames arrived out of order or torn")
        #expect(Int(seen) == totalFrames)
        // framesDropped is not asserted here: this producer retries after a refusal, and
        // each refusal counts. The real producer is an IOProc that never retries.
    }
}
