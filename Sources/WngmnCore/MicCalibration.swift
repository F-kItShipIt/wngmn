import Foundation

/// Picks `--mic-open-db` from measured room and voice levels.
///
/// The threshold sits in a band with two hard edges, and missing either produces the same
/// symptom from outside — partial text appearing while no question ever finalises:
///
/// * **Too low**, and the room itself stays above the close threshold. The detector opens
///   and never closes, so speech is "still happening" forever and no endpoint fires.
/// * **Too high**, and your voice never sustains above it for the onset window, so speech
///   is never detected at all.
///
/// The default of −35 dBFS was a starting point written without measurement, and it is
/// wrong in both directions depending on the room. This replaces the guess.
public enum MicCalibration {
    public struct Result: Sendable, Equatable {
        /// The value to pass to `--mic-open-db`.
        public let recommended: Double
        /// Headroom between the loud end of the room and the loud end of speech. Under
        /// roughly 6 dB there is no threshold that separates them reliably.
        public let separationDB: Double
        /// Whether a threshold exists that clears the room *and* catches speech.
        public let confident: Bool
        public let ambientHighDB: Double
        public let speechHighDB: Double
    }

    /// `ambient` and `speech` are per-window RMS in dBFS, measured over the same window the
    /// endpointer uses.
    ///
    /// Both are read at a high percentile rather than the median. The median of a speech
    /// recording is mostly the gaps between words, and the median of a room misses the
    /// fridge; what decides whether the detector opens and closes is the loud end of each.
    public static func recommend(
        ambient: [Double], speech: [Double], hysteresisDB: Double = 6
    ) -> Result? {
        guard !ambient.isEmpty, !speech.isEmpty else { return nil }

        let ambientHigh = percentile(ambient, 0.95)
        let speechHigh = percentile(speech, 0.90)
        let separation = speechHigh - ambientHigh

        // The floor is set by the *close* threshold, which sits `hysteresisDB` below the
        // open one: to hear silence at all, the room has to fall below open − hysteresis.
        let floor = ambientHigh + hysteresisDB
        // A little below the loud end of speech, so onset has windows to sustain on rather
        // than clipping the start of every sentence.
        let ceiling = speechHigh - 2

        guard floor < ceiling else {
            // No value satisfies both. The honest output is the least-bad threshold plus
            // the fact that it will not work well — a confident number that cannot succeed
            // sends the user hunting for a bug that is really a noisy room.
            return Result(
                recommended: (ceiling * 10).rounded() / 10,
                separationDB: separation,
                confident: false,
                ambientHighDB: ambientHigh,
                speechHighDB: speechHigh
            )
        }

        return Result(
            recommended: ((floor + ceiling) / 2 * 10).rounded() / 10,
            separationDB: separation,
            confident: true,
            ambientHighDB: ambientHigh,
            speechHighDB: speechHigh
        )
    }

    /// Calibrates from one continuous recording, separating room from voice by level
    /// rather than by when they happened.
    ///
    /// The two-phase version depended on the user hearing "now talk" at the right moment.
    /// Any wrapper that buffers output breaks that invisibly, and the measurement inverts —
    /// reporting the room as *louder* than the voice, which is impossible and was the first
    /// sign the method rather than the room was at fault. Here it does not matter when the
    /// talking happened, only that some of the recording contains it.
    ///
    /// The split is by fixed percentile rather than by clustering: p40 sits inside the
    /// quiet floor for any realistic amount of talking, and p95 inside the loud part. If
    /// the recording is entirely silence both land in the same distribution, the separation
    /// collapses, and that is reported rather than papered over.
    /// Calibrates from one continuous recording, separating room from voice by level
    /// rather than by when they happened.
    ///
    /// Timed phases needed the user to hear "now talk" at the right moment, and any wrapper
    /// that buffers output delays the cue past the window — the measurement then inverts and
    /// reports the room as louder than the voice. Here it does not matter when the talking
    /// happened, only that some of the recording contains it.
    public static func recommend(
        samples: [Double], hysteresisDB: Double = 6
    ) -> Result? {
        guard samples.count >= 20 else { return nil }
        guard let split = splitLevel(samples) else {
            // One group: no speech, or a room as loud as the voice. Either way there is no
            // threshold, and reporting the spread of a single distribution as "separation"
            // would dress that up as an answer.
            return Result(
                recommended: (percentile(samples, 0.95) * 10).rounded() / 10,
                separationDB: 0,
                confident: false,
                ambientHighDB: percentile(samples, 0.95),
                speechHighDB: percentile(samples, 0.95)
            )
        }
        let quiet = samples.filter { $0 <= split }
        let loud = samples.filter { $0 > split }
        guard quiet.count >= 5, loud.count >= 5 else { return nil }
        return recommend(ambient: quiet, speech: loud, hysteresisDB: hysteresisDB)
    }

    /// The level that best separates the recording into two groups, or nil when it is
    /// really one group.
    ///
    /// Otsu's method: the split maximising the variance *between* the two groups. Chosen
    /// over a fixed percentile because the percentile has to assume how much of the
    /// recording is speech, and being wrong about that moves the room's estimated ceiling —
    /// which is the number the whole threshold hangs from.
    public static func splitLevel(_ samples: [Double], minimumSeparation: Double = 4) -> Double? {
        guard samples.count >= 20 else { return nil }
        let sorted = samples.sorted()
        guard let low = sorted.first, let high = sorted.last, high - low > minimumSeparation else {
            return nil
        }

        let total = Double(sorted.count)
        let sum = sorted.reduce(0, +)
        var runningSum = 0.0
        var best: (threshold: Double, variance: Double)?

        for (i, value) in sorted.enumerated().dropLast() {
            runningSum += value
            let belowCount = Double(i + 1)
            let aboveCount = total - belowCount
            guard aboveCount > 0 else { break }
            let belowMean = runningSum / belowCount
            let aboveMean = (sum - runningSum) / aboveCount
            let gap = aboveMean - belowMean
            let variance = belowCount * aboveCount * gap * gap
            if best == nil || variance > best!.variance {
                best = (threshold: value, variance: variance)
            }
        }

        guard let best else { return nil }
        // A split through the middle of one distribution always "wins" on variance, so the
        // groups it produces have to be genuinely far apart before it counts as two things.
        let quiet = sorted.filter { $0 <= best.threshold }
        let loud = sorted.filter { $0 > best.threshold }
        guard !quiet.isEmpty, !loud.isEmpty else { return nil }
        let quietMean = quiet.reduce(0, +) / Double(quiet.count)
        let loudMean = loud.reduce(0, +) / Double(loud.count)
        guard loudMean - quietMean >= minimumSeparation else { return nil }
        return best.threshold
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}
