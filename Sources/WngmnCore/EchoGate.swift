import Foundation
import Synchronization

/// How loud a buffer is, in dBFS. −120 for digital silence, as the endpointer reports it.
public enum AudioLevel {
    public static func decibels(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 1e-9 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}

/// What the far end — the other side of the call — was doing, and when.
///
/// Written by the tap, read by the microphone, on the timeline the two already share. A class
/// behind a lock rather than a message between actors, because the mic asks a hundred times a
/// second about a stretch of time that ended milliseconds ago, and an `await` into the tap's
/// actor would queue that question behind the recogniser.
public final class FarEndActivity: Sendable {
    public struct Span: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var levelDB: Double
    }

    private struct State {
        var spans: [Span] = []
        var knownThrough = -Double.infinity
    }

    /// How far back it can be asked about: the gate's longest lag and its tail, and room for
    /// a stall.
    public static let retainedSeconds = 5.0

    private let state = Mutex(State())

    public init() {}

    /// The tap delivered this stretch of audio, at this level.
    public func record(start: Double, end: Double, levelDB: Double) {
        state.withLock { state in
            state.spans.append(Span(start: start, end: end, levelDB: levelDB))
            state.knownThrough = max(state.knownThrough, end)
            let horizon = state.knownThrough - Self.retainedSeconds
            // Trimmed a second at a time, not on every append: this runs a hundred times a
            // second for hours, and removing from the front of an array is a copy.
            if let first = state.spans.first, first.end < horizon - 1 {
                state.spans.removeAll { $0.end < horizon }
            }
        }
    }

    /// The tap delivered nothing up to here. A tap with nothing to say says nothing at all —
    /// it does not deliver buffers of zeros — so silence has to be reported as the absence it
    /// is, or a mic waiting to hear about this stretch of time would wait for ever.
    public func advance(through time: Double) {
        state.withLock { $0.knownThrough = max($0.knownThrough, time) }
    }

    /// The latest time the tap has reported on, by sound or by silence.
    public var knownThrough: Double { state.withLock { $0.knownThrough } }

    /// The loudest the far end was in a stretch of time: −120 where the tap reported silence,
    /// and nil where it has not reported at all. The two are not the same thing — a mic that
    /// took "not heard from yet" for "quiet" would learn the caller's echo as its own room.
    public func loudest(from: Double, to: Double) -> Double? {
        state.withLock { state in
            guard from < state.knownThrough else { return nil }
            return Self.loudest(in: state.spans, from: from, to: to)
        }
    }

    /// What is retained from a time onwards, oldest first, for a caller with many questions
    /// to ask about one stretch.
    public func snapshot(from: Double) -> [Span] {
        state.withLock { state in
            var low = 0, high = state.spans.count
            while low < high {
                let middle = (low + high) / 2
                if state.spans[middle].end <= from { low = middle + 1 } else { high = middle }
            }
            return Array(state.spans[max(low - 2, 0)...])
        }
    }

    /// The loudest span overlapping a stretch, or −120. `spans` is in the order it was
    /// recorded, which is the order of time — searched rather than walked, because the fit
    /// asks this of every buffer it remembers at every lag it tries.
    static func loudest(in spans: [Span], from: Double, to: Double) -> Double {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].end <= from { low = middle + 1 } else { high = middle }
        }
        var loudest = -120.0
        // Two back, because host times jitter and the ends need not be strictly in order.
        var index = max(low - 2, 0)
        while index < spans.count, spans[index].start < to {
            if spans[index].end > from { loudest = max(loudest, spans[index].levelDB) }
            index += 1
        }
        return loudest
    }

    var retainedCount: Int { state.withLock { $0.spans.count } }
}

/// Whether the microphone is, right now, only hearing the call.
///
/// With the call coming out of a speaker, the microphone hears the caller as well as you.
/// Measured on a MacBook Pro at volume 81: the built-in mic heard the built-in speakers at
/// −17.8 dBFS over a −56.1 dBFS room — as loud as a voice at arm's length — and every
/// sentence the caller spoke arrived twice, once from the tap as Caller and once from the mic
/// as You, 32 ms apart and word for word. A pair of Bluetooth earbuds did the same to their
/// own microphone: −21.8 dBFS over a −54 dBFS room.
///
/// The tap already has the caller's half, clean. So while the far end's echo is loud enough
/// to be taken for speech, the mic's audio is replaced with silence before its speech
/// detector or its recogniser hears it. That is half-duplex, not echo cancellation: what you
/// say *while they are talking* is lost with the echo. Cancelling instead would mean an
/// adaptive filter of our own, or Apple's voice-processing unit, which ducks the call's
/// volume and is already in use by the call app.
///
/// On headphones there is no echo and nothing should be lost, and the gate cannot see the
/// route: a device's name is a guess, a headphone jack can feed desk speakers, and earbuds
/// can leak. So it measures the one thing an echo is and your voice is not — **a copy**. An
/// echo is the far end again, a fixed time later and a fixed number of decibels down, so the
/// mic's level rises and falls with the far end's, syllable for syllable; your voice over
/// theirs does not. The first version of this asked only whether the mic was *raised* while
/// the far end was loud, and an interviewer saying "mm-hm" through your answer was enough to
/// convince it, on headphones, that you were an echo.
public struct EchoGate: Sendable {
    public struct Config: Sendable {
        /// Far-end sound this loud is evidence about the route; quieter is left out, because
        /// its echo may not clear the room even on speakers and says nothing either way.
        public var evidenceDB = -35.0
        /// The lags tried, in seconds. Built-in speakers measured 32 ms; a Bluetooth speaker
        /// is a few hundred. Never negative: both captures are stamped by the host clock,
        /// and an echo does not arrive before the sound it echoes.
        public var lags: [Double] = Array(stride(from: 0.0, through: 0.501, by: 0.02))
        /// How much evidence each lag's fit looks back over — seconds *of loud far end* at
        /// that lag, not of clock. An interviewer who only says "mm-hm" every few seconds
        /// gives a third of a second of evidence at a time; counted by the clock it never
        /// adds up, and the doubt — and the gate, which is closed for the length of it —
        /// would last the whole answer.
        public var memorySeconds = 5.0
        /// Evidence older than this is about some other arrangement of the room.
        public var staleSeconds = 120.0
        /// How much evidence every lag must have before anything is concluded. Every lag, not
        /// the best: the long lags fill last, and a verdict drawn before they have is a
        /// verdict that a Bluetooth speaker a quarter of a second late has no echo.
        public var fitNeedsSeconds = 2.0
        public var refitEverySeconds = 0.25
        /// How closely the mic's level must follow the far end's, buffer by buffer, to count
        /// as a copy of it: Pearson's r over the loud buffers. Built-in speakers into the
        /// built-in mic measured 0.74 to 0.82; two recorded voices talking over each other
        /// never passed 0.54. Set nearer the echo than the voices, because missing an echo
        /// leaves things as they were and inventing one silences someone on headphones.
        public var minLikeness = 0.65
        /// The loudest a far end gets. An echo matters if *this* could open the mic through
        /// it — a property of the route, whoever happens to be talking.
        public var loudestFarEndDB = -6.0
        /// A mic this far *under* what the echo should be says the path has gone: an echo is a
        /// floor under the mic's level, so it can be louder than predicted but never quieter.
        public var refuteBelowDB = 10.0
        /// Seconds of evidence, like `memorySeconds`. Also the window a changed gain is read
        /// from: the speakers turned down mid-call are still an echo, only a quieter one.
        public var refuteWindowSeconds = 2.0
        /// The share of loud-far-end time at the bottom of the mic's range that the floor is
        /// read from. An echo is a floor: on speakers the mic never sits far under the far end,
        /// and on headphones it does whenever you draw breath.
        public var floorQuantile = 0.1
        /// How long the room goes on sounding after the far end stops.
        public var tailSeconds = 0.2
        /// Before the route is known, the gate closes for a loud far end and stays closed this
        /// long after it: the longest lag tried, and the room.
        public var coldReleaseSeconds = 0.7
        /// The mic's own speech detector. An echo is removed where it could be taken for
        /// speech: where, through the route's gain, the far end would reach the level that
        /// opens the detector.
        public var micOpenDB = -35.0
        public var headroomDB = 3.0
        /// Quieter than any room a microphone is in: the built-in mic's measured −56, and a
        /// studio's −70. Below it is a muted or stopped device, and a mic that has gone dead
        /// under a loud far end is not a mic the call no longer reaches.
        public var deadMicDB = -80.0

        public init() {}
    }

    public enum Verdict: String, Sendable, Equatable {
        /// Not enough far-end sound yet. Treated as speakers, but only for a far end loud
        /// enough to be evidence — so whatever closes the gate is also what ends the doubt.
        case undecided
        case hearsTheSpeakers
        case doesNot
    }

    /// What is known about the way from the speaker to the microphone.
    enum Path: Sendable, Equatable {
        case unknown
        case none
        case echo(lag: Double, gainDB: Double)
    }

    public var verdict: Verdict {
        switch path {
        case .unknown: .undecided
        case .none: .doesNot
        case .echo: .hearsTheSpeakers
        }
    }

    private(set) var path = Path.unknown

    /// One buffer of evidence: the mic's level, and the far end's at each lag tried. Paired
    /// when the buffer arrives, because the far end's record is short and the evidence for a
    /// slow trickle of "mm-hm"s has to outlive it.
    private struct Heard {
        var start: Double
        var end: Double
        var micDB: Double
        var theirs: [Double]
    }

    private let config: Config
    private var history: [Heard] = []
    private var lastFit = -Double.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Whether this stretch of microphone audio should be replaced with silence.
    ///
    /// - Parameter micDB: the level of the audio as captured, before any silencing.
    public mutating func shouldSilence(
        start: Double, end: Double, micDB: Double, farEnd: FarEndActivity
    ) -> Bool {
        remember(start: start, end: end, micDB: micDB, farEnd: farEnd)
        if end - lastFit >= config.refitEverySeconds, evidenceHasGrown {
            lastFit = end
            evidenceHasGrown = false
            refit(now: end)
        }

        switch path {
        case .none:
            return false
        case .unknown:
            let recent = farEnd.loudest(from: start - config.coldReleaseSeconds, to: end) ?? -120
            return recent >= config.evidenceDB
        case let .echo(lag, gainDB):
            // From when the far end's sound left to when the room stops repeating it. The lag
            // only ever widens this: gating from the moment they speak, rather than from the
            // moment the echo lands, costs nothing the echo was not about to cost anyway.
            let theirs = farEnd.loudest(
                from: start - max(lag, 0) - config.tailSeconds, to: end - min(lag, 0)) ?? -120
            // Against the level that *opens* the detector, not the lower one that holds it: a
            // far end whose echo can only ever murmur — a fan behind them, hold music turned
            // down — is not worth a word of yours, and held to the lower level it closed the
            // mic for the whole call.
            return theirs + gainDB >= config.micOpenDB - config.headroomDB
        }
    }

    private var evidenceHasGrown = false

    private mutating func remember(start: Double, end: Double, micDB: Double, farEnd: FarEndActivity) {
        // A muted or stopped device, not a level: a hardware mute would otherwise read as a mic
        // the far end does not reach.
        guard micDB > config.deadMicDB else { return }
        let spans = farEnd.snapshot(from: start - (config.lags.max() ?? 0) - 0.05)
        let theirs = config.lags.map { FarEndActivity.loudest(in: spans, from: start - $0, to: end - $0) }
        guard theirs.contains(where: { $0 >= config.evidenceDB }) else { return }
        history.append(Heard(start: start, end: end, micDB: micDB, theirs: theirs))
        evidenceHasGrown = true
    }

    /// Drops what no fit will read again: each lag keeps its newest `memorySeconds`, nothing
    /// is kept past staleness, and never more than three memories' worth in all.
    private mutating func forget(now: Double) {
        var perLag = [Double](repeating: 0, count: config.lags.count)
        var kept = 0.0, firstKept = history.count
        for index in history.indices.reversed() {
            let heard = history[index]
            guard perLag.min() ?? 0 < config.memorySeconds, kept < 3 * config.memorySeconds,
                  heard.end >= now - config.staleSeconds else { break }
            let seconds = heard.end - heard.start
            kept += seconds
            for at in perLag.indices where heard.theirs[at] >= config.evidenceDB { perLag[at] += seconds }
            firstKept = index
        }
        if firstKept > 64 { history.removeFirst(firstKept) }
    }

    // MARK: - One buffer

    public enum Announcement: Sendable, Equatable {
        case hearsTheCall
        case noLongerHearsTheCall
    }

    public struct Step: Sendable, Equatable {
        /// The buffer's level as captured, before any silencing.
        public let micDB: Double
        public let silenced: Bool
        /// Set when what is known about the route has changed in a way worth telling. Going
        /// from undecided to "does not hear the call" is not: that is what was assumed.
        public let announcement: Announcement?
    }

    /// Everything that happens to one buffer of microphone audio, in the only order that
    /// works: measured, judged, silenced, *then* shown to the speech detector. The caller
    /// feeds the same buffer to the recogniser afterwards. Silencing only the detector's copy
    /// would stop the echo becoming a line of its own and leave its words in the recogniser,
    /// to come out attached to the next thing you really said.
    ///
    /// Here rather than in `MicSource` so that the order can be tested without a microphone.
    /// A nil `farEnd` is the gate turned off.
    public mutating func process(
        _ buffer: UnsafeMutableBufferPointer<Float>, start: Double, sampleRate: Double,
        farEnd: FarEndActivity?, endpointer: inout Endpointer, emit: (EndpointerEvent) -> Void
    ) -> Step {
        let micDB = AudioLevel.decibels(UnsafeBufferPointer(buffer))
        let before = verdict
        var silenced = false
        if let farEnd {
            silenced = shouldSilence(
                start: start, end: start + Double(buffer.count) / sampleRate, micDB: micDB, farEnd: farEnd)
        }
        if silenced { buffer.update(repeating: 0) }
        endpointer.push(UnsafeBufferPointer(buffer), startTime: start, sampleRate: sampleRate, emit: emit)

        var announcement: Announcement?
        if verdict != before {
            if verdict == .hearsTheSpeakers { announcement = .hearsTheCall }
            if before == .hearsTheSpeakers { announcement = .noLongerHearsTheCall }
        }
        return Step(micDB: micDB, silenced: silenced, announcement: announcement)
    }

    // MARK: - The fit

    public struct Fit: Sendable, Equatable {
        public var lag: Double
        /// How closely the mic's level follows the far end's, buffer by buffer: Pearson's r.
        public var likeness: Double
        /// How far below the far end the mic sits: the median of (mic − far end).
        public var gainDB: Double
        /// How far below it the mic gets at its quietest: the low quantile of the same.
        public var floorDB: Double
    }

    /// The last fit made, whatever came of it. For tests, and for `--debug-vad`.
    public private(set) var lastFitMade: Fit?

    private mutating func refit(now: Double) {
        forget(now: now)
        guard let fit = bestFit(seconds: config.memorySeconds) else { return }
        lastFitMade = fit

        if fit.likeness >= config.minLikeness {
            path = route(from: fit)
            return
        }

        // Not a copy: you were talking over them, or the two are unrelated.
        switch path {
        case .unknown:
            // Doubt ends only on the evidence that settles it: moments when the far end was
            // loud and the mic sat quietly under it, which an echo — a floor under the mic —
            // does not allow. A call that opens with both sides talking at once is not that,
            // and ruled "no echo" there, it doubled the caller's next sentences on speakers.
            if config.loudestFarEndDB + fit.floorDB < config.micOpenDB - config.headroomDB { path = .none }
        case .none:
            break
        case let .echo(lag, gainDB):
            // No reason to forget an echo because you talked over it. A copy in the newest
            // evidence alone is the same echo at a new volume: the speakers turned down.
            if let recent = bestFit(seconds: config.refuteWindowSeconds), recent.likeness >= config.minLikeness {
                path = route(from: recent)
                return
            }
            // Otherwise it is forgotten only if the mic has gone quiet under it.
            guard let at = config.lags.firstIndex(of: lag) else { return }
            var judged = 0.0, under = 0.0
            for heard in history.reversed() where heard.theirs[at] >= config.evidenceDB {
                guard judged < config.refuteWindowSeconds else { break }
                judged += heard.end - heard.start
                if heard.micDB < heard.theirs[at] + gainDB - config.refuteBelowDB { under += heard.end - heard.start }
            }
            if judged >= 1, under / judged >= 0.6 { path = .none }
        }
    }

    /// What a copy of the far end means. Whether it matters is a question about the route,
    /// not about whoever is talking: earbuds that leak a murmur of the call are a copy too,
    /// and one that can never open the mic. Judged against the loudest a far end gets, so a
    /// quiet participant's faint echo is not taken for a route with none.
    private func route(from fit: Fit) -> Path {
        config.loudestFarEndDB + fit.gainDB >= config.micOpenDB - config.headroomDB
            ? .echo(lag: fit.lag, gainDB: fit.gainDB) : .none
    }

    /// The lag at which the mic looks most like a copy of the far end, each lag judged on its
    /// own newest `seconds` of evidence — or nil until every lag has enough.
    private func bestFit(seconds window: Double) -> Fit? {
        var fits: [Fit] = []
        for (at, lag) in config.lags.enumerated() {
            var mine: [Double] = [], theirs: [Double] = []
            var seconds = 0.0
            for buffer in history.reversed() where buffer.theirs[at] >= config.evidenceDB {
                guard seconds < window else { break }
                mine.append(buffer.micDB)
                theirs.append(buffer.theirs[at])
                seconds += buffer.end - buffer.start
            }
            guard seconds >= min(config.fitNeedsSeconds, window) else { return nil }
            let differences = zip(mine, theirs).map { $0 - $1 }.sorted()
            fits.append(Fit(
                lag: lag, likeness: Self.correlation(mine, theirs),
                gainDB: Self.quantile(differences, 0.5),
                floorDB: Self.quantile(differences, config.floorQuantile)))
        }
        guard let closest = fits.map(\.likeness).max() else { return nil }
        // A longer lag has to earn its place: neighbouring lags fit nearly as well as the
        // true one, and the nearest is the likeliest.
        return fits.filter { $0.likeness >= closest - 0.02 }.min { abs($0.lag) < abs($1.lag) }
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n, meanB = b.reduce(0, +) / n
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in a.indices {
            let da = a[index] - meanA, db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 1e-9, varianceB > 1e-9 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }
}
