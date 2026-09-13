import Foundation
import WngmnAudio
import WngmnCore
import WngmnAsk
import WngmnServe

@main
struct Wngmn {
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            EventWriter.note("wngmn: \(error)")
            EventWriter.note("try `wngmn --help`")
            exit(2)
        }

        if options.command == .help {
            print(Options.usage)
            exit(0)
        }

        // Created before the server, which needs it to serve the control route.
        let control = CaptureControl(micMuted: false, tapPaused: options.startPaused)

        // Started before the capture graph: if the port is taken, the user should find out
        // now rather than after the interview has begun.
        // One source for the whole process: the answer path reads Style and Context from
        // it, the capture paths read Terms. Two sources would mean one file with two
        // versions of itself in force at once.
        let profiles = loadProfile(options)
        let server = startServerIfRequested(options, control: control, profiles: profiles)
        let writer = EventWriter(
            // Speech still being spoken goes to open pages but is never retained: it is
            // superseded within the second, and remembering it evicts the questions a
            // reconnecting page actually needs from the replay buffer.
            observer: server.map { server in
                { @Sendable event, line in
                    if event.isReplayable { server.broadcast(line) } else { server.broadcastLive(line) }
                }
            }
        )

        var terms = TermList.empty
        let termsURL = options.resolvedTermsURL
        if options.termsPath != nil, !FileManager.default.fileExists(atPath: termsURL.path) {
            // Silence here would mean jargon correction is simply off for the whole
            // interview, with the user believing their term list is loaded.
            EventWriter.note("wngmn: --terms \(termsURL.path) does not exist; jargon correction is OFF")
        } else {
            do {
                terms = try TermList.load(from: termsURL)
                if options.termsPath != nil, terms.isEmpty {
                    EventWriter.note("wngmn: \(termsURL.path) contains no usable terms")
                }
            } catch {
                EventWriter.note("wngmn: could not read \(termsURL.path): \(error)")
            }
        }

        // A profile's own vocabulary wins over the global list: an investor call and a
        // technical one mangle different words, and the whole point of a profile is that
        // switching domains switches everything about it, jargon included.
        let profileTerms = profiles.current().terms
        if !profileTerms.isEmpty {
            terms = profileTerms
            EventWriter.note("wngmn: using \(profileTerms.terms.count) term(s) from the profile")
        }

        // One idempotent cleanup path for normal exit and for signals alike. atexit alone
        // does not run on SIGTERM, which would leak the private aggregate device on every
        // Ctrl-C.
        let teardown = TeardownCoordinator { _ in exit(130) }
        teardown.installSignalHandlers()
        if let server { teardown.onTeardown { server.stop() } }

        do {
            switch options.command {
            case .run:
                try await runCapture(
                    options: options, terms: terms, writer: writer,
                    teardown: teardown, control: control, profiles: profiles)
            case .selftest:
                let passed = await Selftest.run(options: options, writer: writer, teardown: teardown)
                exit(passed ? 0 : 1)
            case .devices:
                Devices.print(options: options)
            case .stop:
                await stopOtherSessions()
            case .miccheck:
                exit(await MicCheck.run(options: options, writer: writer) ? 0 : 1)
            case .offline:
                try await runOffline(options: options, terms: terms, writer: writer)
            case .installModel:
                try await installModel(options: options)
            case .help:
                break
            }
        } catch {
            writer.emit(.error(code: "fatal", detail: "\(error)"))
            EventWriter.note("wngmn: \(error)")
            teardown.run()
            exit(1)
        }
        teardown.run()
    }

    private static func logDirectory(_ options: Options) -> URL {
        if let path = options.logDirectory { return URL(fileURLWithPath: path) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("wngmn", isDirectory: true)
    }

    /// The session log, or nil when it is off or could not be opened.
    ///
    /// A log that will not open is reported and then dropped rather than fatal. Losing the
    /// record of a call is a real cost; refusing to transcribe it at all because a disk is
    /// full is a larger one, and the pages still receive everything live either way.
    private static func openLog(_ options: Options) -> EventLog? {
        guard options.writeLog else { return nil }
        do {
            return try EventLog(
                directory: logDirectory(options),
                resuming: options.resumeLog,
                restoreLimit: TranscriptServer.backlogLimit
            )
        } catch {
            EventWriter.note("wngmn: cannot write the transcript log: \(error)")
            if options.resumeLog {
                // Dropped along with the log, so it has to be said. The remedy printed below
                // is about silencing the warning, which is the opposite of what someone who
                // asked to recover a transcript is trying to do.
                EventWriter.note(
                    "wngmn: --resume cannot be honoured without the log, so this run starts empty"
                )
            }
            EventWriter.note("wngmn: continuing without it; --no-log silences this")
            return nil
        }
    }

    /// Returns nil when `--serve` was not asked for. A failure to bind exits rather than
    /// continuing quietly: the user asked to read the transcript in a browser, and a run
    /// that transcribes to a page nobody can open is not what they wanted.
    private static func startServerIfRequested(
        _ options: Options, control: CaptureControl, profiles: ProfileSource
    ) -> TranscriptServer? {
        guard options.serve else { return nil }
        let log = openLog(options)
        // Decided now, written after the bind. See TokenStore.plan.
        let tokenPlan = options.serveOnLAN ? resolveTokenPlan(options) : nil
        let server = TranscriptServer(configuration: .init(
            port: options.servePort,
            listenOnLAN: options.serveOnLAN,
            token: tokenPlan?.value,
            onAsk: askHandler(options: options, profiles: profiles),
            onControl: controlHandler(control: control),
            log: log,
            hangoverMilliseconds: options.endpointer.hangoverMs
        ))
        do {
            try server.start()
        } catch {
            // The log is opened before the bind is attempted, so it has to be taken back when
            // the bind fails — otherwise every failed start leaves a zero-byte session with
            // the newest name, standing in front of the transcript --resume is meant to find.
            log?.discardIfEmpty()
            EventWriter.note("wngmn: cannot serve on port \(options.servePort): \(error)")
            EventWriter.note("wngmn: another wngmn may already be running; try --port")
            exit(2)
        }
        // The port is ours, so a `--new-token` rotation can be made permanent. Before the bind
        // it was only a value in memory: a run that could not serve leaves the bookmarked token
        // exactly as it was.
        if let tokenPlan {
            do {
                if try TokenStore().commit(tokenPlan) {
                    EventWriter.note(
                        "wngmn: new token stored; previously bookmarked URLs no longer work"
                    )
                }
            } catch {
                EventWriter.note(
                    "wngmn: serving with a new token, but it could not be stored (\(error));"
                    + " the next run will go back to the previous one"
                )
            }
        }
        if let log {
            if !log.restored.isEmpty {
                EventWriter.note(
                    "wngmn: resumed \(log.restored.count) event(s) from \(log.url.path)"
                )
            } else if options.resumeLog {
                // Said plainly rather than reported as an ordinary start. A --resume that
                // found nothing used to print the same line as a fresh run, so an empty
                // session file left by a short-lived earlier invocation looked exactly like a
                // transcript that had been picked back up.
                EventWriter.note(
                    "wngmn: --resume found nothing to continue; starting a new transcript"
                )
                EventWriter.note("wngmn: transcript → \(log.url.path)")
            } else {
                EventWriter.note("wngmn: transcript → \(log.url.path)")
                // Offered only when there is in fact something to resume, so the line is
                // never advice about a file that does not exist.
                if EventLog.previousSession(in: logDirectory(options), excluding: log.url) != nil {
                    EventWriter.note("wngmn: an earlier session is on disk; --resume continues it instead")
                }
            }
        }
        if Credentials.resolveIncludingCLI() == nil {
            EventWriter.note("wngmn: no Anthropic credentials, so Ask will fail on every question.")
            EventWriter.note("wngmn: set ANTHROPIC_API_KEY, or run `ant auth login`, before the call.")
        }
        EventWriter.note("wngmn: live transcript → \(server.url)")
        // Listed second but the one worth writing down: it survives changing networks.
        if let byName = server.localHostnameURL {
            EventWriter.note("wngmn:                    → \(byName)   (same page, stable name)")
        }
        if options.serveOnLAN {
            EventWriter.note(
                "wngmn: this is reachable from your network. The token in that URL is the"
                + " only thing protecting the transcript. It is the same every run, so this"
                + " URL can be bookmarked; `--new-token` replaces it."
            )
            let fixed = options.serveToken
            if let fixed, fixed.isWeakToken {
                EventWriter.note(
                    "wngmn: WARNING '\(fixed)' is short enough to guess. Anyone on this"
                    + " network can read the transcript — including the other person's words."
                    + " Use a long --token on wifi you do not control."
                )
            }
        }
        return server
    }

    /// The token guarding the LAN-exposed transcript.
    ///
    /// An explicit `--token` wins. Otherwise a generated token is stored and reused, so the
    /// URL is stable enough to bookmark on a phone once while staying wide enough not to be
    /// guessed — about 40 bits, which is thousands of years against an unthrottled server on
    /// your own wifi. If the store cannot be written, a per-run 128-bit token is used rather
    /// than serving unprotected.
    private static func resolveTokenPlan(_ options: Options) -> TokenPlan {
        do {
            return try TokenStore().plan(fixed: options.serveToken, rotate: options.rotateToken)
        } catch {
            EventWriter.note(
                "wngmn: could not use the stored token (\(error)); generating a one-off token"
                + " for this run instead"
            )
            return .fixed(AccessToken.generate())
        }
    }

    /// Prepared material for answers. A missing file is reported rather than silently
    /// treated as empty: answering with no substance is exactly the failure the notes exist
    /// to prevent, and it looks identical to answering well until you read the result.
    /// The active profile, reloading itself when its file changes.
    ///
    /// Reported loudly on the way in. Answering with no material looks identical to
    /// answering well right up until the answer is read aloud, so a missing file, a missing
    /// `## Style`, or a heading that is a typo all have to be said before the call starts —
    /// not discovered during it.
    private static func loadProfile(_ options: Options) -> ProfileSource {
        guard let value = options.profile else {
            return ProfileSource(profile: Profile(notes: loadNotes(options)))
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = Profile.resolve(value, relativeTo: directory)
        guard let profile = try? Profile.load(from: url) else {
            EventWriter.note("wngmn: --profile \(url.path) could not be read; answers will have no material")
            return ProfileSource(profile: .empty)
        }

        let title = profile.name.isEmpty ? url.lastPathComponent : profile.name
        let styleSize = profile.style.isEmpty ? "MISSING" : "\(profile.style.count) chars"
        EventWriter.note(
            "wngmn: profile \(title) — style \(styleSize), "
            + "context \(profile.context.count) chars, \(profile.terms.terms.count) term(s)"
        )
        if profile.style.isEmpty {
            EventWriter.note(
                "wngmn: this profile has no '## Style' section, so answers get no"
                + " formatting or grounding instructions at all."
            )
        }
        for heading in profile.unknownSections {
            EventWriter.note(
                "wngmn: profile section '## \(heading)' is not one of Style, Context or"
                + " Terms, so nothing in it is used"
            )
        }
        return ProfileSource(url: url, initial: profile) { name in
            EventWriter.note("wngmn: reloaded profile \(name)")
        }
    }

    private static func loadNotes(_ options: Options) -> String {
        guard let path = options.notesPath else { return "" }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            EventWriter.note("wngmn: --notes \(path) could not be read; answers will have no prepared material")
            return ""
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EventWriter.note("wngmn: --notes \(path) is empty")
        }
        return text
    }

    /// Applies a capture-control change from the page.
    ///
    /// Only the flags are set here. The `control` status line is emitted by whichever
    /// capture path actually stops or starts, so the transcript records what the machine
    /// did rather than what the page asked for.
    private static func controlHandler(control: CaptureControl) -> ControlHandler {
        { payload in
            let update = try ControlRequest.parse(payload)
            if let muted = update.micMuted { control.setMicMuted(muted) }
            if let paused = update.tapPaused { control.setTapPaused(paused) }
            return #"{"mic":"\#(control.micMuted ? "muted" : "live")","#
                + #""tap":"\#(control.tapPaused ? "paused" : "listening")"}"#
        }
    }

    /// Answers one question from the served page.
    ///
    /// Credentials are resolved per request rather than at startup, so a missing key is
    /// reported on the page when you press the button — with the reason — instead of
    /// silently disabling the button before the interview starts.
    private static func askHandler(options: Options, profiles: ProfileSource) -> AskHandler {
        { payload, emit in
            // Returned rather than dropped, so the server can cancel it if the question is
            // revised before the answer finishes. Cancellation reaches `URLSession`, which
            // ends the stream, and the catch below reports it as any other failure — which
            // the server discards, having already moved on.
            Task {
                do {
                    guard let credentials = Credentials.resolveIncludingCLI() else {
                        throw ClaudeClient.Failure.noCredentials
                    }
                    let (question, recent) = try parseAskPayload(payload)
                    var configuration = ClaudeClient.Configuration()
                    configuration.model = options.askModel
                    configuration.effort = options.askEffort
                    try await ClaudeClient(configuration: configuration).stream(
                        // Read per request, so an edit to the file lands on the next Ask.
                        prompt: AnswerPrompt.build(
                            question: question, recent: recent, profile: profiles.current()),
                        credentials: credentials,
                        // Reported rather than assumed. A cache invalidated by something
                        // upstream produces a request that looks identical and costs full
                        // price, so the only way to know it is working is to watch this
                        // go from `created` on the first ask to `read` on every later one.
                        onUsage: { input, created, read in
                            EventWriter.note(
                                "wngmn: prompt cache — \(read) read, \(created) written, "
                                + "\(input) uncached"
                            )
                        },
                        onTruncated: { emit(.truncated) }
                    ) { text in emit(.text(text)) }
                    emit(.done)
                } catch {
                    emit(.failed("\(error)"))
                }
            }
        }
    }

    private static func parseAskPayload(_ payload: String) throws -> (String, [String]) {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let question = root["question"] as? String,
              !question.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw AskPayloadError.malformed }
        return (question, root["recent"] as? [String] ?? [])
    }

    private enum AskPayloadError: Error, CustomStringConvertible {
        case malformed
        var description: String { "the page sent a request with no question in it" }
    }

    /// Signals every other wngmn on this machine and clears what they leave behind.
    ///
    /// SIGTERM rather than SIGKILL: the teardown coordinator is installed for it, and it is
    /// what releases the private aggregate device. A process that ignores it gets SIGKILL
    /// afterwards, and the aggregate it orphans is swept up at the end — which is also why
    /// the sweep runs even when nothing was found to stop.
    private static func stopOtherSessions() async {
        let own = ProcessInfo.processInfo.processIdentifier
        let targets = RunningProcesses.stoppable(RunningProcesses.all(), excluding: own)

        if targets.isEmpty {
            EventWriter.note("wngmn: no other wngmn is running")
        } else {
            for pid in targets {
                EventWriter.note("wngmn: stopping pid \(pid)")
                kill(pid, SIGTERM)
            }
            // Long enough for teardown to release the aggregate, short enough that this
            // still feels like a command rather than a wait.
            let deadline = Date().addingTimeInterval(3)
            var remaining = targets
            while !remaining.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                remaining = remaining.filter { kill($0, 0) == 0 }
            }
            for pid in remaining {
                EventWriter.note("wngmn: pid \(pid) ignored SIGTERM; killing it")
                kill(pid, SIGKILL)
            }
            EventWriter.note("wngmn: stopped \(targets.count - remaining.count) of \(targets.count) cleanly")
        }

        // Always, not only when something was stopped: the leak this clears is left by runs
        // that were killed rather than asked to stop, which are exactly the ones already
        // gone by the time anyone thinks to run this.
        let swept = SystemAudioTap.sweepLeakedAggregates()
        EventWriter.note(
            swept == 0
                ? "wngmn: no leaked audio devices"
                : "wngmn: removed \(swept) leaked aggregate device(s)"
        )
    }

    private static func runCapture(
        options: Options, terms: TermList, writer: EventWriter,
        teardown: TeardownCoordinator, control: CaptureControl, profiles: ProfileSource
    ) async throws {
        var tapConfiguration = SystemAudioTap.Configuration()
        tapConfiguration.bundleIDs = options.bundleIDs
        tapConfiguration.globalTap = options.globalTap
        tapConfiguration.keepOutputAlive = options.keepOutputAlive

        var transcriberConfiguration = Transcriber.Configuration()
        transcriberConfiguration.locale = options.locale
        transcriberConfiguration.fastResults = options.fastResults
        // Always request volatile results, even when partial lines are suppressed: they are
        // the fallback when a forced final comes back empty.
        transcriberConfiguration.volatileResults = true

        // Shared by both capture sources so their timestamps have one origin.
        let timeline = CaptureTimeline()

        let pipeline = Pipeline(
            configuration: Pipeline.Configuration(
                tap: tapConfiguration,
                transcriber: transcriberConfiguration,
                endpointer: options.endpointer,
                terms: terms,
                emitPartials: options.emitPartials,
                debugVAD: options.debugVAD,
                // Labelled only when there is another source to be distinguished from.
                speaker: options.mic ? .caller : nil,
                profiles: profiles
            ),
            writer: writer,
            timeline: timeline,
            control: control
        )
        // Synchronous: a Task here would lose the race against exit().
        teardown.onTeardown { pipeline.stop() }

        guard options.mic else {
            warnIfRouteBreaksTap()
            try await pipeline.run()
            return
        }

        warnIfNotOnHeadphones()
        warnIfRouteBreaksTap()
        let mic = MicSource(
            configuration: MicSource.Configuration(
                capture: MicCapture.Configuration(deviceUID: options.micDeviceUID),
                transcriber: transcriberConfiguration,
                endpointer: options.micEndpointer,
                terms: terms,
                emitPartials: options.emitPartials,
                profiles: profiles
            ),
            writer: writer,
            timeline: timeline,
            control: control
        )
        teardown.onTeardown { mic.stop() }

        // The caller's half is the one that matters: if the microphone cannot be opened —
        // no input device, permission denied, an unplugged interface — that is reported and
        // the call is still transcribed, rather than the whole run failing over the half
        // that is a convenience.
        // Tagged rather than `Void`, and awaited until the *pipeline* task reports, not
        // until the first task does. `group.next()` returns whichever finishes first, and a
        // microphone that cannot be opened fails immediately — which cancelled the capture
        // graph and ended the run over the half that is only a convenience. Observed with a
        // disconnected Bluetooth headset: `mic_failed`, then `stopped`, and no transcript.
        enum Finished: Sendable { case pipeline, mic }
        try await withThrowingTaskGroup(of: Finished.self) { group in
            group.addTask {
                try await pipeline.run()
                return .pipeline
            }
            group.addTask {
                do {
                    try await mic.run()
                } catch {
                    writer.emit(.warning(code: "mic_failed", detail: "\(error)"))
                    EventWriter.note("wngmn: microphone capture failed: \(error)")
                    EventWriter.note("wngmn: continuing with the call audio only.")
                }
                return .mic
            }
            for try await finished in group where finished == .pipeline { break }
            group.cancelAll()
        }
    }

    /// The mic is assumed to be hearing only you. On speakers it also hears the caller, and
    /// the same sentence arrives twice under both labels — which reads as the caller
    /// stuttering rather than as a configuration mistake, so it is worth saying up front.
    /// The route that silently removes the caller from the transcript.
    ///
    /// Said at startup and again in `devices`, because the symptom gives nothing away: the
    /// tap keeps clocking, latency looks fine, and only the caller's lines are missing.
    /// Checked against the system default input, not wngmn's own device, since the call
    /// app opens a microphone too — Zoom pointed at the headset breaks the tap whatever
    /// wngmn was told to use.
    static func warnIfRouteBreaksTap() {
        guard let headset = AudioRoute.conflict() else { return }
        EventWriter.note(
            "wngmn: WARNING '\(headset)' is both your output and your input. Using a"
            + " Bluetooth headset's microphone switches the link to duplex, and while it is"
            + " there the tap captures NOTHING — the caller will be missing from the"
            + " transcript entirely, with no error."
        )
        EventWriter.note(
            "wngmn: set the microphone to something else — in System Settings AND in"
            + " Zoom, which opens its own — e.g. MacBook Pro Microphone. You can keep"
            + " listening through the headset."
        )
    }

    private static func warnIfNotOnHeadphones() {
        guard let output = AudioCatalog.defaultOutputDevice() else { return }
        let name = AudioCatalog.deviceName(output)
        let soundsLikeHeadphones = ["headphone", "airpod", "earbud", "headset", "buds"]
            .contains { name.lowercased().contains($0) }
        guard !soundsLikeHeadphones else { return }
        EventWriter.note(
            "wngmn: output is '\(name)', which does not look like headphones — if the "
            + "caller is audible through it, your mic will hear them too and their words "
            + "will appear under both Caller and You."
        )
    }

    private static func runOffline(
        options: Options, terms: TermList, writer: EventWriter
    ) async throws {
        var transcriberConfiguration = Transcriber.Configuration()
        transcriberConfiguration.locale = options.locale
        transcriberConfiguration.fastResults = options.fastResults
        // Always request volatile results, even when partial lines are suppressed: they are
        // the fallback when a forced final comes back empty.
        transcriberConfiguration.volatileResults = true

        let runner = OfflineRunner(
            configuration: OfflineRunner.Configuration(
                transcriber: transcriberConfiguration,
                endpointer: options.endpointer,
                terms: terms,
                emitPartials: options.emitPartials,
                debugVAD: options.debugVAD,
                speed: options.offlineSpeed
            ),
            writer: writer
        )
        try await runner.run(url: URL(fileURLWithPath: options.inputPath ?? ""))
    }

    private static func installModel(options: Options) async throws {
        let installed = await Transcriber.installedLocaleIdentifiers()
        EventWriter.note("wngmn: installed locales: \(installed.joined(separator: ", "))")
        if await Transcriber.isModelInstalled(locale: options.locale) {
            EventWriter.note("wngmn: \(options.locale) is already installed; nothing to do.")
            return
        }
        guard let resolved = await Transcriber.resolvedLocale(options.locale) else {
            EventWriter.note("wngmn: \(options.locale) is not a supported locale.")
            exit(1)
        }
        EventWriter.note("wngmn: downloading the \(resolved.identifier) speech model…")
        try await Transcriber.installModel(locale: options.locale)
        let nowInstalled = await Transcriber.isModelInstalled(locale: options.locale)
        EventWriter.note("wngmn: \(options.locale) installed = \(nowInstalled)")
    }
}
