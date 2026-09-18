import Foundation
import Testing
@testable import WngmnCore

/// A call as the two captures hear it, sample by sample, made of real recorded speech.
///
/// The far end is what the tap hears. The microphone hears the room, whoever is sitting at it,
/// and — when the call is coming out of a speaker — the far end again, later and quieter.
/// Measured on a MacBook Pro at volume 81: the built-in mic heard the built-in speakers
/// 8 dB down and 32 ms late, over a −56 dBFS room.
///
/// Real speech on purpose. The first version of these tests drew each voice as a block at a
/// constant level, and every one of them passed while the gate they tested muted a user on
/// headphones whenever their interviewer said "mm-hm": a block has no syllables, so nothing
/// distinguished a voice from its echo except how loud it was.
struct SimulatedCall {
    static let rate = GoldenVADTests.rate

    struct Clip {
        var at: Double
        var fixture: String
        /// Applied to the fixture, which peaks near −12 dBFS.
        var gainDB = 0.0
        /// Seconds into the fixture to start from, and how much to take.
        var from = 0.0
        var length: Double?
    }

    var seconds: Double
    var farEnd: [Clip] = []
    var you: [Clip] = []
    /// A steady sound from the far end, under everything else: a fan, hold music.
    var farEndBedDB: Double?
    /// What the way from the speaker to the microphone does to the far end's level, from a
    /// given time. Nil is headphones: no way. Later entries win.
    var coupling: [(from: Double, dB: Double?)] = [(0, -8)]
    var echoDelay = 0.032
    var roomDB = -56.0
    /// A room that rings: every 50 ms it says again, at this fraction, what it said before.
    /// 0.35 takes a third of a second to die away, which is a bare room with hard walls.
    var ringing: Float = 0
    /// The tap and the mic deliver in buffers of their own sizes, and neither lines up with
    /// the other or with the detector's 10 ms windows. 171 frames is the 512 a 48 kHz device
    /// delivers, at this rate; 341 is what a 24 kHz Bluetooth link does.
    var tapBufferFrames = 160
    var micBufferFrames = 171
    /// Times at which the mic device delivers nothing but zeros, as a hardware mute does.
    var micDeadFrom: Double?
    /// What a dead mic delivers instead of zeros, if anything: converter noise.
    var micDeadNoiseDB: Double?

    // MARK: Signals

    /// Noise that is the same every run.
    private static func noise(count: Int, dB: Double, seed: UInt64) -> [Float] {
        var state = seed
        let amplitude = Float(pow(10, dB / 20) * 3.0.squareRoot())   // uniform noise: rms = a/√3
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 23) - 1) * amplitude
        }
    }

    private func mix(_ clips: [Clip], into signal: inout [Float]) throws {
        for clip in clips {
            let samples = try GoldenVADTests.load(clip.fixture)
            let first = Int(clip.from * Self.rate)
            let count = min(clip.length.map { Int($0 * Self.rate) } ?? samples.count, samples.count - first)
            let gain = Float(pow(10, clip.gainDB / 20))
            let offset = Int(clip.at * Self.rate)
            for index in 0..<count where offset + index < signal.count {
                signal[offset + index] += samples[first + index] * gain
            }
        }
    }

    func signals() throws -> (tap: [Float], mic: [Float]) {
        let count = Int(seconds * Self.rate)
        var tap = [Float](repeating: 0, count: count)
        if let farEndBedDB { tap = Self.noise(count: count, dB: farEndBedDB, seed: 7) }
        try mix(farEnd, into: &tap)

        var mic = Self.noise(count: count, dB: roomDB, seed: 11)
        try mix(you, into: &mic)
        let delay = Int(echoDelay * Self.rate)
        for index in delay..<count {
            let t = Double(index) / Self.rate
            guard let path = coupling.last(where: { t >= $0.from })?.dB else { continue }
            let gain = Float(pow(10, path / 20))
            // The room says it twice more, quieter each time.
            mic[index] += tap[index - delay] * gain
            if index >= delay + 400 { mic[index] += tap[index - delay - 400] * gain * 0.35 }
            if index >= delay + 1100 { mic[index] += tap[index - delay - 1100] * gain * 0.15 }
        }
        if ringing > 0 {
            var echo = [Float](repeating: 0, count: count)
            for index in delay..<count {
                let t = Double(index) / Self.rate
                guard let path = coupling.last(where: { t >= $0.from })?.dB else { continue }
                echo[index] = tap[index - delay] * Float(pow(10, path / 20))
                if index >= 800 { echo[index] += echo[index - 800] * ringing }
                mic[index] += echo[index] - tap[index - delay] * Float(pow(10, path / 20))   // the ring, not the echo again
            }
        }
        if let micDeadFrom {
            let first = Int(micDeadFrom * Self.rate)
            let hiss = micDeadNoiseDB.map { Self.noise(count: count - first, dB: $0, seed: 13) }
            for index in first..<count { mic[index] = hiss?[index - first] ?? 0 }
        }
        return (tap, mic)
    }

    // MARK: Running it

    struct Heard {
        var endpoints: [Endpoint] = []
        var silencedSeconds = 0.0
        var silencedAt: [Double] = []
        /// What was let through: when, and how loud.
        var passed: [(t: Double, micDB: Double)] = []
        var verdicts: [(t: Double, verdict: EchoGate.Verdict)] = []
        var announcements: [(t: Double, what: EchoGate.Announcement)] = []
        var path = EchoGate.Path.unknown

        func wasSilenced(at t: Double) -> Bool { silencedAt.contains { abs($0 - t) < 0.011 } }
        func verdict(at t: Double) -> EchoGate.Verdict {
            verdicts.last { $0.t <= t }?.verdict ?? .undecided
        }
        /// The lines whose speech lay mostly inside a stretch of time.
        func lines(within range: ClosedRange<Double>) -> [Endpoint] {
            endpoints.filter {
                let overlap = min($0.speechEnd, range.upperBound) - max($0.speechStart, range.lowerBound)
                return overlap > 0.5 * ($0.speechEnd - $0.speechStart)
            }
        }
    }

    /// Runs the call. With `gated` false the mic is heard as it is, which is what wngmn did
    /// before — so every test can state its premise as well as its claim.
    func run(gated: Bool = true) throws -> Heard {
        let (tap, mic) = try signals()
        let activity = FarEndActivity()
        var gate = EchoGate()
        var config = EndpointerConfig()
        config.openThresholdDB = -35          // the mic's defaults, not the tap's
        config.hangoverMs = 800
        config.floorIgnoresDigitalSilence = true
        var detector = Endpointer(config: config)
        var heard = Heard()
        var events: [EndpointerEvent] = []

        var tapOffset = 0
        var micOffset = 0
        while micOffset < mic.count {
            let frames = min(micBufferFrames, mic.count - micOffset)
            let start = Double(micOffset) / Self.rate
            let end = Double(micOffset + frames) / Self.rate
            // The tap reports first: `MicSource` leaves a buffer in its ring until it has.
            while tapOffset < tap.count, Double(tapOffset) / Self.rate < end {
                let count = min(tapBufferFrames, tap.count - tapOffset)
                let level = tap[tapOffset..<(tapOffset + count)].withUnsafeBufferPointer {
                    AudioLevel.decibels($0)
                }
                let tapStart = Double(tapOffset) / Self.rate
                // A tap with nothing to say delivers nothing.
                if level > -119 {
                    activity.record(start: tapStart, end: tapStart + Double(count) / Self.rate, levelDB: level)
                } else {
                    activity.advance(through: tapStart + Double(count) / Self.rate)
                }
                tapOffset += count
            }

            var buffer = Array(mic[micOffset..<(micOffset + frames)])
            let step = buffer.withUnsafeMutableBufferPointer {
                gate.process(
                    $0, start: start, sampleRate: Self.rate, farEnd: gated ? activity : nil,
                    endpointer: &detector) { events.append($0) }
            }
            if step.silenced {
                heard.silencedSeconds += end - start
                heard.silencedAt.append(start)
            } else {
                heard.passed.append((start, step.micDB))
            }
            if let what = step.announcement { heard.announcements.append((start, what)) }
            if heard.verdicts.last?.verdict != gate.verdict { heard.verdicts.append((start, gate.verdict)) }
            micOffset += frames
        }
        events += detector.idle(upTo: seconds + 2)
        heard.endpoints = events.endpoints
        heard.path = gate.path
        return heard
    }
}

/// The microphone on speakers: it hears the caller as well as you.
///
/// Without headphones, every sentence the caller spoke arrived twice — once from the tap as
/// Caller, once from the mic as You, 32 ms apart and word for word. In one real 80-minute
/// call on built-in speakers, 22 of the 63 of the user's lines that overlapped a caller line
/// were that caller line again. With auto on, each of those is also a request.
/// Serialized because each test replays seconds of recorded speech through the gate, which
/// is computation with no suspension point in it. In parallel they take every thread of the
/// cooperative pool for seconds at a time, and on Linux, where all test targets share one
/// process, that starved the answerer's tests of the thread their requests were waiting for.
@Suite("Echo gate", .serialized)
struct EchoGateTests {
    typealias Clip = SimulatedCall.Clip

    /// Two questions from the far end (two sentences, 1.0–7.7 s), then your answer.
    var speakers: SimulatedCall {
        var call = SimulatedCall(seconds: 16)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions")]
        call.you = [Clip(at: 9.0, fixture: "jargon", gainDB: -6)]
        return call
    }

    @Test("On speakers, what the caller said is not also transcribed as yours")
    func theEchoIsNotALine() throws {
        let before = try speakers.run(gated: false)
        #expect(before.lines(within: 1.0...8.0).count >= 2, "the premise: ungated, the echo is lines of its own")

        let heard = try speakers.run()
        #expect(heard.lines(within: 1.0...8.0).isEmpty)
        #expect(heard.verdict(at: 8.0) == .hearsTheSpeakers)
        let mine = heard.lines(within: 9.0...16.0)
        let premise = before.lines(within: 9.0...16.0)
        #expect(mine.count == premise.count && !mine.isEmpty, "your own answer is still there")
        #expect(abs(mine[0].speechStart - premise[0].speechStart) < 0.03, "and not clipped")
    }

    /// The first version judged the route by how often the mic reached the level that opens
    /// its detector, buffer by buffer. At half volume most of an echo's buffers fall short of
    /// that and a few do not — enough to open the detector and keep it open, not enough to
    /// count — so it ruled "headphones" and every line was still doubled.
    @Test("Turning the speakers down does not bring the doubled lines back", arguments: [-14.0, -18.0, -22.0])
    func atModerateVolume(coupling: Double) throws {
        var call = speakers
        call.coupling = [(0, coupling)]
        let before = try call.run(gated: false)
        try #require(!before.lines(within: 1.0...8.0).isEmpty, "the premise: at \(coupling) dB the echo still makes lines")
        #expect(try call.run().lines(within: 1.0...8.0).isEmpty)
    }

    /// On headphones there is no way from the speaker to the mic, so there is nothing to
    /// remove — and what you say over the caller is yours.
    @Test("On headphones it learns to leave the mic alone, and what you say over them is kept")
    func headphones() throws {
        var call = SimulatedCall(seconds: 22)
        call.coupling = [(0, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 8.0, fixture: "hesitation")]
        call.you = [Clip(at: 10.0, fixture: "jargon", gainDB: -6)]          // talking over them
        let heard = try call.run()
        #expect(heard.verdict(at: 8.0) == .doesNot)
        #expect(heard.announcements.isEmpty, "nothing was ever wrong, so nothing is said")
        let premise = try call.run(gated: false)
        #expect(heard.endpoints.map(\.speechStart) == premise.endpoints.map(\.speechStart))
    }

    /// The scenario that sank the first version. Your long answer, their "mm-hm" every couple
    /// of seconds: the far end is only ever loud while *you* are talking, so a gate that asks
    /// "is the mic raised while they are loud?" hears yes every time, decides you are an
    /// echo, and silences you whenever they make a sound. Your voice is not a copy of theirs.
    @Test("On headphones, their mm-hm through your long answer does not make you an echo")
    func backChannels() throws {
        var call = SimulatedCall(seconds: 30)
        call.coupling = [(0, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "one-question")]
        call.you = [Clip(at: 5.0, fixture: "hesitation", gainDB: -6), Clip(at: 17.0, fixture: "two-questions", gainDB: -6)]
        for index in 0..<11 {                                   // a syllable or two, every two seconds
            call.farEnd.append(Clip(at: 6.0 + Double(index) * 2, fixture: "jargon", gainDB: -8, from: 0.8, length: 0.45))
        }
        let heard = try call.run()
        #expect(!heard.verdicts.contains { $0.verdict == .hearsTheSpeakers })
        #expect(heard.announcements.isEmpty)
        // Two seconds of far-end sound is what it takes to say so, and at half a second an
        // "mm-hm" that is the first two of them. After that, nothing of yours is touched.
        #expect(heard.verdict(at: 9.0) == .doesNot)
        #expect(heard.silencedAt.allSatisfy { $0 < 9.0 }, "silenced at \(heard.silencedAt.filter { $0 >= 9 }.prefix(3))")
        let premise = try call.run(gated: false)
        #expect(heard.lines(within: 9.0...30.0).map(\.speechStart) == premise.lines(within: 9.0...30.0).map(\.speechStart))
    }

    /// Evidence is counted in seconds of far-end sound, not of clock. Half a second of
    /// "mm-hm" every two seconds never adds up to two seconds inside any five of the clock's,
    /// so counted that way the doubt — and the gate, closed for the length of it — lasts for
    /// as long as you go on answering.
    @Test("An interviewer who has only ever said mm-hm is still enough to end the doubt")
    func onlyBackChannels() throws {
        var call = SimulatedCall(seconds: 30)
        call.coupling = [(0, nil)]
        call.you = [Clip(at: 1.0, fixture: "hesitation", gainDB: -6), Clip(at: 7.0, fixture: "two-questions", gainDB: -6),
                    Clip(at: 14.0, fixture: "jargon", gainDB: -6), Clip(at: 19.0, fixture: "hesitation", gainDB: -6)]
        for index in 0..<14 {
            call.farEnd.append(Clip(at: 2.0 + Double(index) * 2, fixture: "jargon", gainDB: -8, from: 0.8, length: 0.45))
        }
        let heard = try call.run()
        #expect(heard.verdict(at: 16.0) == .doesNot, "\(heard.verdicts)")
        #expect(heard.silencedAt.allSatisfy { $0 < 16.0 })
        #expect(heard.announcements.isEmpty)
    }

    /// Someone reading a prepared answer straight through, over an interviewer who will not
    /// stop. Two voices at steady levels differ by a steady number of decibels — which is what
    /// an echo does too, and all that a fit of the *difference* can see.
    @Test("On headphones, two people talking at once without a pause are still two people")
    func twoVoicesWithoutAPause() throws {
        var call = SimulatedCall(seconds: 24)
        call.coupling = [(0, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions")]
        // Speech only, cut from between the silences and laid end to end.
        let theirs: [(String, Double, Double)] = [("jargon", 0.6, 3.6), ("hesitation", 0.6, 2.0), ("one-question", 0.6, 1.8),
                                                  ("jargon", 0.6, 3.6)]
        let mine: [(String, Double, Double)] = [("hesitation", 2.9, 2.0), ("two-questions", 0.6, 1.7), ("jargon", 0.8, 3.2),
                                                ("one-question", 0.6, 1.8), ("two-questions", 4.2, 1.6)]
        var t = 9.0
        for (fixture, from, length) in theirs { call.farEnd.append(Clip(at: t, fixture: fixture, from: from, length: length)); t += length }
        t = 9.0
        for (fixture, from, length) in mine { call.you.append(Clip(at: t, fixture: fixture, gainDB: -6, from: from, length: length)); t += length }
        let heard = try call.run()
        #expect(!heard.verdicts.contains { $0.verdict == .hearsTheSpeakers }, "\(heard.verdicts)")
        #expect(heard.silencedAt.allSatisfy { $0 < 9.0 })
    }

    /// Two recorded voices at steady levels differ by a steady number of decibels, which is
    /// also what an echo does. What an echo does that they do not is rise and fall *with* the
    /// far end, syllable for syllable.
    @Test("On headphones, talking over them for ten seconds is still not an echo")
    func aLongTalkOver() throws {
        var call = SimulatedCall(seconds: 26)
        call.coupling = [(0, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 9.0, fixture: "jargon"),
                       Clip(at: 14.0, fixture: "hesitation")]
        call.you = [Clip(at: 9.2, fixture: "hesitation", gainDB: -6), Clip(at: 15.0, fixture: "two-questions", gainDB: -6)]
        let heard = try call.run()
        #expect(!heard.verdicts.contains { $0.verdict == .hearsTheSpeakers }, "\(heard.verdicts)")
        #expect(heard.silencedAt.allSatisfy { $0 < 9.0 })
    }

    /// The safe mistake, kept small. Deaf for a moment on headphones costs an interjection;
    /// open for a moment on speakers is the caller's first sentence, twice.
    @Test("Until it has heard enough to judge, it assumes speakers")
    func undecidedIsClosed() throws {
        var call = SimulatedCall(seconds: 6)
        call.coupling = [(0, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions")]
        let heard = try call.run()
        #expect(heard.verdict(at: 1.5) == .undecided)
        #expect(heard.silencedSeconds > 0.5)
        // Settled within five seconds of them starting, and nothing silenced after that.
        let settled = try #require(heard.verdicts.first { $0.verdict == .doesNot }?.t)
        #expect(settled < 6.0)
        #expect(heard.silencedAt.allSatisfy { $0 < settled })
    }

    /// Slower than the other direction, and deliberately: the evidence it holds is five
    /// seconds of far-end sound, and until the old arrangement has aged out of it the mic is
    /// a copy of the far end only half the time. Believing a shorter stretch would be
    /// quicker, and would also believe two seconds of you talking over them.
    @Test("Unplugging the headphones mid-call closes it again once it has heard five seconds of them")
    func unplugged() throws {
        var call = SimulatedCall(seconds: 34)
        call.coupling = [(0, nil), (9, -8)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 10.0, fixture: "hesitation"),
                       Clip(at: 17.0, fixture: "two-questions"), Clip(at: 25.0, fixture: "jargon")]
        let heard = try call.run()
        #expect(heard.verdict(at: 8.5) == .doesNot)
        #expect(heard.verdict(at: 24.0) == .hearsTheSpeakers)
        #expect(heard.lines(within: 25.0...33.0).isEmpty)
        #expect(heard.announcements.map(\.what) == [.hearsTheCall])
    }

    /// An echo is a floor under the mic: it can be louder than predicted, when you talk too,
    /// but never quieter. A mic gone quiet under a loud far end has lost its echo.
    @Test("Plugging headphones in mid-call opens it again")
    func pluggedIn() throws {
        var call = SimulatedCall(seconds: 26)
        call.coupling = [(0, -8), (9, nil)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 10.0, fixture: "hesitation"),
                       Clip(at: 17.0, fixture: "two-questions")]
        call.you = [Clip(at: 19.0, fixture: "jargon", gainDB: -6)]
        let heard = try call.run()
        #expect(heard.verdict(at: 8.5) == .hearsTheSpeakers)
        #expect(heard.verdict(at: 16.5) == .doesNot)
        #expect(!heard.lines(within: 19.0...26.0).isEmpty, "what you say over them is yours again")
        #expect(heard.announcements.map(\.what) == [.hearsTheCall, .noLongerHearsTheCall])
    }

    /// A fan at the other end, hold music turned down: steady, and out of a speaker far below
    /// anything that could open the mic. The first version closed for any far end over
    /// −45 dBFS and only *learned* from one over −35, so a bed between the two shut the mic
    /// for the whole call and could never be argued out of it.
    @Test("A caller with a steady noise behind them does not shut your mic for the call")
    func aNoiseBed() throws {
        var call = speakers
        call.farEndBedDB = -40
        let heard = try call.run()
        #expect(heard.lines(within: 1.0...8.0).isEmpty, "their speech is still removed")
        #expect(heard.lines(within: 9.0...16.0).count == (try call.run(gated: false)).lines(within: 9.0...16.0).count)
        #expect(heard.silencedAt.allSatisfy { $0 < 8.6 }, "and once they stop, nothing is")
    }

    @Test("A caller too quiet ever to be evidence silences nothing, on headphones or off")
    func aQuietCaller() throws {
        var call = SimulatedCall(seconds: 16)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions", gainDB: -30)]      // peaks near −42
        call.you = [Clip(at: 3.0, fixture: "jargon", gainDB: -6)]
        for path in [nil, -8.0] as [Double?] {
            call.coupling = [(0, path)]
            let heard = try call.run()
            #expect(heard.silencedSeconds == 0)
            #expect(heard.verdict(at: 15) == .undecided)
        }
    }

    /// The gain belongs to the route, not to whoever is talking. The first version took a
    /// quiet speaker's faint echo as evidence of headphones, and doubled the next loud one.
    @Test("A quiet participant does not convince it the loud one has no echo")
    func quietThenLoud() throws {
        var call = SimulatedCall(seconds: 26)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"),
                       Clip(at: 9.0, fixture: "hesitation", gainDB: -20),      // barely evidence, faint echo
                       Clip(at: 17.0, fixture: "two-questions")]
        let heard = try call.run()
        #expect(heard.lines(within: 17.0...25.0).isEmpty)
        #expect(heard.verdict(at: 25) == .hearsTheSpeakers)
    }

    /// Earbuds leak a little of the call into their own mic, and a speaker turned right down
    /// reaches the mic as a murmur. The mic is a copy of the far end then — but of one that
    /// cannot open its detector, so there is no second line to prevent and closing the gate
    /// would only cost what you say over them.
    @Test("An echo too faint to open the mic is left alone")
    func aFaintEcho() throws {
        var call = SimulatedCall(seconds: 22)
        call.coupling = [(0, -34)]                        // −12 dBFS arrives at −46: over the room, under −35
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 8.0, fixture: "hesitation")]
        call.you = [Clip(at: 10.0, fixture: "jargon", gainDB: -6)]
        let premise = try call.run(gated: false)
        #expect(premise.lines(within: 1.0...8.0).isEmpty, "the premise: it makes no line of its own")
        let heard = try call.run()
        #expect(heard.verdict(at: 8.0) == .doesNot)
        #expect(heard.endpoints.map(\.speechStart) == premise.endpoints.map(\.speechStart))
    }

    /// A Bluetooth speaker is a quarter of a second behind the tap. Paired with the far end
    /// of *now*, its echo looks like an unrelated sound.
    @Test("A speaker a quarter of a second late is still found")
    func aLateSpeaker() throws {
        var call = speakers
        call.echoDelay = 0.26
        let heard = try call.run()
        #expect(heard.lines(within: 1.0...8.0).isEmpty)
        guard case let .echo(lag, _) = heard.path else { Issue.record("no echo found: \(heard.path)"); return }
        #expect(abs(lag - 0.26) <= 0.04, "lag \(lag)")
    }

    @Test("The gain it finds is the gain of the route")
    func findsTheGain() throws {
        let heard = try speakers.run()
        guard case let .echo(lag, gainDB) = heard.path else { Issue.record("no echo found: \(heard.path)"); return }
        #expect(abs(gainDB - -8) < 3, "gain \(gainDB)")
        #expect(abs(lag - 0.032) <= 0.04, "lag \(lag)")
    }

    @Test("A 24 kHz Bluetooth link's longer buffers change nothing")
    func longerBuffers() throws {
        var call = speakers
        call.micBufferFrames = 341
        call.tapBufferFrames = 341
        let heard = try call.run()
        #expect(heard.lines(within: 1.0...8.0).isEmpty)
        #expect(!heard.lines(within: 9.0...16.0).isEmpty)
    }

    /// The opening of a call is often both people at once — "hi, can you hear me", "yes, hi".
    /// A fit made then is not a copy, and ruled "no echo" on the strength of it, the gate
    /// opened on speakers and doubled the caller's next sentences.
    @Test("A call that opens with both people talking does not end the doubt the wrong way")
    func anOpeningOverlap() throws {
        var call = SimulatedCall(seconds: 20)
        call.farEnd = [Clip(at: 1.0, fixture: "jargon"), Clip(at: 9.0, fixture: "two-questions")]
        call.you = [Clip(at: 1.2, fixture: "hesitation", gainDB: 0)]
        let heard = try call.run()
        #expect(!heard.verdicts.contains { $0.verdict == .doesNot }, "\(heard.verdicts)")
        #expect(heard.lines(within: 9.0...17.0).isEmpty)
    }

    /// The same echo, twelve decibels quieter. First it looked like headphones going in: the
    /// gate opened onto an echo that was still there, and the two warnings flapped.
    @Test("Turning the speakers down mid-call is the same echo, quieter")
    func volumeDown() throws {
        var call = SimulatedCall(seconds: 26)
        call.coupling = [(0, -4), (9, -16)]
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 10.0, fixture: "hesitation"),
                       Clip(at: 17.0, fixture: "two-questions")]
        let heard = try call.run()
        #expect(heard.announcements.map(\.what) == [.hearsTheCall])
        #expect(heard.lines(within: 10.0...25.0).isEmpty)
    }

    /// Once there is an echo, a steady far-end sound whose echo can murmur but never open
    /// the mic must not keep it closed. Held to the detector's lower, holding level, a bed
    /// of −34 dBFS did: every word of yours, for the whole call.
    @Test("A loud noise bed does not shut the mic once an echo is known")
    func aLoudBedOnSpeakers() throws {
        var call = speakers
        call.farEndBedDB = -34
        let heard = try call.run()
        #expect(heard.verdict(at: 8.0) == .hearsTheSpeakers)
        #expect(heard.silencedAt.allSatisfy { $0 < 8.6 }, "\(heard.silencedAt.filter { $0 >= 8.6 }.prefix(3))")
        #expect(!heard.lines(within: 9.0...16.0).isEmpty)
    }

    @Test("A muted microphone that hisses instead of going silent is still a muted microphone")
    func aHissingDeadMic() throws {
        var call = SimulatedCall(seconds: 20)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 9.0, fixture: "hesitation")]
        call.micDeadFrom = 8.5
        call.micDeadNoiseDB = -95
        let heard = try call.run()
        #expect(heard.verdict(at: 19) == .hearsTheSpeakers)
    }

    /// A hardware mute delivers zeros. Counted as "the mic is far under the echo", that reads
    /// as the echo having gone, and the first thing after the unmute is doubled.
    @Test("A muted microphone is not a microphone the call no longer reaches")
    func aDeadMic() throws {
        var call = SimulatedCall(seconds: 20)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 9.0, fixture: "hesitation")]
        call.micDeadFrom = 8.5
        let heard = try call.run()
        #expect(heard.verdict(at: 19) == .hearsTheSpeakers)
    }

    /// While you talk over them the mic is no longer a copy of the far end, and the fit says
    /// so. That is no reason to forget an echo already found: the route has not changed, you
    /// have opened your mouth. Forgotten, the rest of their sentence comes through as yours.
    @Test("On speakers, talking over them does not make it forget the echo")
    func talkingOverAnEcho() throws {
        var call = SimulatedCall(seconds: 24)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 9.0, fixture: "jargon"),
                       Clip(at: 13.6, fixture: "hesitation")]
        call.you = [Clip(at: 9.5, fixture: "two-questions", gainDB: 0)]        // louder than their echo
        let heard = try call.run()
        #expect(heard.verdict(at: 23) == .hearsTheSpeakers)
        // You stop at 16.2 and they go on to 19. What is left of their sentence is theirs.
        #expect(heard.lines(within: 16.5...21.0).isEmpty, "\(heard.lines(within: 16.5...21.0))")
        #expect(heard.announcements.map(\.what) == [.hearsTheCall])
    }

    /// A room goes on saying the end of a word after the far end has stopped. Let through,
    /// that is loud enough to be taken for the start of yours.
    @Test("A room that rings does not get the end of their sentence through")
    func aRingingRoom() throws {
        var call = SimulatedCall(seconds: 12)
        call.coupling = [(0, -3)]
        call.ringing = 0.35
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions")]
        let heard = try call.run()
        #expect(heard.lines(within: 1.0...9.0).isEmpty)
        let afterglow = heard.passed.filter { $0.t > 4.0 && $0.t < 9.0 && $0.micDB >= -35 }
        #expect(afterglow.isEmpty, "let through, loud enough to open the mic: \(afterglow.prefix(4))")
    }

    /// Not a feature. Without echo cancellation there is no telling your voice from theirs
    /// while both are coming out of the same microphone, and theirs is the one the tap
    /// already has.
    @Test("On speakers, what you say while they are talking is lost — and that is the price")
    func doubleTalkOnSpeakers() throws {
        var call = SimulatedCall(seconds: 16)
        call.farEnd = [Clip(at: 1.0, fixture: "two-questions"), Clip(at: 8.0, fixture: "hesitation")]
        call.you = [Clip(at: 10.0, fixture: "one-question", gainDB: -6)]      // inside their second turn
        let heard = try call.run()
        #expect(heard.lines(within: 9.5...13.0).isEmpty)
    }
}

/// `process` is the whole of what happens to a mic buffer, so that its order can be tested.
@Suite("Echo gate, one buffer")
struct EchoGateStepTests {
    /// A far end that has been loud, and a gate that has been shown a copy of it.
    func coupled() -> (EchoGate, FarEndActivity, Endpointer) {
        let activity = FarEndActivity()
        var gate = EchoGate()
        var detector = Endpointer(config: EndpointerConfig())
        var t = 0.0
        var level = -12.0
        while t < 3 {
            level = level == -12 ? -22 : -12                       // a far end with some shape to it
            activity.record(start: t, end: t + 0.01, levelDB: level)
            var buffer = TestSignal.frames(seconds: 0.01, dB: level - 8)
            _ = buffer.withUnsafeMutableBufferPointer {
                gate.process($0, start: t, sampleRate: TestSignal.rate, farEnd: activity, endpointer: &detector) { _ in }
            }
            t += 0.01
        }
        return (gate, activity, detector)
    }

    @Test("A silenced buffer is zeroed in place, so the recogniser fed from it hears nothing either")
    func zeroesInPlace() {
        var (gate, activity, detector) = coupled()
        #expect(gate.verdict == .hearsTheSpeakers)
        activity.record(start: 3.0, end: 3.01, levelDB: -12)
        var buffer = TestSignal.frames(seconds: 0.01, dB: -20)
        let step = buffer.withUnsafeMutableBufferPointer {
            gate.process($0, start: 3.0, sampleRate: TestSignal.rate, farEnd: activity, endpointer: &detector) { _ in }
        }
        #expect(step.silenced)
        #expect(abs(step.micDB - -20) < 0.01, "the level reported is the level captured")
        #expect(buffer.allSatisfy { $0 == 0 })
        #expect(detector.lastLevelDB <= -119, "and the detector was shown the silenced buffer, not the echo")
    }

    @Test("With the gate off, a buffer goes to the detector as it came")
    func ungated() {
        var gate = EchoGate()
        var detector = Endpointer(config: EndpointerConfig())
        var buffer = TestSignal.frames(seconds: 0.01, dB: -20)
        let step = buffer.withUnsafeMutableBufferPointer {
            gate.process($0, start: 0, sampleRate: TestSignal.rate, farEnd: nil, endpointer: &detector) { _ in }
        }
        #expect(!step.silenced && step.announcement == nil)
        #expect(abs(detector.lastLevelDB - -20) < 0.01)
    }

    /// Launching while the caller is mid-sentence, or while the tap is being rebuilt: the mic
    /// has audio and the tap has said nothing. Taken for a quiet far end, that stretch would
    /// teach the gate that an echo is you.
    @Test("Where the tap has not reported, nothing is silenced and nothing is learned")
    func theTapHasNotReported() {
        let activity = FarEndActivity()
        var gate = EchoGate()
        for index in 0..<400 {
            let t = Double(index) * 0.01
            let silenced = gate.shouldSilence(start: t, end: t + 0.01, micDB: -18, farEnd: activity)
            #expect(!silenced)
        }
        #expect(gate.verdict == .undecided)
    }
}

@Suite("Far-end activity")
struct FarEndActivityTests {
    @Test("It reports the loudest the far end was in a stretch of time")
    func loudest() {
        let activity = FarEndActivity()
        activity.record(start: 1.00, end: 1.01, levelDB: -40)
        activity.record(start: 1.01, end: 1.02, levelDB: -12)
        activity.record(start: 1.02, end: 1.03, levelDB: -30)
        #expect(activity.loudest(from: 1.0, to: 1.03) == -12)
        #expect(activity.loudest(from: 1.021, to: 1.03) == -30)
        #expect(activity.loudest(from: 1.005, to: 1.006) == -40, "a stretch inside one span")
    }

    /// Not the same thing. A mic that took "not heard from yet" for "quiet" would learn the
    /// caller's echo as its own voice.
    @Test("Silence the tap reported is −120; a stretch it has not reported on is nothing at all")
    func silenceIsNotAbsence() {
        let activity = FarEndActivity()
        #expect(activity.loudest(from: 0, to: 10) == nil)
        activity.record(start: 1.0, end: 1.01, levelDB: -12)
        #expect(activity.loudest(from: 0.2, to: 0.5) == -120)
        #expect(activity.loudest(from: 2.0, to: 3.0) == nil)
        activity.advance(through: 3.0)
        #expect(activity.loudest(from: 2.0, to: 3.0) == -120)
    }

    /// The mic waits for the tap to have reported on a stretch of time before judging it, so
    /// the tap has to say how far it has got — including when it got there by hearing nothing.
    @Test("It knows how far the tap has reported, by sound or by silence, and never goes back")
    func knownThrough() {
        let activity = FarEndActivity()
        #expect(activity.knownThrough == -.infinity)
        activity.record(start: 1.0, end: 1.01, levelDB: -12)
        #expect(activity.knownThrough == 1.01)
        activity.advance(through: 2.5)
        #expect(activity.knownThrough == 2.5)
        activity.advance(through: 2.0)
        #expect(activity.knownThrough == 2.5)
    }

    /// A call is hours long and this is asked a hundred times a second.
    @Test("It forgets what is too old to be asked about")
    func forgets() {
        let activity = FarEndActivity()
        for index in 0..<6000 {                                   // a minute of 10 ms spans
            let start = Double(index) * 0.01
            activity.record(start: start, end: start + 0.01, levelDB: -12)
        }
        #expect(activity.retainedCount <= Int((FarEndActivity.retainedSeconds + 1) / 0.01) + 1)
        #expect(activity.loudest(from: 59.9, to: 60.0) == -12)
        #expect(activity.loudest(from: 1.0, to: 2.0) == -120)
    }
}

@Suite("Audio level")
struct AudioLevelTests {
    @Test("A buffer's level is its RMS in dBFS, and digital silence is −120")
    func level() {
        TestSignal.frames(seconds: 0.01, dB: -20).withUnsafeBufferPointer {
            #expect(abs(AudioLevel.decibels($0) - -20) < 0.01)
        }
        TestSignal.silence(seconds: 0.01).withUnsafeBufferPointer {
            #expect(AudioLevel.decibels($0) == -120)
        }
        [Float]().withUnsafeBufferPointer { #expect(AudioLevel.decibels($0) == -120) }
    }
}
