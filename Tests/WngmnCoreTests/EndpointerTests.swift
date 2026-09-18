import Testing
import Foundation
@testable import WngmnCore

/// The endpointer decides when a question is over. A boundary that fires mid-sentence puts
/// half a question in front of the user while the journalist is still talking, so these
/// tests weight false positives far more heavily than a few milliseconds of latency.
@Suite("Endpointer")
struct EndpointerTests {
    private func makeEndpointer(_ mutate: (inout EndpointerConfig) -> Void = { _ in }) -> Endpointer {
        var config = EndpointerConfig()
        mutate(&config)
        return Endpointer(config: config)
    }

    @Test("A single utterance produces exactly one endpoint with correct bounds")
    func singleUtterance() {
        var e = makeEndpointer()
        var events = e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 2.0)

        let endpoints = events.endpoints
        #expect(endpoints.count == 1)
        let endpoint = try! #require(endpoints.first)
        #expect(abs(endpoint.speechStart - 0.0) < 0.02)
        #expect(abs(endpoint.speechEnd - 1.0) < 0.02)
        // The decision lands one hangover after speech stopped, not later.
        #expect(abs(endpoint.decisionTime - 1.25) < 0.02)
        #expect(endpoint.forced == false)
        #expect(events.starts.count == 1)
    }

    @Test("Inter-word gaps shorter than the hangover never split a question")
    func interWordGapsDoNotSplit() {
        // Six words with 200 ms gaps: the shape of ordinary continuous speech.
        var spans: [(Double, Double?)] = []
        for _ in 0..<6 {
            spans.append((0.35, -20))
            spans.append((0.20, nil))
        }
        var e = makeEndpointer()
        var events = e.push(TestSignal.envelope(spans), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 6.0)

        #expect(events.endpoints.count == 1)
        #expect(events.starts.count == 1)
    }

    @Test("The pattern that broke the volatile-stability design produces no false boundary")
    func burstCadenceProducesNoFalseBoundary() {
        // The rejected design fired on ~600 ms of quiet between volatile updates, which
        // arrive ~958-964 ms apart *during* continuous speech and produced 6 endpoints on a
        // 2-question clip. An RMS VAD sees the audio itself, so the same cadence must yield
        // exactly two boundaries.
        var spans: [(Double, Double?)] = []
        for _ in 0..<3 { spans.append((0.958, -20)); spans.append((0.05, nil)) }
        spans.append((0.9, nil))                    // real gap between questions
        for _ in 0..<3 { spans.append((0.958, -20)); spans.append((0.05, nil)) }

        var e = makeEndpointer()
        var events = e.push(TestSignal.envelope(spans), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 12.0)

        #expect(events.endpoints.count == 2)
    }

    @Test("A gap longer than the hangover splits two questions")
    func longGapSplits() {
        var e = makeEndpointer()
        var events = e.push(
            TestSignal.envelope([(1.0, -20), (0.8, nil), (1.0, -20)]),
            startTime: 0, sampleRate: TestSignal.rate
        )
        events += e.idle(upTo: 4.0)

        let endpoints = events.endpoints
        #expect(endpoints.count == 2)
        #expect(abs(endpoints[0].speechEnd - 1.0) < 0.02)
        #expect(abs(endpoints[1].speechStart - 1.8) < 0.03)
    }

    @Test("Short blips are discarded rather than emitted as questions")
    func blipsDiscarded() {
        var e = makeEndpointer()
        // 150 ms is long enough to trip onset but under the 350 ms minimum: a Slack ding.
        var events = e.push(TestSignal.frames(seconds: 0.15, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 1.0)

        #expect(events.endpoints.isEmpty)
        #expect(events.discards == 1)
    }

    @Test("The endpoint still fires when the tap stops delivering buffers")
    func endpointFiresWhenTapStalls() {
        // The tap elides silence rather than zero-filling it, so a quiet moment can deliver
        // zero buffers. If the hangover only advanced on incoming audio, the question would
        // never be emitted — exactly when the user needs it.
        var e = makeEndpointer()
        let events = e.push(TestSignal.frames(seconds: 0.8, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        #expect(events.endpoints.isEmpty, "no silence has been observed yet")

        let afterStall = e.idle(upTo: 1.4)
        #expect(afterStall.endpoints.count == 1)
        #expect(abs(afterStall.endpoints[0].speechEnd - 0.8) < 0.02)
    }

    @Test("Audio resuming after a stall is timed from its host stamp, not from sample counts")
    func resumeAfterStallUsesHostTime() {
        var e = makeEndpointer()
        var events = e.push(TestSignal.frames(seconds: 0.8, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        // Five seconds of wall clock pass with no buffers at all, then speech resumes.
        events += e.push(TestSignal.frames(seconds: 0.8, dB: -20), startTime: 5.8, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 7.5)

        let endpoints = events.endpoints
        #expect(endpoints.count == 2)
        #expect(abs(endpoints[0].speechEnd - 0.8) < 0.02)
        #expect(abs(endpoints[1].speechStart - 5.8) < 0.03)
        #expect(abs(endpoints[1].speechEnd - 6.6) < 0.03)
    }

    @Test("A monologue is force-endpointed so the wngmn never goes mute")
    func monologueForcesEndpoint() {
        var e = makeEndpointer { $0.maxSpeechMs = 2000 }
        let events = e.push(TestSignal.frames(seconds: 5.0, dB: -20), startTime: 0, sampleRate: TestSignal.rate)

        let endpoints = events.endpoints
        #expect(endpoints.count >= 2)
        #expect(endpoints[0].forced)
        #expect(abs(endpoints[0].decisionTime - 2.0) < 0.03)
    }

    @Test("Level below the open threshold is never treated as speech")
    func quietRoomToneIsNotSpeech() {
        var e = makeEndpointer()
        var events = e.push(TestSignal.frames(seconds: 3.0, dB: -60), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 4.0)

        #expect(events.isEmpty)
        #expect(e.inSpeech == false)
    }

    @Test("A loud room raises the effective threshold via the noise floor")
    func noiseFloorAdapts() {
        var e = makeEndpointer()
        // Thirty seconds of -30 dB hum: above the -45 dB absolute threshold, so a fixed
        // threshold alone would call it speech forever.
        _ = e.push(TestSignal.frames(seconds: 2.0, dB: -50), startTime: 0, sampleRate: TestSignal.rate)
        #expect(e.noiseFloor < -45)
    }

    /// The mic's audio is sometimes replaced with zeros (`EchoGate`). Learned as a quiet
    /// room, a quarter of a second of that drags the floor to −100, the raised threshold of a
    /// noisy room is gone, and the first thing back through the gate opens a detector it would
    /// not have opened before.
    @Test("A microphone's silenced stretches do not teach it that the room is quiet")
    func digitalSilenceIsNotARoom() {
        var noisy = makeEndpointer { $0.floorIgnoresDigitalSilence = true }
        _ = noisy.push(TestSignal.frames(seconds: 3.0, dB: -40), startTime: 0, sampleRate: TestSignal.rate)
        let learned = noisy.noiseFloor
        _ = noisy.push(TestSignal.silence(seconds: 2.0), startTime: 3.0, sampleRate: TestSignal.rate)
        #expect(abs(noisy.noiseFloor - learned) < 0.5)

        var tap = makeEndpointer()              // the tap's digital silence really is a quiet far end
        _ = tap.push(TestSignal.frames(seconds: 3.0, dB: -40), startTime: 0, sampleRate: TestSignal.rate)
        _ = tap.push(TestSignal.silence(seconds: 2.0), startTime: 3.0, sampleRate: TestSignal.rate)
        #expect(tap.noiseFloor < learned - 20)
    }

    @Test("Ragged buffer sizes produce the same boundaries as one contiguous push")
    func raggedBuffersMatchContiguous() {
        let audio = TestSignal.envelope([(0.9, -20), (0.6, nil), (0.9, -20)])

        var contiguous = makeEndpointer()
        var expected = contiguous.push(audio, startTime: 0, sampleRate: TestSignal.rate)
        expected += contiguous.idle(upTo: 4.0)

        var chunked = makeEndpointer()
        var actual: [EndpointerEvent] = []
        var offset = 0
        // Sizes deliberately coprime with the 480-frame window.
        let sizes = [512, 777, 333, 1024, 97]
        var k = 0
        while offset < audio.count {
            let n = min(sizes[k % sizes.count], audio.count - offset)
            let slice = Array(audio[offset..<(offset + n)])
            actual += chunked.push(slice, startTime: Double(offset) / TestSignal.rate, sampleRate: TestSignal.rate)
            offset += n
            k += 1
        }
        actual += chunked.idle(upTo: 4.0)

        #expect(actual.endpoints.count == expected.endpoints.count)
        for (a, b) in zip(actual.endpoints, expected.endpoints) {
            #expect(abs(a.speechStart - b.speechStart) < 0.03)
            #expect(abs(a.speechEnd - b.speechEnd) < 0.03)
        }
    }

    @Test("flush closes an in-flight utterance on shutdown")
    func flushClosesUtterance() {
        var e = makeEndpointer()
        _ = e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        var out: [EndpointerEvent] = []
        e.flush(at: 1.0) { out.append($0) }

        #expect(out.endpoints.count == 1)
        #expect(out.endpoints[0].forced)
        #expect(e.inSpeech == false)
    }

    @Test("The hangover is the primary latency knob and behaves linearly")
    func hangoverControlsLatency() {
        for hangover in [150.0, 250.0, 400.0] {
            var e = makeEndpointer { $0.hangoverMs = hangover }
            var events = e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
            events += e.idle(upTo: 3.0)
            let endpoint = try! #require(events.endpoints.first)
            #expect(abs((endpoint.decisionTime - endpoint.speechEnd) * 1000 - hangover) < 25)
        }
    }
}

/// Continuation chaining: no single silence threshold separates "pausing to think" from
/// "finished asking", so the endpoint fires fast and a resumed utterance is marked as the
/// rest of the same question.
@Suite("Endpointer chaining")
struct EndpointerChainingTests {
    private func run(gap: Double, merge: Double = 700) -> [Endpoint] {
        var config = EndpointerConfig()
        config.mergeWindowMs = merge
        var e = Endpointer(config: config)
        var events = e.push(
            TestSignal.envelope([(0.8, -20), (gap, nil), (0.8, -20)]),
            startTime: 0, sampleRate: TestSignal.rate
        )
        events += e.idle(upTo: 3.0 + gap)
        return events.endpoints
    }

    @Test("A gap inside the merge window marks the second utterance as a continuation")
    func shortGapChains() {
        let endpoints = run(gap: 0.5)
        #expect(endpoints.count == 2)
        #expect(endpoints[1].continuesPrevious)
        #expect(abs(endpoints[1].chainStart - endpoints[0].speechStart) < 0.02)
    }

    @Test("A gap beyond the merge window starts a new question")
    func longGapDoesNotChain() {
        let endpoints = run(gap: 1.2)
        #expect(endpoints.count == 2)
        #expect(endpoints[1].continuesPrevious == false)
        #expect(endpoints[1].chainStart == endpoints[1].speechStart)
    }

    @Test("A chain of three keeps pointing at the original start")
    func threeWayChain() {
        var e = Endpointer()
        var events = e.push(
            TestSignal.envelope([(0.8, -20), (0.5, nil), (0.8, -20), (0.5, nil), (0.8, -20)]),
            startTime: 0, sampleRate: TestSignal.rate
        )
        events += e.idle(upTo: 6.0)
        let endpoints = events.endpoints
        #expect(endpoints.count == 3)
        #expect(endpoints.dropFirst().allSatisfy { $0.continuesPrevious })
        #expect(endpoints.allSatisfy { abs($0.chainStart - endpoints[0].speechStart) < 0.02 })
    }

    @Test("A chain cannot outgrow the monologue limit")
    func chainIsBounded() {
        var config = EndpointerConfig()
        config.maxSpeechMs = 2000
        var e = Endpointer(config: config)
        var events: [EndpointerEvent] = []
        var t = 0.0
        // Six 0.8 s bursts separated by 0.5 s: well inside the merge window, well past the
        // 2 s bound.
        for _ in 0..<6 {
            events += e.push(TestSignal.frames(seconds: 0.8, dB: -20), startTime: t, sampleRate: TestSignal.rate)
            t += 0.8
            events += e.idle(upTo: t + 0.5)
            t += 0.5
        }
        events += e.idle(upTo: t + 1.0)
        let endpoints = events.endpoints
        #expect(endpoints.count == 6)
        #expect(endpoints.contains { !$0.continuesPrevious && $0.speechStart > 1.0 },
                "the chain must restart once it passes maxSpeechMs")
    }

    @Test("A discarded blip does not reset the chain bookkeeping")
    func blipDoesNotBreakChain() {
        // A notification ding between the two halves of a question must not make the second
        // half look like a new question. The merge window is measured from the end of the
        // last real utterance, so the blip is simply ignored — it neither extends the window
        // nor restarts it. Widened here so the blip plus the two hangovers it needs on
        // either side still fit inside the window being tested.
        var config = EndpointerConfig()
        config.mergeWindowMs = 1000
        var e = Endpointer(config: config)
        var events = e.push(
            TestSignal.envelope([(0.8, -20), (0.3, nil), (0.1, -20), (0.3, nil), (0.8, -20)]),
            startTime: 0, sampleRate: TestSignal.rate
        )
        events += e.idle(upTo: 4.0)
        let endpoints = events.endpoints
        #expect(events.discards == 1, "the 100 ms blip must be discarded, not emitted")
        #expect(endpoints.count == 2)
        guard endpoints.count == 2 else { return }
        #expect(endpoints[1].continuesPrevious)
        #expect(abs(endpoints[1].chainStart - endpoints[0].speechStart) < 0.02)
    }

    @Test("Elapsed time past the merge window breaks the chain even across a blip")
    func longGapAcrossBlipDoesNotChain() {
        // The counterpart: a blip does not keep a chain alive. If a full second passes
        // between the two halves, they are two questions regardless of what happened in
        // between — otherwise a Slack ding during a long pause would glue unrelated
        // questions together.
        var e = Endpointer()
        var events = e.push(
            TestSignal.envelope([(0.8, -20), (0.45, nil), (0.1, -20), (0.45, nil), (0.8, -20)]),
            startTime: 0, sampleRate: TestSignal.rate
        )
        events += e.idle(upTo: 4.0)
        let endpoints = events.endpoints
        #expect(endpoints.count == 2)
        #expect(endpoints[1].continuesPrevious == false)
    }
}

@Suite("Endpointer robustness")
struct EndpointerRobustnessTests {
    @Test("Sustained loud background never raises the threshold past hearing a speaker")
    func adaptationIsBounded() {
        // Hold music at -30 dBFS is below the speech threshold, so it feeds the noise floor
        // for as long as it plays. Unbounded, that ratchets the threshold up until the
        // journalist is inaudible to the detector — mid-interview, silently.
        var e = Endpointer()
        for i in 0..<60 {
            _ = e.push(TestSignal.frames(seconds: 1.0, dB: -50), startTime: Double(i), sampleRate: TestSignal.rate)
        }
        // A speaker at a normal level must still register afterwards.
        var events = e.push(TestSignal.frames(seconds: 1.0, dB: -25), startTime: 60, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 62.5)
        #expect(events.endpoints.count == 1, "the detector went deaf: \(events)")
    }

    @Test("A buffer whose timestamp goes backwards does not corrupt the timeline")
    func backwardsTimestampsAreIgnored() {
        var e = Endpointer()
        var events = e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 10, sampleRate: TestSignal.rate)
        // A device glitch, or a rebuild that re-anchored badly.
        events += e.push(TestSignal.frames(seconds: 0.5, dB: -20), startTime: 5, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 14)
        // Whatever it decides, it must terminate and produce sane bounds rather than looping
        // or emitting a negative-duration question.
        for endpoint in events.endpoints {
            #expect(endpoint.speechEnd >= endpoint.speechStart)
            #expect(endpoint.decisionTime >= endpoint.speechEnd)
        }
    }

    @Test("Empty and single-sample buffers are handled")
    func degenerateBuffers() {
        var e = Endpointer()
        #expect(e.push([], startTime: 0, sampleRate: TestSignal.rate).isEmpty)
        #expect(e.push([0.5], startTime: 0, sampleRate: TestSignal.rate).isEmpty)
        #expect(e.push([0.5], startTime: 0, sampleRate: 0).isEmpty, "a zero sample rate must not divide by zero")
    }

    @Test("Non-finite samples do not poison the level estimate")
    func nonFiniteSamples() {
        var e = Endpointer()
        var samples = TestSignal.frames(seconds: 0.5, dB: -20)
        samples[100] = .nan
        samples[200] = .infinity
        var events = e.push(samples, startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 3.0)
        // The requirement is that it stays sane and keeps working, not that it hears the
        // corrupted window.
        _ = events
        let recovered = e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 3.0, sampleRate: TestSignal.rate)
            + e.idle(upTo: 5.0)
        #expect(recovered.endpoints.count == 1, "the detector must recover after a bad buffer")
    }
}

@Suite("Forced split")
struct ForcedSplitTests {
    @Test("A monologue cut by maxSpeechMs is not stitched back together")
    func forcedSplitDoesNotChain() {
        // The cut lands mid-speech, so the "gap" is zero and an unguarded chain would
        // survive the very split meant to bound it: a 30 s question followed by a 60 s
        // revision of it, then 90 s, growing without limit.
        var config = EndpointerConfig()
        config.maxSpeechMs = 1000
        var e = Endpointer(config: config)
        var events = e.push(TestSignal.frames(seconds: 4.0, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 6.0)

        let endpoints = events.endpoints
        #expect(endpoints.count >= 3)
        #expect(endpoints[0].forced)
        // No segment after a forced cut may claim to continue the one before it.
        for endpoint in endpoints.dropFirst() where endpoints[0].forced {
            #expect(!endpoint.continuesPrevious, "a machine-made cut is not a pause the speaker took")
        }
    }

    @Test("A real pause after a forced cut still starts a fresh question")
    func realPauseAfterForcedCut() {
        var config = EndpointerConfig()
        config.maxSpeechMs = 1000
        var e = Endpointer(config: config)
        var events = e.push(TestSignal.frames(seconds: 2.5, dB: -20), startTime: 0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 4.0)
        events += e.push(TestSignal.frames(seconds: 1.0, dB: -20), startTime: 4.0, sampleRate: TestSignal.rate)
        events += e.idle(upTo: 6.0)
        #expect(events.endpoints.last?.continuesPrevious == false)
    }
}
