import Foundation

/// Parsed command line. Hand-rolled rather than pulling in swift-argument-parser, because a
/// stated success criterion is that setup on a clean machine needs no network fetch.
public struct Options: Sendable, Equatable {
    public enum Command: String, Sendable, Equatable {
        /// Capture, transcribe and emit questions. The default.
        case run
        /// Active probe: play a known tone and assert the tap hears it. The go/no-go gate,
        /// because a silent TCC denial returns `noErr` from every Core Audio call.
        case selftest
        /// Enumerate audio processes and devices. Used to resolve which bundle ID actually
        /// carries Meet audio, and to check for leaked private aggregate devices.
        case devices
        /// Run a WAV/AIFF file through the same endpointer and transcriber. Needs no audio
        /// permission, so golden-file tests run in any terminal.
        case offline
        /// Measure the room and the voice, and print the `--mic-open-db` to use. The
        /// threshold fails invisibly in both directions, so it needs an instrument.
        case miccheck
        /// Signal every other wngmn on this machine to shut down, then clear anything
        /// they left behind. A capture graph outliving its run holds the audio device and
        /// the port.
        case stop
        /// Download the speech model for a locale. Explicit, because a 396 MB download is
        /// not something to start by accident an hour before an interview.
        case installModel = "install-model"
        case help
    }

    public var command: Command = .run
    /// Bundle IDs to scope the tap to. Chrome renders Meet audio from a helper process, so
    /// the helper is a candidate too; which entry actually carries the audio is resolved by
    /// `devices` and by rehearsal, not assumed.
    public var bundleIDs: [String] = [
        "us.zoom.xos", "us.zoom.CptHost", "us.zoom.caphost",
        "com.google.Chrome", "com.google.Chrome.helper",
    ]
    /// Tap everything instead of scoping by bundle ID. Picks up Slack dings and other tabs,
    /// so Do Not Disturb becomes mandatory.
    public var globalTap = false
    public var locale = "en-US"
    public var termsPath: String?
    public var inputPath: String?
    public var endpointer = EndpointerConfig()
    /// Capture the local microphone as a second source, so the transcript carries both
    /// halves of the conversation rather than only the caller's.
    ///
    /// Assumes headphones. On speakers the mic also hears the caller, and the same sentence
    /// is transcribed twice under both labels; `Pipeline` warns at startup if the default
    /// output looks like a speaker device.
    /// Begin without listening to the caller, so capture starts only when asked for.
    public var startPaused = false
    public var mic = false
    /// Device UID to capture from. Nil uses the default input.
    public var micDeviceUID: String?
    /// The mic's own endpointer. Your mouth is inches from the microphone while the caller
    /// arrives through the tap at conversational level, so a threshold tuned for one is
    /// wrong for the other. The default here is a starting point for rehearsal, not a
    /// measured value.
    public var micEndpointer: EndpointerConfig = {
        var config = EndpointerConfig()
        config.openThresholdDB = -35
        // Far shorter than the tap's 700 ms, because the two sources pause for opposite
        // reasons. The caller asks one question and hesitates inside it, so a gap is
        // usually the middle of a thought and stitching it back is right. You speak
        // several sentences in a row, so a gap is usually the end of one — and stitching
        // there merges them into a single row that keeps being rewritten, which reads as
        // the later sentences never arriving at all.
        config.mergeWindowMs = 250
        // Far longer than the tap's 250 ms, and it costs nothing. That 250 is spent buying
        // latency: the caller's question has to be on screen fast enough to answer. Your own
        // speech is never read back, so the only thing a longer wait affects is whether a
        // natural mid-sentence pause is mistaken for the end of the sentence. People pause
        // for half a second mid-thought routinely, and splitting there produces two half
        // lines out of one sentence.
        config.hangoverMs = 800
        return config
    }()
    /// `.fastResults` is documented as "faster but also less accurate". Latency now comes
    /// from `finalize(through:)` rather than from waiting on `isFinal`, so dropping it may
    /// cost nothing and improve jargon accuracy. A flag, to be settled in rehearsal.
    public var fastResults = true
    public var emitPartials = true
    /// Emit a `metric` line per VAD window. Very noisy; for threshold tuning only.
    public var debugVAD = false
    public var selftestSeconds: Double = 3
    /// Hold the tapped output device open with a silent IOProc.
    ///
    /// Without this the aggregate only clocks while something else happens to be playing:
    /// with the speakers idle, `AudioDeviceStart` returns `noErr` and the IOProc fires zero
    /// times, forever. On a live call Zoom is rendering anyway, so this is insurance
    /// against the failure looking like flakiness.
    public var keepOutputAlive = true
    /// Offline playback speed relative to real time.
    public var offlineSpeed: Double = 8
    /// Write the durable half of the transcript to disk as it happens.
    ///
    /// On by default: the replay buffer is in memory, so without this a wngmn that dies
    /// mid-interview comes back with nothing to tell the pages that reconnect to it.
    public var writeLog = true
    /// Continue the most recent session rather than starting one.
    ///
    /// Opt-in, because restarting is also how a *new* interview begins, and silently
    /// inheriting the previous one's questions would be worse than losing them.
    public var resumeLog = false
    /// Where sessions are kept. Nil means Application Support, next to the token.
    public var logDirectory: String?
    /// Serve the live transcript over HTTP so it can be read in a browser.
    public var serve = false
    public var servePort: UInt16 = 7373
    /// Bind every interface rather than loopback, so a phone or iPad can read the
    /// transcript. Reading on a second device is also the only way to be certain the
    /// transcript is not on screen if the call is ever screen-shared. It puts the
    /// transcript of a press interview on the wifi, so it is token-gated.
    public var serveOnLAN = false
    /// A fixed token, so one bookmarked URL keeps working across runs.
    ///
    /// Nil generates a fresh one per run, which is safer but means retyping 32 characters on
    /// a phone every session. A short token here is guessable by anyone on the network —
    /// `isWeakToken` is what the binary warns on.
    public var serveToken: String?
    /// Replace the stored token, invalidating every bookmarked URL.
    public var rotateToken = false
    /// Prepared material the answer should draw on. The whole point of the press-interview
    /// framing: substance supplied in advance, retrieved at the right moment.
    public var notesPath: String?
    /// The conversation domain: what to say, how to say it, and its jargon.
    ///
    /// A bare name resolves inside `profiles/`; anything path-shaped is taken as written.
    /// Supersedes `--notes`, which remains as a context-only shorthand.
    public var profile: String?
    public var askModel = "claude-opus-5"
    /// Latency is the binding constraint on a live call, so this defaults low rather than
    /// to the API's own default of `high`.
    public var askEffort = "low"

    /// The effort levels this model family accepts.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    public init() {}

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static func parse(_ arguments: [String]) throws -> Options {
        var o = Options()
        var args = arguments

        if let first = args.first, !first.hasPrefix("-") {
            guard let command = Command(rawValue: first) else {
                throw ParseError(
                    "unknown command '\(first)'; expected run, selftest, devices, miccheck, stop, offline or install-model"
                )
            }
            o.command = command
            args.removeFirst()
        }

        var explicitBundleIDs: [String] = []
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError("\(flag) requires a value") }
            let next = args[i]
            // A flag left without its value used to take the *following flag* as that value,
            // which silently dropped whatever that flag did: `--terms --no-log` wrote the
            // interview to disk despite being told not to, and the only trace was a stray
            // path inside an unrelated warning about the terms file.
            //
            // Keyed on the long-option prefix rather than on a leading minus, because every
            // dBFS threshold is a negative number and `--open-db -45` is not a mistake.
            // A leading "-" followed by a letter is a flag; a leading "-" followed by a
            // digit or a dot is a negative number, which every dBFS threshold is.
            let looksLikeFlag = next.hasPrefix("--")
                || (next.hasPrefix("-") && next.dropFirst().first.map { $0.isLetter } == true)
            guard !looksLikeFlag else {
                throw ParseError("\(flag) requires a value, but the next argument is \(next)")
            }
            return next
        }
        func number(_ flag: String) throws -> Double {
            let raw = try value(flag)
            // `Double("nan")` and `Double("inf")` both parse. Letting either through reaches
            // a `UInt64(...)` conversion that traps with no message.
            guard let v = Double(raw), v.isFinite else {
                throw ParseError("\(flag) expects a finite number, got '\(raw)'")
            }
            return v
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help": o.command = .help
            case "--bundle-id": explicitBundleIDs.append(try value(arg))
            case "--global": o.globalTap = true
            case "--locale": o.locale = try value(arg)
            case "--terms": o.termsPath = try value(arg)
            case "--hangover-ms": o.endpointer.hangoverMs = try number(arg)
            case "--onset-ms": o.endpointer.onsetMs = try number(arg)
            case "--min-speech-ms": o.endpointer.minSpeechMs = try number(arg)
            case "--max-speech-ms": o.endpointer.maxSpeechMs = try number(arg)
            case "--open-db": o.endpointer.openThresholdDB = try number(arg)
            case "--no-adaptive-floor": o.endpointer.adaptNoiseFloor = false
            // A token only means anything once the port is on the network, so asking for
            // one is asking to serve on it.
            case "--token":
                o.serveToken = try value(arg)
                o.serve = true
                o.serveOnLAN = true
            case "--new-token": o.rotateToken = true; o.serve = true; o.serveOnLAN = true
            case "--start-paused": o.startPaused = true; o.serve = true
            case "--mic": o.mic = true
            // Naming a device is an unambiguous request to capture from it.
            case "--mic-device": o.micDeviceUID = try value(arg); o.mic = true
            case "--mic-open-db": o.micEndpointer.openThresholdDB = try number(arg)
            case "--merge-ms": o.endpointer.mergeWindowMs = try number(arg)
            case "--mic-merge-ms": o.micEndpointer.mergeWindowMs = try number(arg)
            case "--mic-hangover-ms": o.micEndpointer.hangoverMs = try number(arg)
            case "--no-fast-results": o.fastResults = false
            case "--no-keepalive": o.keepOutputAlive = false
            case "--no-partials": o.emitPartials = false
            case "--debug-vad": o.debugVAD = true
            case "--seconds": o.selftestSeconds = try number(arg)
            case "--speed": o.offlineSpeed = try number(arg)
            case "--no-log": o.writeLog = false
            // Both imply --serve, as --port, --listen and --token do. The log exists to
            // catch a reconnecting page up, so without a server these were silent no-ops:
            // no file, nothing restored, and nothing said about either.
            case "--resume": o.resumeLog = true; o.serve = true
            case "--log-dir": o.logDirectory = try value(arg); o.serve = true
            case "--serve": o.serve = true
            case "--notes": o.notesPath = try value(arg)
            case "--profile": o.profile = try value(arg)
            case "--ask-model": o.askModel = try value(arg)
            case "--ask-effort":
                let level = try value(arg)
                // Rejected here rather than by the API, which would answer with a 400 in
                // the middle of an interview.
                guard Options.effortLevels.contains(level) else {
                    throw ParseError(
                        "--ask-effort expects one of \(Options.effortLevels.joined(separator: ", "));"
                        + " got '\(level)'"
                    )
                }
                o.askEffort = level
            case "--listen": o.serve = true; o.serveOnLAN = true
            case "--port":
                let raw = try value(arg)
                // Converting out of range wraps: 65536 becomes 0, the OS then picks a
                // random port, and the URL printed to the user is wrong.
                guard let p = UInt16(raw), p > 0 else {
                    throw ParseError("--port expects 1–65535, got '\(raw)'")
                }
                o.servePort = p
                o.serve = true
            default:
                if arg.hasPrefix("-") { throw ParseError("unknown option '\(arg)'") }
                if o.command == .offline, o.inputPath == nil { o.inputPath = arg }
                else { throw ParseError("unexpected argument '\(arg)'") }
            }
            i += 1
        }

        if !explicitBundleIDs.isEmpty { o.bundleIDs = explicitBundleIDs }
        if o.command == .offline, o.inputPath == nil {
            throw ParseError("offline requires an audio file path")
        }
        if o.endpointer.hangoverMs <= 0 { throw ParseError("--hangover-ms must be positive") }
        if o.micEndpointer.hangoverMs <= 0 {
            throw ParseError("--mic-hangover-ms must be positive")
        }
        if o.offlineSpeed <= 0 { throw ParseError("--speed must be positive") }
        if o.selftestSeconds <= 0 { throw ParseError("--seconds must be positive") }
        // dBFS is a level relative to full scale, so it is never positive. A dropped minus
        // sign would put the speech threshold above anything the tap can produce and no
        // question would ever be detected — silently, for the whole interview.
        if o.endpointer.onsetMs <= 0 { throw ParseError("--onset-ms must be positive") }
        if o.endpointer.minSpeechMs <= 0 { throw ParseError("--min-speech-ms must be positive") }
        // Before the relational check below, which would otherwise report a zero or negative
        // --max-speech-ms against --min-speech-ms — a flag the user need not have set, and a
        // remedy that cannot fix it.
        if o.endpointer.maxSpeechMs <= 0 { throw ParseError("--max-speech-ms must be positive") }
        if o.endpointer.maxSpeechMs < o.endpointer.minSpeechMs {
            throw ParseError("--max-speech-ms must be at least --min-speech-ms")
        }
        // Zero is rejected along with positives: an RMS level cannot reach 0 dBFS, so the
        // threshold would never be crossed and no question would ever be detected.
        // Zero is meaningful here — never stitch, every pause starts a new row — so unlike
        // the other durations it is allowed, and only a negative value is an error.
        for (label, value) in [
            ("--merge-ms", o.endpointer.mergeWindowMs),
            ("--mic-merge-ms", o.micEndpointer.mergeWindowMs),
        ] where value < 0 {
            throw ParseError("\(label) must be zero or positive (got \(value))")
        }
        if let token = o.serveToken {
            // Pasted straight into a query string: anything needing escaping would produce a
            // URL that silently fails to match rather than one that visibly breaks.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard !token.isEmpty, token.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ParseError(
                    "--token must be non-empty and use only letters, digits, - . _ ~ (got '\(token)')"
                )
            }
        }
        if o.micEndpointer.openThresholdDB >= 0 {
            throw ParseError(
                "--mic-open-db is dBFS and must be negative (got \(o.micEndpointer.openThresholdDB))"
            )
        }
        if let directory = o.logDirectory, directory.trimmingCharacters(in: .whitespaces).isEmpty {
            // `URL(fileURLWithPath: "")` is the current directory, so this quietly wrote the
            // interview transcript into whatever directory wngmn was launched from.
            throw ParseError("--log-dir needs a path")
        }
        if o.resumeLog, !o.writeLog {
            // Doing neither silently is how someone finds out mid-call that the transcript
            // they expected back never came back.
            throw ParseError("--resume needs the log, so it cannot be combined with --no-log")
        }
        if o.endpointer.openThresholdDB >= 0 {
            // Only suggest a sign flip when flipping the sign actually produces a legal
            // value. Prepending a minus unconditionally turned `--open-db 0` into the advice
            // `--0.0`, which is not even a flag, and sent the user round the same loop.
            let got = o.endpointer.openThresholdDB
            // The semicolon belongs to the hint, so it goes when the hint does — otherwise
            // the message trails off with a bare "…(got 0.0);".
            let hint = got > 0 ? "; did you mean -\(got)?" : ""
            throw ParseError("--open-db is dBFS and must be negative (got \(got))\(hint)")
        }
        return o
    }

    /// Resolved terms file. Defaults to `terms.txt` beside the working directory.
    public var resolvedTermsURL: URL {
        if let termsPath { return URL(fileURLWithPath: termsPath) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("terms.txt")
    }

    public static let usage = """
    wngmn — live interview teleprompter, stage 1 (capture + transcribe + endpoint)

    USAGE
      wngmn [run] [options]        capture conferencing audio, emit questions as JSON Lines
      wngmn selftest [options]     play a tone and assert the tap hears it (go/no-go gate)
      wngmn devices                list audio processes, devices and any leaked aggregates
      wngmn offline <file>         run a recorded file through the same pipeline
      wngmn install-model          download the speech model for --locale
      wngmn miccheck [options]     measure this room and this voice, print --mic-open-db
      wngmn stop                   stop every running wngmn and release its audio devices

    CAPTURE
      --bundle-id <id>       scope the tap to this app; repeatable. Replaces the default list,
                             which covers Zoom (xos, CptHost, caphost) and Chrome (browser and
                             helper) — neither renders call audio from the obvious process.
      --global               tap everything instead of scoping by bundle ID
      --no-keepalive         do not hold the output device open with a silent IOProc
                             (the tap only clocks while that device is running)

    ENDPOINTING
      --hangover-ms <n>      silence before a question is considered over (default 250)
      --onset-ms <n>         speech before a question is considered started (default 80)
      --min-speech-ms <n>    shorter utterances are discarded as blips (default 350)
      --max-speech-ms <n>    force an endpoint in a monologue (default 30000)
      --open-db <n>          absolute speech threshold in dBFS (default -45)
      --merge-ms <n>         continuation window for the caller in ms (default 700): a
                             pause shorter than this is a hesitation mid-question, and the
                             two halves are stitched into one line
      --no-adaptive-floor    do not track the ambient noise floor

    TRANSCRIPTION
      --locale <id>          speech locale (default en-US)
      --terms <path>         jargon correction list (default ./terms.txt)

    MICROPHONE  (the "You" half of the transcript)
      --token <value>        fixed access token, so one bookmarked URL keeps working across
                             runs instead of a new one each time. Implies --listen. A short
                             token is guessable by anyone on your network; the transcript
                             carries the other person's words too.
      --new-token            replace the stored token; every bookmarked URL stops working
      --start-paused         begin paused: the caller is not transcribed until you press
                             Listen on the page (or p). Capture controls are also on the
                             page as Mute and Pause.
      --mic                  also capture your microphone, so both sides of the call are
                             transcribed and each line is labelled Caller or You
      --mic-device <uid>     capture from this input device (default: system default
                             input); implies --mic
      --mic-open-db <n>      speech threshold for the mic in dBFS (default -35; louder
                             than the tap's, because your mouth is inches from it).
                             Run `wngmn miccheck` to measure the right value.
      --mic-hangover-ms <n>  silence before YOUR sentence is considered over (default 800,
                             far longer than the tap's 250: your own speech is never read
                             back, so waiting costs nothing, and a natural mid-sentence
                             pause under this no longer splits the line in two)
      --mic-merge-ms <n>     speech resuming within this long is treated as a continuation
                             of the same sentence rather than a new one (default 250, far
                             shorter than the tap's 700: consecutive sentences of your own
                             should be separate lines). 0 never stitches.

      Assumes headphones. On speakers the mic hears the caller too and the same sentence
      is transcribed twice, once under each label.
      --no-fast-results      drop .fastResults; slower per result, better on jargon

    OUTPUT
      --no-partials          suppress volatile "partial" lines
      --debug-vad            emit a metric line per VAD window (threshold tuning only)

    LIVE TRANSCRIPT
      --serve                serve the transcript at http://127.0.0.1:7373 — questions, the
                             live caption, latency against the budget, and warnings
      --port <n>             port for --serve (default 7373); implies --serve
      --listen               bind the network instead of loopback so a phone or iPad can
                             read it, with a token in the printed URL. Implies --serve
      --no-log               do not write the transcript to disk. The pages still get
                             everything live; nothing survives the process
      --resume               continue the most recent session instead of starting one, so a
                             wngmn that died mid-call comes back with its transcript
      --log-dir <path>       where sessions are kept (default: Application Support)

    ANSWERS  (the Ask button on the served page)
      --profile <name|path>  the conversation domain, as one markdown file: `## Style`
                             for how answers should be shaped, `## Context` for the
                             substance, `## Terms` for its jargon. A bare name resolves
                             to ./profiles/<name>.md. Re-read when it changes on disk, so
                             a profile can be edited mid-session.
      --notes <path>         prepared material to answer from; the substance you supply in
                             advance. Without it, answers have nothing but the question.
      --ask-model <id>       model for answers (default claude-opus-5)
      --ask-effort <level>   low, medium, high, xhigh or max (default low — latency is the
                             binding constraint on a live call)

      Credentials are read from ANTHROPIC_API_KEY, then ANTHROPIC_AUTH_TOKEN, then the
      profile written by `ant auth login`. Asking sends the question and the recent
      transcript to the Claude API; nothing is sent until you press the button.
      --seconds <n>          selftest duration (default 3)
      --speed <n>            offline playback speed vs real time (default 8); the recogniser
                             must keep up with the endpointer, so this is not free

    NOTES
      System Audio Recording is granted to the *terminal app*, not to this binary. Run from a
      terminal that holds the grant, and run `wngmn selftest` before every interview: a
      denial returns noErr from every Core Audio call and yields pure silence.
    """
}
