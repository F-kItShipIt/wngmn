import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import WngmnCore
import Synchronization

/// Capture → endpoint → transcribe → emit.
///
/// The consumer runs as a single serial task. Everything real-time lives behind the ring
/// buffer; everything here is allowed to allocate, log and await.
public actor Pipeline {
    public struct Configuration: Sendable {
        public var tap: SystemAudioTap.Configuration
        public var transcriber: Transcriber.Configuration
        public var endpointer: EndpointerConfig
        public var terms: TermList
        public var emitPartials: Bool
        public var debugVAD: Bool
        /// Label applied to this source's lines. Nil when the tap is the only source, which
        /// keeps single-source output byte-identical to the published shape; set to
        /// `.caller` once the microphone is also being captured, so both halves are labelled
        /// rather than one being labelled and the other left to be inferred.
        public var speaker: Speaker?
        /// Shared with the answer path. Consulted before each finalisation so an edited
        /// `## Terms` section reaches jargon repair without a restart — the profile is one
        /// file, so editing it must not update half the tool.
        public var profiles: ProfileSource?

        public init(
            tap: SystemAudioTap.Configuration,
            transcriber: Transcriber.Configuration,
            endpointer: EndpointerConfig,
            terms: TermList = .empty,
            emitPartials: Bool = true,
            debugVAD: Bool = false,
            speaker: Speaker? = nil,
            profiles: ProfileSource? = nil
        ) {
            self.tap = tap
            self.transcriber = transcriber
            self.endpointer = endpointer
            self.terms = terms
            self.emitPartials = emitPartials
            self.debugVAD = debugVAD
            self.speaker = speaker
            self.profiles = profiles
        }
    }

    /// Poll interval for the consumer. Short enough that the 250 ms hangover is resolved
    /// promptly, long enough that the loop is not a spin.
    private static let pollInterval = Duration.milliseconds(5)
    /// How far the analyser's timeline may fall behind the capture clock before silence is
    /// injected to close the gap. Two tap buffer periods.
    private static let silenceThreshold = 0.025
    /// How far behind the wall clock the tap's newest delivered audio necessarily is.
    ///
    /// An input IOProc cannot run before the frames it carries exist. Measured on this
    /// machine: 512-frame buffers at 48 kHz, and the block runs 20.7 ms after the last frame
    /// it delivers. Wall-clock "now" therefore always leads the endpointer's cursor.
    ///
    /// Idling the endpointer to that unclamped "now" fabricates -120 dBFS windows over audio
    /// that has been captured but not yet handed over, interleaved with the real ones. The
    /// state machine then never sees two consecutive above-threshold windows, `.onset` never
    /// reaches `.speech`, and **no question is ever emitted for the whole session** — while
    /// every status line still reads `capturing`. Verified by replay: 0 endpoints with the
    /// unclamped bound, 1 endpoint (identical to the offline path) with this allowance.
    ///
    /// 60 ms is comfortably past the measured lag and far inside the 250 ms hangover, so a
    /// genuine stall still closes the question on time.
    private static let deliveryLagAllowance = 0.060
    /// A pending question with no matching final after this long is emitted with whatever
    /// text exists, rather than being lost.
    private static let finalTimeout = 2.5
    /// Per §4.2: the no-buffer check is a long-window *secondary* signal. The tap
    /// legitimately delivers nothing whenever the tapped output device is not clocking, so
    /// a short timer would rebuild the capture graph during the pause before a question.
    private static let noBufferWarningSeconds = 90.0
    /// How long a tap may be alive, registered and still delivering nothing before the
    /// graph is rebuilt anyway.
    ///
    /// The warning window above deliberately does not rebuild: the tap is legitimately
    /// silent whenever the tapped device is not clocking. But "no buffers" is not "no
    /// speech" — a running IOProc delivers buffers *of* silence, so a stretch this long
    /// with none at all is a stalled graph rather than a quiet room. Observed twice in
    /// multi-hour runs, both reporting deviceAlive=true ioProcRegistered=true and both
    /// recovering never, because those two probes were the only thing that could trigger a
    /// rebuild.
    private static let noBufferRebuildSeconds = 240.0
    /// Ceiling on the backoff between rebuilds that change nothing. Capped rather than
    /// unbounded so a session left running overnight is still retrying in the morning.
    private static let maximumRebuildInterval = 3600.0

    private let configuration: Configuration
    private let writer: EventWriter

    /// The live tap, reachable without the actor.
    ///
    /// Teardown has to be callable synchronously from the signal handler: dispatching a
    /// `Task` there loses the race against `exit()`, and the private aggregate device that
    /// gets left behind is invisible to `system_profiler`, so it would accumulate unnoticed
    /// on every Ctrl-C.
    private nonisolated let activeTap = Mutex<SystemAudioTap?>(nil)

    private var tap: SystemAudioTap {
        didSet { activeTap.withLock { $0 = tap } }
    }
    private var transcriber: Transcriber?
    private var watcher: DeviceWatcher?
    private var clock = AudioStreamClock()
    private var endpointer: Endpointer

    /// Offset that keeps the emitted timeline continuous across a capture-graph rebuild.
    private var timelineOffset: Double = 0
    /// Origin shared with any other capture source, so a "Caller" line and a "You" line an
    /// instant apart sort in the order they were spoken rather than by which device
    /// happened to receive its first buffer first.
    private let timeline: CaptureTimeline
    private let control: CaptureControl
    /// Which capture-graph anchor `timelineOffset` was computed against. Without this the
    /// offset could only ever be computed once, so a second device change during the same
    /// call would leave every timestamp after it wrong.
    private var offsetComputedForAnchor: UInt64?

    private var scratch: [Float]
    private var assembler: QuestionAssembler
    private var lastBufferHostTime: UInt64?
    private var warnedNoBuffers = false
    /// Rebuilds since the last buffer actually arrived. Reset by a buffer, not by a
    /// successful-looking rebuild: a rebuild that returns without error but still delivers
    /// nothing is exactly the case the backoff exists for.
    private var consecutiveRebuilds = 0
    /// Tracks the pause transition so the endpointer is flushed once on the way in, rather
    /// than on every poll while paused.
    private var wasPaused = false
    /// Loudest sample seen since capture started, for the silent-capture check.
    private var loudestSample: Float = 0
    private var warnedSilentCapture = false
    private var captureStarted = MonotonicStopwatch()
    private var transcriberDied = false
    private var rebuildRequested: RebuildReason?

    private enum RebuildReason: String {
        case defaultOutputDeviceChanged = "default_output_changed"
        case clockDeviceDied = "clock_device_died"
        case noBuffers = "no_buffers"
    }

    public init(
        configuration: Configuration,
        writer: EventWriter,
        timeline: CaptureTimeline = CaptureTimeline(),
        control: CaptureControl = CaptureControl()
    ) {
        self.configuration = configuration
        self.writer = writer
        self.timeline = timeline
        self.control = control
        let tap = SystemAudioTap(configuration: configuration.tap)
        self.tap = tap
        activeTap.withLock { $0 = tap }
        endpointer = Endpointer(config: configuration.endpointer)
        var assembler = QuestionAssembler(terms: configuration.terms)
        assembler.finalTimeout = Self.finalTimeout
        self.assembler = assembler
        scratch = [Float](repeating: 0, count: 16_384)
    }

    // MARK: - Run

    public func run() async throws {
        writer.emit(.status(state: "starting", format: nil, detail: nil))

        try await Self.requireModel(configuration.transcriber.locale)

        try startCapture()
        defer { shutdown() }

        let transcriber = try await Transcriber(configuration: configuration.transcriber)
        self.transcriber = transcriber
        try await transcriber.prepare(sourceFormat: tap.format)

        writer.emit(.status(
            state: "capturing",
            format: StreamFormat(rate: tap.format.sampleRate, ch: Int(tap.format.channelCount)),
            detail: nil
        ))

        // Only the result stream crosses into the child task — the transcriber itself is
        // not Sendable and stays owned by this actor.
        let transcripts = transcriber.transcripts
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await transcript in transcripts {
                    await self?.handle(transcript: transcript)
                }
                await self?.noteTranscriberEnded()
            }
            group.addTask { [weak self] in await self?.consumeAudio() }
            await group.next()
            group.cancelAll()
        }

        await transcriber.finish()
        if transcriberDied {
            // Exiting 0 here would tell a supervisor — or the user glancing at the terminal
            // after the call — that the session ended normally, when in fact transcription
            // stopped partway through and every question after that point was lost.
            throw Transcriber.Failure.recognitionStopped
        }
        writer.emit(.status(state: "stopped", format: nil, detail: nil))
    }

    /// Fails fast with an actionable message rather than transcribing silence all call.
    static func requireModel(_ locale: String) async throws {
        guard await Transcriber.isModelInstalled(locale: locale) else {
            let installed = await Transcriber.installedLocaleIdentifiers()
            throw Transcriber.Failure.modelUnavailable(
                "\(locale) is not installed (installed: \(installed.joined(separator: ", "))); "
                + "run `wngmn install-model --locale \(locale)`"
            )
        }
    }

    private func startCapture() throws {
        // Start the no-buffer clock now, so a tap that never delivers a single buffer is
        // still noticed rather than waiting forever on a timestamp that never arrives.
        lastBufferHostTime = HostClock.now()
        captureStarted = MonotonicStopwatch()
        loudestSample = 0
        warnedSilentCapture = false
        // A crash cannot run teardown, and a leaked private aggregate is invisible to
        // `system_profiler`, so it would accumulate silently.
        let swept = SystemAudioTap.sweepLeakedAggregates()
        if swept > 0 {
            writer.emit(.warning(
                code: "swept_aggregates",
                detail: "destroyed \(swept) aggregate device(s) left by a previous run"
            ))
        }
        // Registered before the graph is built, so a failure to build it still leaves us
        // listening for the device change that will fix it.
        let watcher = DeviceWatcher { [weak self] change in
            guard let self else { return }
            Task { await self.requestRebuild(for: change) }
        }
        do {
            try watcher.start()
        } catch {
            // A listener the HAL refuses is indistinguishable from a live one, so say so
            // rather than silently running without device-change detection.
            writer.emit(.warning(
                code: "listener_failed",
                detail: "default-output listener not registered: \(error); "
                    + "device changes will only be caught by the 90 s no-buffer check"
            ))
        }
        self.watcher = watcher

        try tap.start()
        clock = AudioStreamClock(sampleRate: Int32(tap.format.sampleRate))

        do {
            try watcher.watchClockDevice(tap.clockDeviceID)
        } catch {
            writer.emit(.warning(
                code: "listener_failed",
                detail: "clock-device liveness listener not registered: \(error)"
            ))
        }
    }

    private func requestRebuild(for change: DeviceWatcher.Change) {
        switch change {
        case .defaultOutputDeviceChanged: rebuildRequested = .defaultOutputDeviceChanged
        case .clockDeviceDied: rebuildRequested = .clockDeviceDied
        }
    }

    /// Tears the capture graph down synchronously, from any thread. Idempotent.
    ///
    /// This is what the signal handler calls. It deliberately does not touch actor state.
    public nonisolated func stop() {
        activeTap.withLock { $0 }?.teardown()
    }

    private func shutdown() {
        watcher?.stop()
        watcher = nil
        tap.teardown()
    }

    // MARK: - Audio consumer

    private func consumeAudio() async {
        while !Task.isCancelled {
            do {
                try await drainRing()
                try await advanceIdleTime()
            } catch {
                writer.emit(.warning(code: "feed_failed", detail: "\(error)"))
            }
            checkPendingTimeouts()
            checkCaptureHealth()
            checkSilentCapture()
            if writer.readerIsGone { return }
            if let reason = rebuildRequested {
                rebuildRequested = nil
                await rebuildCapture(reason: reason)
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func drainRing() async throws {
        while let peek = tap.ring.peekSegment() {
            if peek.frameCount > scratch.count {
                scratch = [Float](repeating: 0, count: peek.frameCount * 2)
            }
            let segment: AudioSegment? = scratch.withUnsafeMutableBufferPointer {
                tap.ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
            }
            guard let segment else { return }

            let timing = clock.admit(
                hostTime: segment.hostTime == 0 ? nil : segment.hostTime,
                frameCount: Int64(segment.frameCount)
            )
            anchorTimelineIfNeeded(segment.hostTime)
            // Recorded before the pause check: while paused, buffers really are arriving, so
            // the stall watchdog must not read a deliberate pause as a dead capture graph
            // and rebuild the aggregate underneath it.
            lastBufferHostTime = segment.hostTime == 0 ? HostClock.now() : segment.hostTime
            warnedNoBuffers = false
            consecutiveRebuilds = 0

            // Tracked before the pause check: a pause is silence by request, and counting it
            // would report the user's own mute as a broken tap.
            if !control.tapPaused {
                scratch.withUnsafeBufferPointer { buffer in
                    for i in 0..<segment.frameCount {
                        let magnitude = abs(buffer[i])
                        if magnitude > loudestSample { loudestSample = magnitude }
                    }
                }
            }

            if control.tapPaused {
                // Discarded before the endpointer or the transcriber sees it: paused means
                // not transcribed, not held and not sent — not merely hidden from the page.
                if !wasPaused {
                    wasPaused = true
                    writer.emit(.status(
                        state: "control", format: nil, detail: control.stateDescription))
                    if let now = streamSecondsNow() {
                        var pending: [EndpointerEvent] = []
                        endpointer.flush(at: now) { pending.append($0) }
                        for event in pending { await handle(event) }
                    }
                }
                continue
            }
            if wasPaused {
                wasPaused = false
                writer.emit(.status(
                    state: "control", format: nil, detail: control.stateDescription))
            }

            let start = timelineOffset + timing.streamSeconds
            if timing.didResync, timing.gapSeconds > 0.1 {
                writer.emit(.warning(
                    code: "capture_gap",
                    detail: String(format: "%.2f s with no buffers; timeline advanced", timing.gapSeconds)
                ))
            }

            // Endpointing reads the raw Float32 capture directly: computing it from the
            // resampled Int16 stream would put the sample-rate converter's roll-off, and a
            // scaling factor, between the microphone and the decision.
            var events: [EndpointerEvent] = []
            scratch.withUnsafeBufferPointer { buffer in
                endpointer.push(
                    UnsafeBufferPointer(rebasing: buffer[0..<segment.frameCount]),
                    startTime: start, sampleRate: tap.format.sampleRate
                ) { events.append($0) }
            }

            if let transcriber {
                // Keep the analyser's timeline aligned with the capture clock before
                // feeding, so a gap stays a gap rather than being silently compressed.
                try await transcriber.advance(toStreamSeconds: start)
                try await transcriber.feed(Array(scratch[0..<segment.frameCount]))
            }
            for event in events { await handle(event) }

            if configuration.debugVAD {
                writer.emit(.metric(name: "vad_db", value: endpointer.lastLevelDB, unit: "dBFS"))
            }
        }
    }

    /// Advances both the endpointer and the analyser through wall-clock silence.
    ///
    /// This is what makes the design survive a tap that stops delivering. Without it the
    /// hangover would freeze and the question would never be emitted; and because
    /// `finalize(through:)` does not return until input past its boundary is consumed, the
    /// finalise dispatched at the endpoint would never complete either.
    private func advanceIdleTime() async throws {
        guard let now = streamSecondsNow() else { return }
        // Only ever advance through time the tap has certainly finished delivering.
        let settled = now - Self.deliveryLagAllowance
        guard settled > 0 else { return }

        var events: [EndpointerEvent] = []
        endpointer.idle(upTo: settled) { events.append($0) }
        for event in events { await handle(event) }

        if let transcriber, await settled - transcriber.cursorSeconds > Self.silenceThreshold {
            try await transcriber.advance(toStreamSeconds: settled)
        }
    }

    private func streamSecondsNow() -> Double? {
        guard let seconds = clock.streamSeconds(forHostTime: HostClock.now()) else { return nil }
        return timelineOffset + seconds
    }

    private func anchorTimelineIfNeeded(_ hostTime: UInt64) {
        guard hostTime != 0, let anchor = clock.anchorHostTime else { return }
        // Whichever source anchors first defines the origin; this one adopts it. When the
        // tap is alone that is its own first buffer, so the single-source timeline is
        // unchanged.
        let master = timeline.anchor(anchor)
        // After a rebuild the new clock re-anchors at zero. The offset restores continuity
        // against the original anchor so emitted timestamps never jump backwards — and it is
        // recomputed for each new anchor, not just the first.
        guard offsetComputedForAnchor != anchor else { return }
        offsetComputedForAnchor = anchor
        timelineOffset = Double(HostClock.nanos(
            fromSignedTicks: HostClock.delta(anchor, minus: master)
        )) / 1_000_000_000
    }

    // MARK: - Endpointer events

    private func handle(_ event: EndpointerEvent) async {
        switch event {
        case .speechStarted, .discarded:
            break
        case let .endpoint(endpoint):
            // Registered *before* the finalise is requested. The call below suspends this
            // actor, and a final arriving in that window with nothing pending would be
            // filed away and only surface on the 2.5 s timeout.
            assembler.endpointDetected(endpoint, now: Self.monotonicNow)
            // Dispatched, never awaited: `finalize(through:)` does not return until input
            // past its boundary has been consumed, so awaiting it on the task feeding audio
            // deadlocks the process outright.
            await transcriber?.finalize(throughStreamSeconds: endpoint.decisionTime)
        }
    }

    // MARK: - Transcript consumer

    private func handle(transcript: Transcriber.Transcript) {
        if transcript.isFinal {
            refreshTerms()
            let questions = assembler.finalArrived(
                start: transcript.start, end: transcript.end, text: transcript.text,
                now: Self.monotonicNow
            )
            reportDroppedQuestions()
            for question in questions {
                if question.usedVolatileFallback {
                    writer.emit(.warning(
                        code: "volatile_fallback",
                        detail: "the forced final for this region was empty; used volatile text"
                    ))
                }
                writer.emit(.question(question, speaker: configuration.speaker))
            }
        } else {
            assembler.volatileArrived(
                start: transcript.start, end: transcript.end, text: transcript.text
            )
            guard configuration.emitPartials else { return }
            let text = TextNormalizer.stripArtifacts(transcript.text)
            guard !text.isEmpty else { return }
            writer.emit(.partial(text: text, t: transcript.end, speaker: configuration.speaker))
        }
    }

    /// Picks up an edited `## Terms` section.
    ///
    /// Assigned rather than rebuilding the assembler: a rebuild would discard the pending
    /// questions and retained volatiles it is holding, losing whatever was mid-utterance
    /// at the moment the file was saved.
    private func refreshTerms() {
        guard let profiles = configuration.profiles else { return }
        let terms = profiles.current().terms
        if terms != assembler.terms { assembler.terms = terms }
    }

    /// The result sequence ending before shutdown means the analyser tore itself down. An
    /// overlapping input range does exactly this, and it ends transcription for the rest of
    /// the session rather than for one buffer — so it must be visible, not silent.
    private func noteTranscriberEnded() {
        guard !Task.isCancelled else { return }
        transcriberDied = true
        writer.emit(.warning(
            code: "transcriber_ended",
            detail: "the recogniser closed its result stream; no further questions will be emitted"
        ))
    }

    /// A boundary that produced no usable text leaves no `question` line. Without this it
    /// would also leave no trace at all, so a rehearsal counting warnings to tune the
    /// hangover would see a clean log while questions went missing.
    private func reportDroppedQuestions() {
        for endpoint in assembler.takeDropped() {
            writer.emit(.warning(
                code: "question_lost",
                detail: String(
                    format: "boundary at t0=%.2f t1=%.2f produced no usable text",
                    endpoint.speechStart, endpoint.speechEnd
                )
            ))
        }
    }

    private func checkPendingTimeouts() {
        let timedOut = assembler.tick(now: Self.monotonicNow)
        reportDroppedQuestions()
        for question in timedOut {
            writer.emit(.warning(
                code: "final_timeout",
                detail: String(format: "no final within %.1f s of the endpoint", Self.finalTimeout)
            ))
            writer.emit(.question(question, speaker: configuration.speaker))
        }
    }

    /// Monotonic seconds, in the same clock domain as the capture timestamps.
    private static var monotonicNow: Double {
        Double(HostClock.nanos(fromTicks: HostClock.now())) / 1_000_000_000
    }

    // MARK: - Capture health

    /// What the watchdog should do about a silent tap.
    ///
    /// Pure, so the escalation can be asserted without a capture graph and a four-minute
    /// wait — which is why the gap between "detected" and "recovered" went unnoticed.
    enum CaptureHealthAction: Equatable {
        case nothing
        case warn
        case rebuild
    }

    /// How long to wait before the next rebuild, given how many in a row have already
    /// changed nothing.
    ///
    /// A rebuild tears down a capture graph that might have been about to recover, so
    /// retrying at a fixed interval forever is its own failure mode when the cause is
    /// permanent — permission revoked mid-session, an interface unplugged. Doubling keeps
    /// the first recovery fast while making a hopeless one cheap.
    static func rebuildThreshold(
        base: Double, consecutiveRebuilds: Int, maximum: Double
    ) -> Double {
        guard consecutiveRebuilds > 0 else { return base }
        // Clamped before the shift: an unbounded exponent overflows to infinity, which would
        // silently disable retrying altogether — the very failure this is here to prevent.
        let exponent = Double(min(consecutiveRebuilds, 16))
        return min(base * pow(2, exponent), maximum)
    }

    static func captureHealthAction(
        idleSeconds: Double,
        alive: Bool,
        registered: Bool,
        alreadyWarned: Bool,
        consecutiveRebuilds: Int = 0,
        warnAfter: Double = Pipeline.noBufferWarningSeconds,
        rebuildAfter: Double = Pipeline.noBufferRebuildSeconds,
        maximumInterval: Double = Pipeline.maximumRebuildInterval
    ) -> CaptureHealthAction {
        // Below the warning window nothing is wrong yet, however the probes look: the tap is
        // silent by design whenever the tapped device is not clocking.
        guard idleSeconds > warnAfter else { return .nothing }

        // Visibly broken: rebuild as soon as it is noticed — but still backed off, or a dead
        // device would be rebuilt every 90 seconds for the rest of the session.
        if !alive || !registered {
            let threshold = rebuildThreshold(
                base: warnAfter, consecutiveRebuilds: consecutiveRebuilds, maximum: maximumInterval
            )
            return idleSeconds > threshold ? .rebuild : .nothing
        }

        // Alive, registered, and still nothing. Not a quiet room — a stalled graph.
        let threshold = rebuildThreshold(
            base: rebuildAfter, consecutiveRebuilds: consecutiveRebuilds, maximum: maximumInterval
        )
        if idleSeconds > threshold { return .rebuild }
        return alreadyWarned ? .nothing : .warn
    }

    /// Whether to report a tap that is clocking but carrying nothing.
    ///
    /// `no_audio` asks whether buffers are arriving, and cannot see the failure where they
    /// are — timeline advancing, watchdog satisfied — while every sample in them is silence.
    /// Pure, so the window and floor can be asserted without waiting two minutes.
    static func shouldWarnSilentCapture(
        loudestDB: Double,
        secondsSinceStart: Double,
        alreadyWarned: Bool,
        floorDB: Double = -60,
        afterSeconds: Double = 120
    ) -> Bool {
        guard !alreadyWarned, secondsSinceStart > afterSeconds else { return false }
        return loudestDB < floorDB
    }

    private func checkCaptureHealth() {
        guard let last = lastBufferHostTime else { return }
        let idle = Double(HostClock.nanos(
            fromSignedTicks: HostClock.delta(HostClock.now(), minus: last)
        )) / 1_000_000_000

        // Probed every poll rather than once: latching the warning also latched the only
        // path to recovery, so a stall detected at 90 s was never re-examined again.
        let alive = AudioProperty.isAlive(tap.clockDeviceID)
        let registered = tap.ioProcStillRegistered
        let action = Self.captureHealthAction(
            idleSeconds: idle, alive: alive, registered: registered,
            alreadyWarned: warnedNoBuffers, consecutiveRebuilds: consecutiveRebuilds
        )

        switch action {
        case .nothing:
            return
        case .warn:
            warnedNoBuffers = true
            writer.emit(.warning(
                code: "no_audio",
                detail: "no buffers for \(Int(idle))s; deviceAlive=\(alive) ioProcRegistered=\(registered)"
            ))
        case .rebuild:
            warnedNoBuffers = true
            writer.emit(.warning(
                code: "no_audio",
                detail: "no buffers for \(Int(idle))s; deviceAlive=\(alive) "
                    + "ioProcRegistered=\(registered); rebuilding"
            ))
            rebuildRequested = .noBuffers
        }
    }

    /// Reports a tap that clocks but carries no audio.
    ///
    /// The signature of an output route the tap can no longer follow — opening a Bluetooth
    /// headset's microphone switches the link to duplex and does exactly this. Everything
    /// else looks healthy, which is why it needs saying out loud.
    private func checkSilentCapture() {
        let loudest = 20 * log10(Double(max(loudestSample, 1e-9)))
        guard Self.shouldWarnSilentCapture(
            loudestDB: loudest,
            secondsSinceStart: captureStarted.elapsedSeconds,
            alreadyWarned: warnedSilentCapture
        ) else { return }
        warnedSilentCapture = true
        writer.emit(.warning(
            code: "silent_capture",
            detail: "buffers are arriving but every sample has been silence. The tapped "
                + "device may not be rendering, or the audio route changed underneath the "
                + "tap — opening a Bluetooth headset's microphone does this."
        ))
    }

    private func rebuildCapture(reason: RebuildReason) async {
        consecutiveRebuilds += 1
        writer.emit(.warning(
            code: "rebuilding",
            detail: "capture graph rebuild: \(reason.rawValue) (attempt \(consecutiveRebuilds))"
        ))

        if let now = streamSecondsNow() {
            var events: [EndpointerEvent] = []
            endpointer.flush(at: now) { events.append($0) }
            for event in events { await handle(event) }
        }
        watcher?.stop()
        tap.teardown()

        tap = SystemAudioTap(configuration: configuration.tap)
        do {
            try startCapture()
            writer.emit(.status(
                state: "capturing",
                format: StreamFormat(rate: tap.format.sampleRate, ch: Int(tap.format.channelCount)),
                detail: "rebuilt after \(reason.rawValue)"
            ))
            // Re-arm rather than clear: `nil` disables checkCaptureHealth entirely, so a
            // rebuilt graph that never delivers a buffer would go unnoticed for the rest of
            // the interview — which is the exact failure a rebuild is responding to.
            lastBufferHostTime = HostClock.now()
            warnedNoBuffers = false
            // The watcher was torn down and rebuilt around this; a device change arriving in
            // that window reached no listener. Re-check against reality rather than trusting
            // that nothing moved.
            if let current = AudioCatalog.defaultOutputDevice(), current != tap.clockDeviceID {
                rebuildRequested = .defaultOutputDeviceChanged
            }
        } catch {
            // Reset the watchdog state so the next 90 s window retries. Leaving it latched
            // would mean one failed rebuild ends capture for the rest of the interview,
            // silently.
            writer.emit(Self.rebuildFailedEvent(detail: "\(error)"))
            lastBufferHostTime = HostClock.now()
            warnedNoBuffers = false
        }
    }

    /// What a rebuild that failed says about itself.
    ///
    /// A warning, not an error. `error` means the binary is about to exit non-zero, and this
    /// path does the opposite: it re-arms the watchdog and retries. Reported as an error it
    /// turned the page's status pill red over a session that was still running. Pure, so the
    /// contract can be asserted without a capture graph.
    static func rebuildFailedEvent(detail: String) -> Event {
        .warning(code: "rebuild_failed", detail: detail)
    }
}
