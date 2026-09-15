import AVFoundation
import CoreMedia
import Foundation
import WngmnCore

/// Turns microphone audio into `you`-labelled transcript events.
///
/// A sibling of `Pipeline` rather than a second source inside it. `Pipeline` carries the
/// aggregate-rebuild, device-watch and keep-alive machinery that a live call depends on,
/// and none of it applies to a plain input device: a microphone is not tap-backed, so it
/// does not stop clocking when the speakers go idle — the failure mode that all of that
/// code exists to survive. Keeping the two apart means enabling the mic cannot regress
/// caller capture, which is the half that matters most.
///
/// The two share an `EventWriter` and a `CaptureTimeline`, which is what makes their
/// questions interleave in the right order.
public actor MicSource {
    public struct Configuration: Sendable {
        public var capture: MicCapture.Configuration
        public var transcriber: Transcriber.Configuration
        public var endpointer: EndpointerConfig
        public var terms: TermList
        public var emitPartials: Bool
        /// Shared with the answer path, so both halves see one version of the profile.
        public var profiles: ProfileSource?

        public init(
            capture: MicCapture.Configuration = .init(),
            transcriber: Transcriber.Configuration = .init(),
            endpointer: EndpointerConfig = .init(),
            terms: TermList = .empty,
            emitPartials: Bool = true,
            profiles: ProfileSource? = nil
        ) {
            self.capture = capture
            self.transcriber = transcriber
            self.endpointer = endpointer
            self.terms = terms
            self.emitPartials = emitPartials
            self.profiles = profiles
        }
    }

    private static let pollInterval = Duration.milliseconds(10)
    private static let finalTimeout: Double = 2.5
    /// How far the recogniser's timeline may fall behind the clock before silence is fed to
    /// close the gap, and how far behind the clock the newest delivered audio necessarily
    /// is. The same numbers, for the same reasons, as `Pipeline`'s.
    private static let silenceThreshold = 0.025
    private static let deliveryLagAllowance = 0.060
    /// Long enough that an ordinary pause between sentences does not trip it, short enough
    /// that a denied microphone is reported while there is still time to fix it.
    private static let silentWarningSeconds: Double = 20

    private let configuration: Configuration
    private let writer: EventWriter
    private let timeline: CaptureTimeline
    private let control: CaptureControl
    private let capture: MicCapture

    private var transcriber: Transcriber?
    private var endpointer: Endpointer
    private var assembler: QuestionAssembler
    private var scratch: [Float]
    private var warnedSilent = false
    /// Whether anything has been fed yet. The shared clock may already be running before
    /// the mic's first buffer, and walking the recogniser forward before that would put its
    /// zero ahead of audio still queued in the ring.
    private var fedFirstBuffer = false
    /// Whether the input device is currently running. Muting stops it outright rather than
    /// discarding its audio, so the system microphone indicator goes out — a mute that
    /// leaves the light on is not a mute.
    private var micRunning = false
    private var started = MonotonicStopwatch()

    public init(
        configuration: Configuration,
        writer: EventWriter,
        timeline: CaptureTimeline,
        control: CaptureControl = CaptureControl()
    ) {
        self.configuration = configuration
        self.writer = writer
        self.timeline = timeline
        self.control = control
        capture = MicCapture(configuration: configuration.capture)
        endpointer = Endpointer(config: configuration.endpointer)
        var assembler = QuestionAssembler(terms: configuration.terms)
        assembler.finalTimeout = Self.finalTimeout
        self.assembler = assembler
        scratch = [Float](repeating: 0, count: 16_384)
    }

    public func run() async throws {
        try capture.start()
        micRunning = true
        defer { capture.stop() }
        started = MonotonicStopwatch()

        let transcriber = try await Transcriber(configuration: configuration.transcriber)
        self.transcriber = transcriber
        try await transcriber.prepare(sourceFormat: capture.format)

        writer.emit(.status(
            state: "mic",
            format: StreamFormat(
                rate: capture.format.sampleRate, ch: Int(capture.format.channelCount)
            ),
            detail: AudioCatalog.deviceName(capture.deviceID)
        ))

        let transcripts = transcriber.transcripts
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await transcript in transcripts { await self?.handle(transcript: transcript) }
            }
            group.addTask { [weak self] in await self?.consume() }
            await group.next()
            group.cancelAll()
        }
        await transcriber.finish()
    }

    public nonisolated func stop() { capture.stop() }

    // MARK: - Audio

    private func consume() async {
        while !Task.isCancelled {
            do {
                try await drain()
                try await advanceIdleTime()
            } catch {
                writer.emit(.warning(code: "mic_feed_failed", detail: "\(error)"))
            }
            applyMute()
            checkPendingTimeouts()
            checkSilence()
            if writer.readerIsGone { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Starts and stops the device to match the mute flag.
    ///
    /// Restarting is cheap here in a way it is not for the tap: a microphone is an ordinary
    /// input device with no aggregate, no tap object and no rebuild path to get wrong, which
    /// is why mute can stop the hardware while pause only discards.
    private func applyMute() {
        let muted = control.micMuted
        guard muted != !micRunning else { return }
        if muted {
            capture.stop()
            micRunning = false
            // Close anything half-spoken so it cannot stitch across the mute.
            var pending: [EndpointerEvent] = []
            endpointer.flush(at: timeline.seconds(forHostTime: HostClock.now()) ?? 0) {
                pending.append($0)
            }
            // Discarded rather than emitted: the words after a mute are exactly what the
            // user asked not to be captured.
            _ = pending
            _ = assembler.takeDropped()
            writer.emit(.status(state: "control", format: nil, detail: control.stateDescription))
        } else {
            do {
                try capture.start()
                micRunning = true
                writer.emit(.status(state: "control", format: nil, detail: control.stateDescription))
            } catch {
                writer.emit(.warning(code: "mic_unmute_failed", detail: "\(error)"))
            }
        }
    }

    private func drain() async throws {
        // Anything the ring collected in the instant before the device stopped is dropped
        // rather than transcribed late.
        if control.micMuted {
            while capture.ring.readSegment(into: &scratch, capacity: scratch.count) != nil {}
            return
        }
        while let peek = capture.ring.peekSegment() {
            if peek.frameCount > scratch.count {
                scratch = [Float](repeating: 0, count: peek.frameCount * 2)
            }
            let segment: AudioSegment? = scratch.withUnsafeMutableBufferPointer {
                capture.ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
            }
            guard let segment else { return }

            // Anchored against the shared origin rather than a private one, so a "You" line
            // and a "Caller" line an instant apart sort in the order they were spoken.
            timeline.anchor(segment.hostTime)
            let start = timeline.seconds(forHostTime: segment.hostTime) ?? 0

            var events: [EndpointerEvent] = []
            scratch.withUnsafeBufferPointer { buffer in
                endpointer.push(
                    UnsafeBufferPointer(rebasing: buffer[0..<segment.frameCount]),
                    startTime: start, sampleRate: capture.format.sampleRate
                ) { events.append($0) }
            }

            if let transcriber {
                // Aligned to the shared timeline before feeding, as the tap is. The mic's
                // first buffer is not at zero on that timeline, and a mute leaves a hole in
                // it. Fed without this, the recogniser's timestamps sat behind the
                // endpointer's by the length of every mute so far, no final ever covered
                // the endpoint that asked for it, and each line after the first unmute
                // waited out the 2.5 s timeout — quietly, and with the next sentence's
                // words pulled in.
                try await transcriber.advance(toStreamSeconds: start)
                try await transcriber.feed(Array(scratch[0..<segment.frameCount]))
                fedFirstBuffer = true
            }
            for event in events { await handle(event) }
        }
    }

    /// Walks the recogniser forward through silence when nothing is being fed.
    ///
    /// The mic delivers continuously, so unlike the tap it never stalls — except while
    /// muted, when its buffers are discarded. Left alone, the recogniser then stood still
    /// for the whole mute and the first buffer after it filled the whole hole at once: a
    /// ten-minute mute became six hundred buffers of silence queued ahead of the first real
    /// word. Fed here in real time, a mute is just quiet.
    private func advanceIdleTime() async throws {
        guard fedFirstBuffer, let transcriber,
              let now = timeline.seconds(forHostTime: HostClock.now())
        else { return }
        let cursor = await transcriber.cursorSeconds
        guard let target = Self.idleAdvanceTarget(
            now: now, cursor: cursor,
            allowance: Self.deliveryLagAllowance, threshold: Self.silenceThreshold
        ) else { return }
        try await transcriber.advance(toStreamSeconds: target)
    }

    /// Where to walk the recogniser to, or nil when it is close enough behind the clock.
    /// Only time the mic has certainly finished delivering is ever filled. Pure, so the rule
    /// can be asserted without a microphone.
    static func idleAdvanceTarget(
        now: Double, cursor: Double, allowance: Double, threshold: Double
    ) -> Double? {
        let settled = now - allowance
        return settled - cursor > threshold ? settled : nil
    }

    private func handle(_ event: EndpointerEvent) async {
        switch event {
        case .speechStarted, .discarded:
            break
        case let .endpoint(endpoint):
            assembler.endpointDetected(endpoint, now: Self.monotonicNow)
            await transcriber?.finalize(throughStreamSeconds: endpoint.decisionTime)
        }
    }

    private func handle(transcript: Transcriber.Transcript) {
        let safeStart = transcript.start
        let safeEnd = transcript.end

        guard transcript.isFinal else {
            assembler.volatileArrived(start: safeStart, end: safeEnd, text: transcript.text)
            guard configuration.emitPartials else { return }
            let text = TextNormalizer.stripArtifacts(transcript.text)
            guard !text.isEmpty else { return }
            writer.emit(.partial(text: text, t: safeEnd, speaker: .you))
            return
        }

        if let profiles = configuration.profiles {
            let terms = profiles.current().terms
            if terms != assembler.terms { assembler.terms = terms }
        }
        let questions = assembler.finalArrived(
            start: safeStart, end: safeEnd, text: transcript.text, now: Self.monotonicNow
        )
        reportDropped()
        for question in questions {
            writer.emit(.question(question, speaker: .you))
        }
    }

    /// Emits questions whose final never arrived.
    ///
    /// Without this a mic question waits for the *next* final to flush it rather than for
    /// its own 2.5 s timeout, so a last remark before a silence surfaces tens of seconds
    /// late or not at all. No `final_timeout` warning is emitted, for the same reason
    /// dropped boundaries are not: your own side of a call is full of half-words, and one
    /// warning each would bury the caller's genuine ones.
    private func checkPendingTimeouts() {
        let timedOut = assembler.tick(now: Self.monotonicNow)
        reportDropped()
        for question in timedOut {
            writer.emit(.question(question, speaker: .you))
        }
    }

    /// A boundary of your own speech that produced no question.
    ///
    /// Two very different cases, split by whether a transcript arrived at all. A boundary
    /// whose text was heard and then lost (`hadTranscript`) is a genuine miss and warns,
    /// under its own code so it filters separately from the caller's. A boundary the
    /// recogniser found no words in is not: on your own mic that is typing, a breath, a
    /// cough — the gate opening on non-speech, several times a minute — so it is not
    /// reported. Suppressing it used to hide whole lost sentences too, but those now fall
    /// back to their volatile in the assembler and are emitted rather than dropped, so the
    /// only thing left to suppress is the noise.
    private func reportDropped() {
        for drop in assembler.takeDropped() where drop.hadTranscript {
            writer.emit(.warning(
                code: "mic_question_lost",
                detail: String(
                    format: "your speech at t0=%.2f t1=%.2f produced no usable text",
                    drop.endpoint.speechStart, drop.endpoint.speechEnd
                )
            ))
        }
    }

    /// A denied microphone returns `noErr` from every call and simply produces silence — the
    /// same failure the tap has, and the same reason it needs saying out loud.
    private func checkSilence() {
        guard !warnedSilent, started.elapsedSeconds > Self.silentWarningSeconds else { return }
        guard capture.diagnostics.frames == 0 else {
            warnedSilent = true
            return
        }
        warnedSilent = true
        writer.emit(.warning(
            code: "mic_silent",
            detail: "no microphone buffers in \(Int(Self.silentWarningSeconds))s; "
                + "Microphone access is granted to the terminal app, not to wngmn"
        ))
    }

    private static var monotonicNow: Double {
        Double(HostClock.nanos(fromTicks: HostClock.now())) / 1_000_000_000
    }
}
