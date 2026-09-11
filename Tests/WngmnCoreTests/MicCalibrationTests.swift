import Testing
@testable import WngmnCore

/// Choosing `--mic-open-db` from measurements instead of from guesses.
///
/// The threshold has to sit in a band with two hard edges: above the room, or the detector
/// never hears silence and no question is ever finalised; below your voice, or speech never
/// crosses it and nothing is heard at all. Both failures look the same from outside —
/// partials appear and questions never do.
@Suite("Mic calibration")
struct MicCalibrationTests {
    /// dB values, quiet to loud.
    func windows(_ range: ClosedRange<Double>, count: Int = 200) -> [Double] {
        (0..<count).map { range.lowerBound
            + (range.upperBound - range.lowerBound) * Double($0) / Double(count - 1) }
    }

    @Test("A well-separated room lands between the two")
    func clearSeparation() throws {
        let result = try #require(MicCalibration.recommend(
            ambient: windows((-60)...(-45)), speech: windows((-35)...(-12))))
        #expect(result.confident)
        #expect(result.recommended > -45, "must sit above the room or silence never closes")
        #expect(result.recommended < -20, "must sit below speech or nothing is ever heard")
    }

    /// The threshold must clear the room by more than the hysteresis, or the detector opens
    /// and never closes: speech is "still happening" forever and no endpoint fires.
    @Test("The recommendation clears ambient by at least the hysteresis")
    func clearsHysteresis() throws {
        let ambient = windows((-50)...(-40))
        let result = try #require(MicCalibration.recommend(
            ambient: ambient, speech: windows((-30)...(-10)), hysteresisDB: 6))
        let ambientHigh = ambient.max()!
        #expect(result.recommended >= ambientHigh - 6,
                "recommended \(result.recommended) would leave the close threshold inside the room noise")
    }

    /// A noisy room with quiet speech has no good answer. Saying so is the useful output;
    /// returning a confident number that cannot work is not.
    @Test("Overlapping distributions are reported as not confident")
    func noSeparation() throws {
        let result = try #require(MicCalibration.recommend(
            ambient: windows((-40)...(-20)), speech: windows((-38)...(-18))))
        #expect(!result.confident)
        #expect(result.separationDB < 6)
    }

    @Test("Wider separation is reported as such")
    func reportsSeparation() throws {
        let close = try #require(MicCalibration.recommend(
            ambient: windows((-50)...(-40)), speech: windows((-38)...(-30))))
        let wide = try #require(MicCalibration.recommend(
            ambient: windows((-70)...(-60)), speech: windows((-30)...(-10))))
        #expect(wide.separationDB > close.separationDB)
    }

    @Test("No samples yields no recommendation rather than a made-up one")
    func emptyInput() {
        #expect(MicCalibration.recommend(ambient: [], speech: windows((-30)...(-10))) == nil)
        #expect(MicCalibration.recommend(ambient: windows((-60)...(-50)), speech: []) == nil)
    }
}


/// Calibrating from one continuous recording instead of two timed phases.
///
/// The two-phase version needed the user to hear "now talk" at the right moment, and any
/// wrapper that buffers output breaks that silently — the measurement inverts, reporting
/// the room as louder than the voice. One recording with the phases separated afterwards
/// by level cannot fail that way: it does not matter *when* the talking happened.
@Suite("Mic calibration from one pass")
struct MicSinglePassTests {
    /// Half quiet, half loud, interleaved so ordering cannot be what separates them.
    func mixed(quiet: Double, loud: Double, talkFraction: Double, count: Int = 400) -> [Double] {
        (0..<count).map { Double($0) / Double(count) < talkFraction ? loud : quiet }.shuffled()
    }

    @Test("Talking for about half the recording separates cleanly")
    func halfTalking() throws {
        let result = try #require(MicCalibration.recommend(
            samples: mixed(quiet: -50, loud: -20, talkFraction: 0.5)))
        #expect(result.confident)
        #expect(result.recommended > -50 && result.recommended < -20)
    }

    /// Talking for only a fifth of it must still work — people pause.
    @Test("A short burst of talking is still found")
    func shortBurst() throws {
        let result = try #require(MicCalibration.recommend(
            samples: mixed(quiet: -50, loud: -20, talkFraction: 0.2)))
        #expect(result.confident)
    }

    /// Never speaking must report no separation rather than inventing a threshold from the
    /// noise floor's own spread — the failure that produced a -10 dB "separation".
    @Test("Silence throughout is reported as no separation")
    func neverSpoke() throws {
        let result = try #require(MicCalibration.recommend(
            samples: mixed(quiet: -50, loud: -50, talkFraction: 0.5)))
        #expect(!result.confident)
        #expect(result.separationDB < 6)
    }

    @Test("Too few windows yields nothing rather than a guess")
    func tooFewSamples() {
        #expect(MicCalibration.recommend(samples: [-40, -20]) == nil)
    }
}


/// Splitting one recording into "room" and "voice" by finding the gap between them.
///
/// The first single-pass attempt took a fixed percentile as the room's upper edge, which is
/// the 40th percentile of a *mixture* — far below where the room actually peaks. It
/// recommended thresholds several dB too low, the detector never heard silence, and no
/// question ever finalised while partial text kept scrolling.
@Suite("Level split")
struct LevelSplitTests {
    func mixed(quiet: Double, loud: Double, talkFraction: Double, count: Int = 400) -> [Double] {
        (0..<count).map { Double($0) / Double(count) < talkFraction ? loud : quiet }.shuffled()
    }

    @Test("The split lands between the two groups, not inside one")
    func findsTheGap() throws {
        let split = try #require(MicCalibration.splitLevel(mixed(quiet: -50, loud: -20, talkFraction: 0.4)))
        // The split is the top of the quiet group — `quiet` is everything <= it — so for a
        // two-valued recording it lands exactly on the quiet level.
        #expect(split >= -50 && split < -20, "split \(split) is not between the groups")
    }

    /// The failure that motivated this: the room's own upper edge, not a percentile of the
    /// mixture, is what the threshold has to clear.
    @Test("Ambient is measured from the quiet group's top, not the mixture's middle")
    func ambientIsTheQuietGroupsTop() throws {
        // A room that idles at -45 but peaks at -30, plus speech at -15.
        var samples = (0..<300).map { _ in Double.random(in: (-45)...(-30)) }
        samples += (0..<200).map { _ in Double.random(in: (-18)...(-12)) }
        let result = try #require(MicCalibration.recommend(samples: samples))
        #expect(result.ambientHighDB > -34,
                "ambient \(result.ambientHighDB) ignores the room's peaks and will never close")
        #expect(result.recommended > result.ambientHighDB,
                "the threshold must sit above the room, not inside it")
    }

    @Test("A recording with no speech has no gap to find")
    func noGap() {
        let flat = (0..<300).map { _ in Double.random(in: (-42)...(-38)) }
        let result = MicCalibration.recommend(samples: flat)
        #expect(result?.confident != true)
    }
}
