import Foundation

/// Tuning for the RMS voice-activity endpointer.
///
/// `hangoverMs` is the primary knob: it trades latency against false boundaries. Real
/// inter-word gaps in continuous speech are typically well under 200 ms, so 250 ms clears
/// them while still firing long before the framework's own `isFinal` would.
public struct EndpointerConfig: Sendable, Equatable {
    /// Analysis window. RMS is computed over non-overlapping windows of this length.
    public var windowMs: Double = 10
    /// Speech must stay above the open threshold this long before a question is considered started.
    public var onsetMs: Double = 80
    /// Silence must persist this long after speech before the endpoint fires.
    public var hangoverMs: Double = 250
    /// Utterances shorter than this are discarded as blips (mouse clicks, notification dings).
    public var minSpeechMs: Double = 350
    /// A monologue longer than this is force-endpointed so the wngmn never goes mute.
    public var maxSpeechMs: Double = 30_000
    /// Absolute floor for "this is speech", in dBFS.
    public var openThresholdDB: Double = -45
    /// The close threshold sits this far below the open threshold. Prevents chatter.
    public var hysteresisDB: Double = 6
    /// Speech must also exceed the tracked noise floor by this margin.
    public var noiseMarginDB: Double = 10
    /// Track the ambient noise floor during silence rather than trusting the absolute threshold alone.
    public var adaptNoiseFloor: Bool = true
    /// Ceiling on how far the noise floor may push the speech threshold above
    /// `openThresholdDB`.
    ///
    /// Without a ceiling the adaptation ratchets: sustained hold music at -30 dBFS is never
    /// loud enough to count as speech, so it feeds the floor, which raises the threshold,
    /// which lets still louder audio feed the floor. The detector ends up deaf to a
    /// journalist speaking at -25 dBFS — mid-interview, with no error anywhere. Twelve dB
    /// of adaptation covers a noisy room; beyond that the absolute threshold is the safer
    /// authority.
    public var maximumAdaptationDB: Double = 12
    /// Speech resuming within this long after an endpoint is treated as a continuation of
    /// the same question rather than as a new one.
    ///
    /// A journalist pausing mid-sentence to choose their words leaves a gap in the same
    /// range as a journalist who has finished — measured at 530 ms on the hesitation
    /// fixture, against 1.2 s between two real questions. No single silence threshold
    /// separates them, so raising `hangoverMs` far enough to cover hesitations (600 ms on
    /// that fixture) would spend the entire latency budget on the common case to protect
    /// the rare one. Instead the endpoint still fires fast, and the continuation is
    /// stitched back on when it arrives.
    public var mergeWindowMs: Double = 700

    public init() {}
}

/// A detected question boundary, in stream seconds.
public struct Endpoint: Sendable, Equatable {
    /// When speech began — the `t0` of the emitted question.
    public let speechStart: Double
    /// When the level dropped, i.e. the last speech audio — the `t1` of the emitted question.
    public let speechEnd: Double
    /// When the endpointer committed. This is what gets passed to `finalize(through:)`, so it
    /// deliberately includes the hangover silence: the recogniser transcribes trailing
    /// consonants better with a little silence after them.
    public let decisionTime: Double
    /// True when this fired from `maxSpeechMs` rather than from a real silence.
    public let forced: Bool
    /// True when speech resumed within `mergeWindowMs` of the previous endpoint, meaning
    /// this is the rest of a question that was already emitted rather than a new one.
    public let continuesPrevious: Bool
    /// Speech start of the first utterance in this chain. Equals `speechStart` unless this
    /// is a continuation, in which case it is the `t0` the joined question should carry.
    public let chainStart: Double

    public init(
        speechStart: Double, speechEnd: Double, decisionTime: Double, forced: Bool = false,
        continuesPrevious: Bool = false, chainStart: Double? = nil
    ) {
        self.speechStart = speechStart
        self.speechEnd = speechEnd
        self.decisionTime = decisionTime
        self.forced = forced
        self.continuesPrevious = continuesPrevious
        self.chainStart = chainStart ?? speechStart
    }
}

public enum EndpointerEvent: Sendable, Equatable {
    case speechStarted(at: Double)
    /// Speech ended but was too short to be a question; carried for instrumentation only.
    case discarded(speechStart: Double, speechEnd: Double)
    case endpoint(Endpoint)
}

/// Voice-activity endpointer running over raw tap frames, ahead of the recogniser.
///
/// Two properties matter more than accuracy:
///
/// 1. It must not fire mid-question. A false boundary is worse than a late one, because it
///    puts a half-question in front of the user while the journalist is still talking.
/// 2. It must fire even when the tap stops delivering buffers. The tap elides silence rather
///    than zero-filling it, so a pause in the conversation can look identical to a dead
///    capture graph. `idle(upTo:)` advances the same state machine from the host clock, which
///    means the hangover completes whether or not audio is still flowing.
public struct Endpointer: Sendable {
    public private(set) var config: EndpointerConfig

    private enum State: Equatable {
        case silence
        case onset(since: Double)
        case speech(start: Double)
        case hangover(start: Double, droppedAt: Double)
    }

    private var state: State = .silence
    private var noiseFloorDB: Double = -70

    /// End of the last emitted question, and the start of the chain it belongs to. Together
    /// they decide whether the next utterance continues it.
    private var lastEndpointSpeechEnd: Double?
    private var chainStart: Double?
    /// Whether the last boundary was forced by `maxSpeechMs` rather than by real silence.
    private var lastCloseWasForced = false

    /// End of the last window fed to the state machine, in stream seconds. `nil` until the
    /// first sample arrives, which is also what anchors the timeline.
    private var cursor: Double?

    // Partial-window accumulator. Tap buffers do not arrive in tidy 10 ms multiples.
    private var partialSumSquares: Double = 0
    private var partialCount: Int = 0
    private var partialStart: Double = 0
    private var windowSamples: Int = 0
    private var sampleRate: Double = 0

    /// Most recent window level, exposed for `--debug-vad`.
    public private(set) var lastLevelDB: Double = -120
    /// Current adaptive noise floor, exposed for `--debug-vad`.
    public var noiseFloor: Double { noiseFloorDB }
    public var inSpeech: Bool {
        if case .silence = state { return false }
        return true
    }

    public init(config: EndpointerConfig = EndpointerConfig()) {
        self.config = config
    }

    /// Feed captured frames. `startTime` is the stream-seconds timestamp of `samples[0]`,
    /// derived from the IOProc host time — never from an accumulated sample count.
    public mutating func push(
        _ samples: UnsafeBufferPointer<Float>,
        startTime: Double,
        sampleRate rate: Double,
        emit: (EndpointerEvent) -> Void
    ) {
        guard rate > 0 else { return }
        if sampleRate != rate {
            sampleRate = rate
            windowSamples = max(1, Int((config.windowMs / 1000) * rate))
            partialSumSquares = 0
            partialCount = 0
        }

        // A gap between the last window and this buffer is real elapsed silence, not
        // missing data: close the hangover across it before consuming new audio.
        advanceSilence(to: startTime, emit: emit)

        if cursor == nil { cursor = startTime }
        if partialCount == 0 { partialStart = startTime }

        let dt = 1.0 / rate
        var i = 0
        while i < samples.count {
            let take = min(windowSamples - partialCount, samples.count - i)
            var sum = partialSumSquares
            for j in i..<(i + take) {
                let v = Double(samples[j])
                sum += v * v
            }
            partialSumSquares = sum
            if partialCount == 0 { partialStart = startTime + Double(i) * dt }
            partialCount += take
            i += take

            if partialCount >= windowSamples {
                let level = dBFS(sumSquares: partialSumSquares, count: partialCount)
                let end = partialStart + Double(partialCount) * dt
                step(level: level, windowEnd: end, emit: emit)
                partialSumSquares = 0
                partialCount = 0
            }
        }
    }

    /// Advance the state machine through silence up to `streamTime` without any audio.
    ///
    /// Called on a timer whenever the ring buffer is empty. Without this, a tap that stalls
    /// during a quiet moment would freeze the hangover and the question would never be
    /// emitted — precisely at the moment the user needs it.
    public mutating func idle(upTo streamTime: Double, emit: (EndpointerEvent) -> Void) {
        guard cursor != nil else { return }
        advanceSilence(to: streamTime, emit: emit)
    }

    /// Force any in-flight utterance to close. Used on shutdown and on capture-graph rebuild.
    public mutating func flush(at streamTime: Double, emit: (EndpointerEvent) -> Void) {
        switch state {
        case .silence, .onset:
            state = .silence
        case let .speech(start):
            close(start: start, end: streamTime, decision: streamTime, forced: true, emit: emit)
        case let .hangover(start, droppedAt):
            close(start: start, end: droppedAt, decision: streamTime, forced: true, emit: emit)
        }
        lastEndpointSpeechEnd = nil
        chainStart = nil
        partialSumSquares = 0
        partialCount = 0
    }

    // MARK: - Internals

    /// Synthesise silence windows from the cursor up to `time`.
    private mutating func advanceSilence(to time: Double, emit: (EndpointerEvent) -> Void) {
        guard var c = cursor else { return }
        let window = config.windowMs / 1000
        // Nothing to do for the ordinary contiguous case.
        guard time > c + window else { return }

        // The partially filled window belongs to audio that predates the gap. Folding the
        // post-gap frames into it would place the window end before the cursor.
        partialSumSquares = 0
        partialCount = 0

        var guardCount = 0
        while c + window <= time {
            c += window
            step(level: -120, windowEnd: c, emit: emit)
            guardCount += 1
            // A very long stall (sleep/wake) must not spin: jump the cursor once the
            // hangover has certainly expired.
            if guardCount > 2000 {
                c = time
                break
            }
        }
        cursor = c
    }

    private mutating func step(level: Double, windowEnd: Double, emit: (EndpointerEvent) -> Void) {
        lastLevelDB = level
        cursor = windowEnd
        let window = config.windowMs / 1000
        let windowStart = windowEnd - window

        let openDB = config.adaptNoiseFloor
            ? min(
                max(config.openThresholdDB, noiseFloorDB + config.noiseMarginDB),
                config.openThresholdDB + config.maximumAdaptationDB
              )
            : config.openThresholdDB
        let closeDB = openDB - config.hysteresisDB

        switch state {
        case .silence:
            trackNoiseFloor(level)
            if level >= openDB { state = .onset(since: windowStart) }

        case let .onset(since):
            if level < closeDB {
                trackNoiseFloor(level)
                state = .silence
            } else if (windowEnd - since) * 1000 >= config.onsetMs {
                state = .speech(start: since)
                updateChain(speechStart: since)
                emit(.speechStarted(at: since))
            }

        case let .speech(start):
            if level < closeDB {
                state = .hangover(start: start, droppedAt: windowStart)
            } else if (windowEnd - start) * 1000 >= config.maxSpeechMs {
                close(start: start, end: windowEnd, decision: windowEnd, forced: true, emit: emit)
            }

        case let .hangover(start, droppedAt):
            if level >= openDB {
                // An inter-word gap, not the end of the question.
                state = .speech(start: start)
            } else if (windowEnd - droppedAt) * 1000 >= config.hangoverMs {
                close(start: start, end: droppedAt, decision: windowEnd, forced: false, emit: emit)
            }
        }
    }

    private mutating func close(
        start: Double, end: Double, decision: Double, forced: Bool,
        emit: (EndpointerEvent) -> Void
    ) {
        state = .silence
        guard (end - start) * 1000 >= config.minSpeechMs else {
            // A blip does not break a chain: a cough between two halves of a question
            // should not stop the second half from being stitched onto the first.
            emit(.discarded(speechStart: start, speechEnd: end))
            return
        }
        let chained = chainStart ?? start
        emit(.endpoint(Endpoint(
            speechStart: start, speechEnd: end, decisionTime: decision, forced: forced,
            continuesPrevious: chained != start, chainStart: chained
        )))
        lastEndpointSpeechEnd = end
        chainStart = chained
        lastCloseWasForced = forced
    }

    /// Decides whether an utterance starting at `speechStart` continues the previous
    /// question or begins a new one.
    private mutating func updateChain(speechStart: Double) {
        guard let previousEnd = lastEndpointSpeechEnd, let existing = chainStart else {
            chainStart = speechStart
            return
        }
        // A forced cut lands mid-speech, so the "gap" is zero and the chain would survive
        // the very split that was meant to bound it — the monologue limit would emit a
        // 30-second question, then a 60-second revision of it. A cut the machine made is not
        // a pause the speaker took, so there is no half-question on screen to revise.
        if lastCloseWasForced {
            chainStart = speechStart
            return
        }
        let gapMs = (speechStart - previousEnd) * 1000
        let spanMs = (speechStart - existing) * 1000
        // Bounded: a chain may not outgrow the monologue limit, or a long uninterrupted
        // answer would keep extending the same question forever.
        if gapMs <= config.mergeWindowMs, spanMs <= config.maxSpeechMs {
            return
        }
        chainStart = speechStart
    }

    /// Asymmetric tracker: falls quickly toward a quieter room, rises slowly so that a
    /// stray loud window cannot desensitise the detector.
    private mutating func trackNoiseFloor(_ level: Double) {
        guard config.adaptNoiseFloor, level.isFinite else { return }
        let alpha = level < noiseFloorDB ? 0.25 : 0.002
        noiseFloorDB += (level - noiseFloorDB) * alpha
        noiseFloorDB = min(max(noiseFloorDB, -100), -20)
    }

    private func dBFS(sumSquares: Double, count: Int) -> Double {
        guard count > 0 else { return -120 }
        let rms = (sumSquares / Double(count)).squareRoot()
        guard rms > 1e-9 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}

public extension Endpointer {
    /// Array-returning convenience used by tests and offline tooling.
    mutating func push(_ samples: [Float], startTime: Double, sampleRate: Double) -> [EndpointerEvent] {
        var out: [EndpointerEvent] = []
        samples.withUnsafeBufferPointer { buf in
            push(buf, startTime: startTime, sampleRate: sampleRate) { out.append($0) }
        }
        return out
    }

    mutating func idle(upTo streamTime: Double) -> [EndpointerEvent] {
        var out: [EndpointerEvent] = []
        idle(upTo: streamTime) { out.append($0) }
        return out
    }
}
