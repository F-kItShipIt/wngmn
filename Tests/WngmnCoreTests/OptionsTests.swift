import Testing
import Foundation
@testable import WngmnCore

@Suite("Options")
struct OptionsTests {
    @Test("Defaults match the design")
    func defaults() throws {
        let o = try Options.parse([])
        #expect(o.command == .run)
        #expect(o.endpointer.hangoverMs == 250)
        #expect(o.bundleIDs.contains("us.zoom.xos"))
        // Zoom renders the meeting itself from a separate host process, so scoping to the
        // app's own bundle ID captures nothing on a real call.
        #expect(o.bundleIDs.contains("us.zoom.CptHost"))
        #expect(o.bundleIDs.contains("us.zoom.caphost"))
        #expect(o.fastResults)
    }

    /// It used to hear Zoom and Chrome and nothing else, unless told `--global`. A call in
    /// Teams, FaceTime, Slack or Safari was silence with every status code reading success,
    /// and the README ended up putting `--global` on every command it printed — which is a
    /// default, spelled the long way.
    @Test("It hears whatever app the call is in, unless told which")
    func hearsEveryAppByDefault() throws {
        #expect(try Options.parse([]).globalTap)
        let named = try Options.parse(["--bundle-id", "com.example.a"])
        #expect(!named.globalTap, "naming an app is asking for that app")
        #expect(named.bundleIDs == ["com.example.a"])
        let calls = try Options.parse(["--call-apps"])
        #expect(!calls.globalTap)
        #expect(calls.bundleIDs.contains("us.zoom.CptHost") && calls.bundleIDs.contains("com.google.Chrome.helper"))
        #expect(Options.usage.contains("--call-apps"))
    }

    @Test("A run says what it is listening to, and how to make that less")
    func listeningNote() throws {
        let everything = try Options.parse([]).listeningNote
        #expect(everything.contains("everything this Mac plays") && everything.contains("--call-apps"))
        #expect(everything.contains("your microphone") && everything.contains("--no-mic"))
        let narrow = try Options.parse(["--bundle-id", "com.example.a", "--no-mic"]).listeningNote
        #expect(narrow.contains("only com.example.a") && narrow.contains("microphone is off"))
    }

    /// Commands written for 0.3 still mean what they meant.
    @Test("--global is still accepted, and still wins over a named app")
    func globalStillParses() throws {
        #expect(try Options.parse(["--global"]).globalTap)
        #expect(try Options.parse(["--global", "--bundle-id", "com.example.a"]).globalTap)
        #expect(try Options.parse(["--bundle-id", "com.example.a", "--global"]).globalTap)
    }

    @Test("Commands and their options parse together")
    func commands() throws {
        #expect(try Options.parse(["selftest", "--seconds", "5"]).command == .selftest)
        #expect(try Options.parse(["devices"]).command == .devices)
        let offline = try Options.parse(["offline", "clip.wav", "--hangover-ms", "400"])
        #expect(offline.command == .offline)
        #expect(offline.inputPath == "clip.wav")
        #expect(offline.endpointer.hangoverMs == 400)
    }

    @Test("Repeated --bundle-id replaces the default list rather than appending to it")
    func bundleIDsReplaceDefaults() throws {
        let o = try Options.parse(["--bundle-id", "com.example.a", "--bundle-id", "com.example.b"])
        #expect(o.bundleIDs == ["com.example.a", "com.example.b"])
    }

    @Test("Bad input is rejected with a usable message")
    func errors() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["frobnicate"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--nope"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--hangover-ms"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--hangover-ms", "abc"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--hangover-ms", "0"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["offline"]) }
    }

    @Test("The terms file defaults to the working directory")
    func termsPath() throws {
        #expect(try Options.parse([]).resolvedTermsURL.lastPathComponent == "terms.txt")
        #expect(try Options.parse(["--terms", "/tmp/x.txt"]).resolvedTermsURL.path == "/tmp/x.txt")
    }
}

@Suite("Serve options")
struct ServeOptionsTests {
    @Test("Serving is off unless asked for, and loopback when it is")
    func serveDefaults() throws {
        #expect(try !Options.parse([]).serve)
        let o = try Options.parse(["--serve"])
        #expect(o.serve)
        #expect(o.servePort == 7373)
        #expect(!o.serveOnLAN)
    }

    @Test("--listen exposes the transcript to the network and implies --serve")
    func listenImpliesServe() throws {
        let o = try Options.parse(["--listen"])
        #expect(o.serve)
        #expect(o.serveOnLAN)
    }

    @Test("--port takes a value in range")
    func portParses() throws {
        #expect(try Options.parse(["--serve", "--port", "9000"]).servePort == 9000)
    }

    // A port outside the range wraps when converted to UInt16, so 65536 would silently
    // bind port 0 — the OS picks a random one and the printed URL is wrong.
    @Test("A port outside the valid range is rejected rather than wrapped")
    func rejectsOutOfRangePort() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["--port", "65536"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--port", "0"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--port", "-1"]) }
    }
}

@Suite("Ask options")
struct AskOptionsTests {
    @Test("Answering defaults to the current Opus model at low effort")
    func askDefaults() throws {
        let o = try Options.parse([])
        #expect(o.askModel == "claude-opus-5")
        #expect(o.askEffort == "low")
        #expect(o.notesPath == nil)
    }

    @Test("--notes names the prepared material")
    func notesParses() throws {
        #expect(try Options.parse(["--notes", "brief.md"]).notesPath == "brief.md")
    }

    // An unrecognised effort is rejected by the API with a 400 mid-interview, which is the
    // worst possible moment to discover a typo in a flag.
    @Test("An unknown effort level is rejected at parse time, not by the API mid-call")
    func rejectsUnknownEffort() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["--ask-effort", "highest"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--ask-effort", ""]) }
    }

    @Test("Every documented effort level is accepted")
    func acceptsKnownEfforts() throws {
        for level in ["low", "medium", "high", "xhigh", "max"] {
            #expect(try Options.parse(["--ask-effort", level]).askEffort == level)
        }
    }
}

/// Microphone capture: the "You" half of a two-speaker transcript.
@Suite("Mic options")
struct MicOptionsTests {
    /// It was off unless asked for, because on speakers the mic re-heard the caller and every
    /// line doubled. That is `EchoGate`'s job now, and a tool that answers a conversation
    /// should not need telling to listen to both halves of it.
    @Test("Your side of the call is heard unless that is turned off")
    func micDefaultsOn() throws {
        #expect(try Options.parse([]).mic)
        #expect(try Options.parse([]).micDeviceUID == nil)
        #expect(try !Options.parse(["--no-mic"]).mic)
        #expect(try Options.parse(["--mic"]).mic, "commands written for 0.3 still parse")
        #expect(Options.usage.contains("--no-mic"))
    }

    /// Naming a device is an unambiguous request to capture from it; making the user pass
    /// --mic as well would only be a way to get it wrong.
    @Test("Naming a mic device implies capturing from it")
    func micDeviceImpliesMic() throws {
        let o = try Options.parse(["--mic-device", "BuiltInMicrophoneDevice"])
        #expect(o.mic)
        #expect(o.micDeviceUID == "BuiltInMicrophoneDevice")
    }

    /// Your own mouth is far closer to the mic than the caller is to the tap, so the two
    /// sources cannot share one open threshold.
    @Test("The mic gets its own endpointer, louder than the tap's by default")
    func micHasItsOwnThreshold() throws {
        let o = try Options.parse([])
        #expect(o.micEndpointer.openThresholdDB > o.endpointer.openThresholdDB)
    }

    @Test("The mic threshold is overridable and still validated as dBFS")
    func micThresholdOverride() throws {
        #expect(try Options.parse(["--mic-open-db", "-30"]).micEndpointer.openThresholdDB == -30)
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-open-db", "12"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-open-db"]) }
    }

    /// Built-in speakers and the built-in mic are what a laptop has, and the person who has
    /// not plugged anything in is the person least likely to know a flag exists.
    @Test("The mic is protected from the speakers unless that is turned off")
    func echoGateDefaultsOn() throws {
        #expect(try Options.parse(["--mic"]).echoGate)
        #expect(try !Options.parse(["--mic", "--no-echo-gate"]).echoGate)
        #expect(Options.usage.contains("--no-echo-gate"))
    }

    /// The other endpointer knobs still reach the tap only, so tuning one cannot silently
    /// detune the other.
    @Test("--open-db tunes the tap without touching the mic")
    func openDBDoesNotTouchMic() throws {
        let o = try Options.parse(["--open-db", "-52"])
        #expect(o.endpointer.openThresholdDB == -52)
        #expect(o.micEndpointer.openThresholdDB != -52)
    }
}


/// Continuation stitching, which is right for one source and wrong for the other.
@Suite("Merge window")
struct MergeWindowTests {
    /// The caller asks one question and hesitates inside it, so a gap is usually the middle
    /// of a thought. You speak several sentences in a row, so a gap is usually the end of
    /// one. Sharing a window merges your sentences into a single row that keeps being
    /// rewritten, which reads as the later ones never arriving.
    @Test("The mic merges far less eagerly than the tap by default")
    func micMergesLessEagerly() throws {
        let o = try Options.parse([])
        #expect(o.micEndpointer.mergeWindowMs < o.endpointer.mergeWindowMs)
        #expect(o.endpointer.mergeWindowMs == 700)
    }

    @Test("Each source's window is settable on its own")
    func settable() throws {
        #expect(try Options.parse(["--mic-merge-ms", "120"]).micEndpointer.mergeWindowMs == 120)
        #expect(try Options.parse(["--merge-ms", "900"]).endpointer.mergeWindowMs == 900)
        // Tuning one must not move the other.
        let o = try Options.parse(["--mic-merge-ms", "120"])
        #expect(o.endpointer.mergeWindowMs == 700)
    }

    /// Zero is a real choice — never stitch, every pause starts a new row — so it is
    /// accepted where the other durations reject it.
    @Test("Zero disables stitching; negative is rejected")
    func zeroAllowedNegativeRejected() throws {
        #expect(try Options.parse(["--mic-merge-ms", "0"]).micEndpointer.mergeWindowMs == 0)
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-merge-ms", "-1"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--merge-ms", "-1"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-merge-ms"]) }
    }
}


/// How long a pause has to be before your sentence is considered over.
@Suite("Mic hangover")
struct MicHangoverTests {
    /// The tap's 250 ms is spent buying latency: the caller's question has to reach the
    /// screen fast enough to be answered. Your own speech is never read back, so waiting
    /// longer before deciding you have finished costs nothing — and the pauses people take
    /// mid-sentence are far longer than 250 ms.
    @Test("The mic waits considerably longer than the tap by default")
    func micWaitsLonger() throws {
        let o = try Options.parse([])
        #expect(o.micEndpointer.hangoverMs > o.endpointer.hangoverMs)
        #expect(o.endpointer.hangoverMs == 250, "the caller's latency budget must not move")
    }

    @Test("Each source's hangover is settable on its own")
    func settable() throws {
        #expect(try Options.parse(["--mic-hangover-ms", "1200"]).micEndpointer.hangoverMs == 1200)
        // Tuning the mic must not slow the caller down.
        #expect(try Options.parse(["--mic-hangover-ms", "1200"]).endpointer.hangoverMs == 250)
        #expect(try Options.parse(["--hangover-ms", "400"]).micEndpointer.hangoverMs > 400)
    }

    @Test("A non-positive hangover is rejected")
    func rejectsNonPositive() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-hangover-ms", "0"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-hangover-ms", "-5"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["--mic-hangover-ms"]) }
    }
}

/// The on-disk transcript and the flags that govern it.
@Suite("Transcript log options")
struct LogOptionTests {
    /// On by default. A record of the call is the useful state; the flag exists for people
    /// who would rather it not be on disk at all, which is a preference the tool should hold
    /// but not assume.
    @Test("Logging is on unless turned off")
    func defaultsOn() throws {
        #expect(try Options.parse([]).writeLog)
        #expect(try Options.parse(["--no-log"]).writeLog == false)
    }

    /// Off by default, because restarting is also how a new interview begins — inheriting
    /// the previous one's transcript would be worse than losing it.
    @Test("Resuming is opt-in")
    func resumeIsOptIn() throws {
        #expect(try Options.parse([]).resumeLog == false)
        #expect(try Options.parse(["--resume"]).resumeLog)
    }

    @Test("The log directory can be pointed somewhere else")
    func logDirectory() throws {
        #expect(try Options.parse([]).logDirectory == nil)
        #expect(try Options.parse(["--log-dir", "/tmp/x"]).logDirectory == "/tmp/x")
    }

    /// Asking to resume a log that is not being written cannot be honoured, and silently
    /// doing neither is how someone discovers mid-call that the transcript never came back.
    @Test("Resuming with logging off is rejected rather than ignored")
    func resumeWithoutLogIsAnError() {
        #expect(throws: (any Error).self) { try Options.parse(["--no-log", "--resume"]) }
    }

    @Test("Both flags are documented in the usage text")
    func documented() {
        #expect(Options.usage.contains("--no-log"))
        #expect(Options.usage.contains("--resume"))
    }
}

/// Argument-parsing edges that fail quietly rather than loudly.
@Suite("Argument parsing edges")
struct ArgumentEdgeTests {
    /// The one that matters: a flag left without its value used to consume the NEXT flag as
    /// that value, dropping it silently. `--terms --no-log` wrote the interview to disk
    /// despite being told not to, and the only clue was a stray path in an unrelated warning.
    @Test("A flag missing its value does not swallow the next flag")
    func missingValueDoesNotSwallow() {
        #expect(throws: (any Error).self) { try Options.parse(["--terms", "--no-log"]) }
        #expect(throws: (any Error).self) { try Options.parse(["--ask-model", "--serve"]) }
        #expect(throws: (any Error).self) { try Options.parse(["--log-dir", "--resume"]) }
    }

    /// A negative number is a value, not a flag — dBFS thresholds are all negative, so the
    /// guard must key on the long-option prefix rather than on a leading minus.
    @Test("A negative number is still a value")
    func negativeNumbersSurvive() throws {
        #expect(try Options.parse(["--open-db", "-45"]).endpointer.openThresholdDB == -45)
        #expect(try Options.parse(["--mic-open-db", "-31"]).micEndpointer.openThresholdDB == -31)
    }

    /// Log flags used to be silent no-ops without --serve: no file, nothing restored, nothing
    /// said. Every other serve-scoped flag turns serving on, so these do too.
    @Test("Log flags imply serving, as the other serve-scoped flags do")
    func logFlagsImplyServe() throws {
        #expect(try Options.parse(["--log-dir", "/tmp/x"]).serve)
        #expect(try Options.parse(["--resume"]).serve)
        // --no-log is a disable, so it must not switch the server on by itself.
        #expect(try Options.parse(["--no-log"]).serve == false)
    }

    /// Advice that cannot work is worse than none: the hint prepended a minus to a value that
    /// might already be negative or zero, so `--open-db 0` suggested `-0.0`, which fails the
    /// same check and sends the user round the loop again.
    @Test("The dBFS hint only appears when flipping the sign would work")
    func dbHintIsUsable() {
        for bad in ["0", "-0"] {
            do {
                _ = try Options.parse(["--open-db", bad])
                Issue.record("--open-db \(bad) should have been rejected")
            } catch {
                #expect(!"\(error)".contains("did you mean"),
                        "suggested a sign flip that cannot help: \(error)")
            }
        }
        do {
            _ = try Options.parse(["--open-db", "45"])
            Issue.record("--open-db 45 should have been rejected")
        } catch {
            #expect("\(error)".contains("did you mean -45"), "lost a suggestion that works: \(error)")
        }
    }

    /// Naming a flag the user never set sends them to fix the wrong thing.
    @Test("A non-positive duration is reported against the flag that was actually set")
    func durationErrorNamesTheRightFlag() {
        do {
            _ = try Options.parse(["--max-speech-ms", "0"])
            Issue.record("--max-speech-ms 0 should have been rejected")
        } catch {
            #expect("\(error)".contains("--max-speech-ms"))
            #expect(!"\(error)".contains("--min-speech-ms"),
                    "names a flag the user did not set: \(error)")
        }
    }

    @Test("Every command the parser accepts is in the usage block")
    func usageListsEveryCommand() {
        for command in ["miccheck", "stop", "shot", "selftest", "devices", "offline", "install-model"] {
            #expect(Options.usage.contains("wngmn \(command)"),
                    "`\(command)` is accepted but not documented in USAGE")
        }
    }
}

/// Flags that parse cleanly and then do nothing, which is the worst way for one to fail.
@Suite("Flags that must not be no-ops")
struct SilentNoOpTests {
    /// Rotating the token only happens on the LAN path, so on any other run `--new-token`
    /// parsed, printed nothing, and left the bookmarked URL working — the opposite of what
    /// someone asking to rotate a token wants to be true.
    @Test("--new-token implies the serving it rotates a token for")
    func newTokenImpliesListening() throws {
        let o = try Options.parse(["--new-token"])
        #expect(o.serve)
        #expect(o.serveOnLAN, "a rotated token only means anything once the port is on the network")
    }

    /// Pause is released from the page. Without a server there is no page, no key handler and
    /// no route, so the run stays paused for its whole life with nothing able to unpause it.
    @Test("--start-paused implies the interface that can unpause it")
    func startPausedImpliesServe() throws {
        #expect(try Options.parse(["--start-paused"]).serve)
    }

    /// `URL(fileURLWithPath: "")` is the current directory, so this wrote the interview
    /// transcript into whatever directory wngmn happened to be launched from.
    @Test("An empty --log-dir is refused rather than resolved to the launch directory")
    func emptyLogDirIsRefused() {
        #expect(throws: (any Error).self) { try Options.parse(["--log-dir", ""]) }
    }

    /// The guard added for `--terms --no-log` keyed on the long-option prefix only, so a
    /// short flag was still swallowed as a value.
    @Test("A short flag is not swallowed as a value either")
    func shortFlagsAreNotValues() {
        #expect(throws: (any Error).self) { try Options.parse(["--terms", "-h"]) }
        // Still not a flag: every dBFS threshold is a negative number.
        #expect(throws: Never.self) { try Options.parse(["--open-db", "-45"]) }
    }

    @Test("The dBFS message does not trail off with a bare semicolon")
    func noDanglingSemicolon() {
        do {
            _ = try Options.parse(["--open-db", "0"])
            Issue.record("should have been rejected")
        } catch {
            #expect(!"\(error)".hasSuffix(";"), "message trails off: \(error)")
        }
    }
}

/// `wngmn shot` is a client: it asks a wngmn that is already running to take a picture.
@Suite("Shot options")
struct ShotOptionsTests {
    @Test("shot is a command, and the whole screen is what it takes unless told otherwise")
    func parsesShot() throws {
        let o = try Options.parse(["shot"])
        #expect(o.command == .shot)
        #expect(o.shotMode == .screen)
    }

    @Test("--region asks for the crosshair")
    func parsesRegion() throws {
        #expect(try Options.parse(["shot", "--region"]).shotMode == .region)
    }

    /// Everywhere else `--port` and `--token` mean "serve", because that is the only reason to
    /// give them, and `main` starts the server before it looks at the command. A `shot` that
    /// inherited that would try to bind the very port it is meant to post to — and exit with
    /// "cannot serve on port 7373; another wngmn may already be running", which is the wngmn
    /// it was looking for. With nothing running it would bind it, and open a session log.
    @Test("For shot, --port and --token say where to post, not what to serve")
    func portAndTokenDoNotServe() throws {
        let o = try Options.parse(["shot", "--region", "--port", "7400", "--token", "abcd2345"])
        #expect(o.servePort == 7400)
        #expect(o.serveToken == "abcd2345")
        #expect(!o.serve, "a client must never start a server")
        #expect(!o.serveOnLAN)
    }

    @Test("--region means nothing outside shot, and says so")
    func regionNeedsShot() {
        #expect(throws: Options.ParseError.self) { try Options.parse(["--region"]) }
        #expect(throws: Options.ParseError.self) { try Options.parse(["offline", "x.wav", "--region"]) }
    }

    @Test("shot is in the usage block and in the unknown-command message")
    func documented() {
        #expect(Options.usage.contains("wngmn shot"))
        #expect(Options.usage.contains("--region"))
        do {
            _ = try Options.parse(["shoot"])
            Issue.record("an unknown command parsed")
        } catch {
            #expect("\(error)".contains("shot"), "the list of commands leaves shot out: \(error)")
        }
    }
}

/// Whether a run starts with auto already on.
///
/// It did not, until it did. The tool's point is an answer that arrives while the other person
/// is still waiting for yours; a toggle to find, in the first seconds of a call, stood between
/// every new user and that. So it starts on — and the ways it must *not* start on are what
/// these pin.
@Suite("Auto on by default")
struct AutoDefaultTests {
    @Test("A served run with credentials starts with auto on")
    func startsOn() throws {
        let o = try Options.parse(["--serve"])
        #expect(o.autoAnswer)
        #expect(o.startsWithAuto(hasCredentials: true))
    }

    @Test("--no-auto is the way to start with it off")
    func noAuto() throws {
        let o = try Options.parse(["--serve", "--no-auto"])
        #expect(!o.autoAnswer)
        #expect(!o.startsWithAuto(hasCredentials: true))
    }

    /// With no key every turn would become an `answer_failed` row: a transcript full of red,
    /// from a feature nobody asked for, on a run whose startup already said Ask will fail.
    @Test("Without credentials it starts off, rather than failing on every turn")
    func offWithoutCredentials() throws {
        #expect(!(try Options.parse(["--serve"]).startsWithAuto(hasCredentials: false)))
    }

    /// Auto answers onto the page. With nothing served there is nowhere for an answer to go.
    @Test("Without a page there is nothing to answer onto")
    func offWithoutAPage() throws {
        #expect(!(try Options.parse([]).startsWithAuto(hasCredentials: true)))
    }

    @Test("--no-auto is documented")
    func documented() {
        #expect(Options.usage.contains("--no-auto"))
    }
}
