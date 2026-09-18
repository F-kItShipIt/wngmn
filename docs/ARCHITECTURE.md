# Architecture

[wngmn](../README.md) · [Usage](USAGE.md) · [Permissions](PERMISSIONS.md) · [Tuning](TUNING.md) · [The page](PAGE.md) · [Security](../SECURITY.md) · [Contributing](../CONTRIBUTING.md)

Read this before changing anything. It covers what the five targets own, how a sample of
audio becomes a line on a phone screen, the concurrency rules that are not negotiable, the
two published protocols (JSON Lines and HTTP), and the platform behaviour that will
otherwise cost you an afternoon each.

The tool is a single macOS binary. It taps the audio a conferencing app is playing,
transcribes it on-device, decides when the other person's question has ended, and prints one
JSON object per line on stdout. With `--serve` it also serves a live transcript page over a
hand-rolled HTTP/1.1 listener. Audio never leaves the machine; only pressing **Ask** on the
page sends anything anywhere.

## Build constraints

`Package.swift` pins `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, and applies
two settings to every target:

```swift
.swiftLanguageMode(.v6)
.treatAllWarnings(as: .error)
```

There are **no package dependencies** — not for HTTP, not for argument parsing, not for
JSON. Two reasons, and both are load-bearing rather than taste. A stated success criterion
is that setting up on a clean machine needs no network fetch. And warnings-as-errors exists
because the Swift 6 data-race diagnostics that matter here — sending a buffer pointer across
an isolation boundary, a global `var` silently inferred `@MainActor` — are the ones that
produce a crash on the audio thread rather than a compile failure.

Everything is Apple frameworks or hand-rolled: Core Audio, `Speech`, `AVFoundation`,
`Network`, `Synchronization`.

## The five targets

```
                       wngmn (executable)
                   ┌────────┬────────┬────────┐
             WngmnAudio  WngmnServe  WngmnAsk │
                   └────────┴───┬────┴────────┘
                             WngmnCore
```

`WngmnAudio`, `WngmnServe` and `WngmnAsk` each depend on `WngmnCore` and on nothing else.
They do not know about each other. The executable is the only place the three meet.

### Where they live

The directories say which layer a target belongs to, because wngmn is meant to run on more
than one operating system and the engine is the part that has to travel.

```
Sources/
  Engine/           the part that travels: no Apple framework may be imported here
    WngmnCore/      pure logic
    WngmnAsk/       the Claude client, the conversation, the answerer
  UI/
    WngmnServe/     the page, and the server that feeds it
  Platform/
    Apple/
      WngmnAudio/   Core Audio, the process tap, SpeechAnalyzer
  App/
    wngmn/          the macOS command line: wiring and nothing else
```

Target names do not change with the directory, so every `import` and `--filter` reads as it
always did. A second platform adds `Platform/<os>/` beside `Apple/` and an app beside `wngmn`,
and shares everything under `Engine/` and `UI/`. Not all of `Engine/` is there yet: see
[the split](#the-engine-and-the-platform) below.

### WngmnCore — pure logic

`Endpointer`, `QuestionAssembler`, `AudioRingBuffer`, `Event`/`EventEncoder`,
`TextNormalizer`, `TermList`, `Profile`/`ProfileSource`, `Options`, `CaptureControl`,
`MicCalibration`, `RunningProcesses`, `TurnBatcher`, `AnswerQueue`, `ShotCapture`,
`EchoGate`/`FarEndActivity`.

Deliberately free of Core Audio and `Speech`. The reason is testability under the permission
model: System Audio Recording is granted to a *parent process*, so a test bundle run from an
IDE or a CI shell may not hold the grant. Keeping the decisions that actually matter — when
a question ended, how a final is matched to an endpoint, how jargon is repaired — in a target
that imports neither framework means `WngmnCoreTests` runs in any terminal, with no
permission and no microphone. Its fixtures are headerless 16 kHz mono little-endian Int16
(`.s16le16k`) for the same reason: reading a WAV would mean importing an audio framework.

`AudioRingBuffer` lives here despite being the audio hot path, because it is pure memory and
atomics, and because its overrun and wraparound behaviour is exactly the kind of thing that
should be asserted rather than observed on a live call.

`ShotCapture` is here because the executable has no test target. Taking a screenshot needs a
display, a permission and sometimes a person; what to run, whether to shrink the result,
whether it fits the API, where `wngmn shot` posts and what each reply means are arithmetic
and strings, so they are decided here and the executable is left with a process spawn and a
network call.

`TurnBatcher` and `AnswerQueue` are here for the same reason, one level up. When a turn is
over, and what may be sent while a request is already out, are decisions — and both are value
types that take their inputs as arguments, so neither needs a clock, a socket or a model to be
tested.

### WngmnAudio — everything that touches the system

`SystemAudioTap` (the process tap and its private aggregate), `MicCapture`/`MicSource`,
`Transcriber` (`SpeechAnalyzer` + `AVAudioConverter`), `AudioClock` (`HostClock`,
`MonotonicStopwatch`, `AudioStreamClock`), `AudioCatalog`, `AudioObjectProperty`,
`AudioRoute`, `DeviceWatcher`, `CaptureTimeline`, `Pipeline`, `OfflineRunner`, `Teardown`,
and `EventWriter` (in `Output.swift`).

This is the target whose tests need the grant, which is why the boundary is drawn here and
not looser. `OfflineRunner` is the exception that proves it useful: it runs the same
endpointer, resampler, analyser and assembler over a file, so the golden-file tier exercises
everything except the tap and still needs no permission.

### WngmnServe — the transcript view

`TranscriptServer` (hand-rolled HTTP/1.1 and Server-Sent Events on `Network.framework`),
`HTTPRequest`, `SSE`, `Page` (the whole page, embedded as a Swift string), `EventLog`,
`AccessToken`, `TokenStore`.

It depends on `WngmnCore` only — it renders events, it does not know where they came from.
That is why `offline clip.wav --serve` replays a recording into the identical page with no
special case anywhere, and why the server's tests construct events by hand.

The consequence to keep in mind when editing: `WngmnServe` cannot reach `EventWriter.note`,
because that lives in `WngmnAudio`. `EventLog` writes its one durability failure directly to
`FileHandle.standardError` for exactly this reason.

The page is embedded rather than shipped as a file so the binary is self-contained — no
asset path to resolve, and `swift build && wngmn --serve` works from any directory. It loads
nothing from the internet, because there is none behind the socket it is served from.

### WngmnAsk — outbound Claude calls

`ClaudeClient` (one streaming POST to the Messages API), `AnthropicStream` (SSE decoding,
separated from the transport so every branch can be tested without a key), `AnswerPrompt`
(pure prompt assembly), `Credentials`.

Separate from `WngmnServe` on purpose. The server renders the transcript and knows nothing
about where an answer comes from; the Claude dependency stays on one side of that line. The
seam is a function type in `WngmnServe`:

```swift
public typealias AskHandler = @Sendable (
    _ payload: String, _ emit: @escaping @Sendable (AskChunk) -> Void
) -> Task<Void, Never>
```

The executable supplies it. The returned `Task` is handed back so the server can cancel an
answer that has been overtaken by a revision of its question.

`AutoAnswerer` (the real-time loop: utterances in, answer frames out) and `CallConversation`
(the call as one Messages-API conversation, which is also what the end-of-call notes are
written from). The answerer's turn-taking is not its own: `TurnBatcher` decides when a turn is
over and `AnswerQueue` decides what is sent, both pure and both in `WngmnCore`.

### wngmn — the executable

`Wngmn.swift` (argument dispatch and wiring), `Selftest`, `Devices`, `MicCheck`, `Shot`.

Its job is joining: it builds the `EventWriter` with an observer closure that forwards every
event to the `TranscriptServer`, builds the `AskHandler` that closes over `WngmnAsk`, shares
one `CaptureTimeline` and one `CaptureControl` between the tap and the microphone, and
installs the `TeardownCoordinator`. Commands: `run` (the default), `selftest`, `devices`,
`offline <file>`, `miccheck`, `stop`, `shot`, `install-model`.

`shot` is the odd one: a client. It leaves `main` beside `help`, before the profile, the
server and the signal handlers exist, because everywhere else `--port` and `--token` mean
"serve" and `main` starts the server before it looks at the command — dispatched with the
others, it would try to bind the port it is posting to. `Shot.swift` also holds the other
half, `ShotTaker`, which runs in the long-lived process: it spawns `screencapture` and `sips`
through `BoundedProcess`, the only place in wngmn a child is given a deadline, because it is
the only child that waits for a person. The `CaptureTimeline` is made in `main` rather than
in `runCapture` so that a shot can be stamped on the clock its neighbouring rows use.

## The live data path

One trace, from the speaker's voice to the reader's screen. The thread or actor each step
runs on is named, because several of the bugs this code carries scar tissue from were
crossings between them.

1. **IOProc block** — Core Audio's IO thread, registered with
   `AudioDeviceCreateIOProcIDWithBlock` on the `wngmn.tap` queue
   (`SystemAudioTap.startIO`). It reads the tap's buffer out of the input list at
   `tapBufferIndex`, checks the channel count still matches, scans once for a peak, calls
   `ring.write`, and bumps four atomics. Nothing else. The block is explicitly `@Sendable`
   — see *Platform lessons*.

2. **`AudioRingBuffer.write`** — same thread. Two `memcpy`s and three atomic stores, no
   allocation, no locks, no syscalls. Overrun policy is drop-newest-and-count. Default
   capacity is `1 << 20` frames — about 21 seconds at 48 kHz mono, 4 MB — with `1 << 12`
   segment slots, one per callback in flight. Each segment carries the buffer's
   `mHostTime`, because the tap elides silence rather than zero-filling it and elapsed time
   can therefore never be recovered from a frame count.

3. **`Pipeline.consumeAudio` → `drainRing`** — the `Pipeline` actor, polling every 5 ms.
   Short enough to resolve the 250 ms hangover promptly, long enough not to be a spin. It
   pops segments with `peekSegment` then `readSegment` into a reusable scratch array.

4. **`AudioStreamClock.admit`** — `Pipeline` actor. Turns `mHostTime` into a sample-accurate
   position on a timeline anchored at the first buffer. Inside a contiguous run the timeline
   advances by exactly `frameCount`; it resyncs to host time only when the two disagree by
   more than 30 ms, which is a real gap. `CaptureTimeline.anchor` then reconciles this
   source's origin with whichever source anchored first, and `timelineOffset` keeps the
   emitted timeline continuous across a capture-graph rebuild.

5. **`Endpointer.push`** — `Pipeline` actor. RMS over non-overlapping 10 ms windows, driving
   a four-state machine (`silence` → `onset` → `speech` → `hangover`). It reads the **raw
   Float32 capture**, not the resampled stream: putting the sample-rate converter's roll-off
   and a scaling factor between the microphone and the decision would be a silent accuracy
   cost. Defaults: 80 ms onset, 250 ms hangover, 350 ms minimum utterance, 30 s monologue
   limit, −45 dBFS open threshold with 6 dB hysteresis and an adaptive noise floor capped at
   12 dB of movement.

6. **`Transcriber.advance` then `Transcriber.feed`** — the `Transcriber` actor. `advance`
   fills the analyser's timeline with silence up to the buffer's start so a gap stays a gap;
   `feed` resamples 48 kHz Float32 to the analyser's format — measured as 16 kHz mono
   **Int16**, interleaved — and yields `AnalyzerInput` at the next contiguous position on
   `analyzerFrames`. The converter uses `AVSampleRateConverterAlgorithm_MinimumPhase` at
   maximum quality: the default algorithm measured −2.12 dB at 6 kHz and −5.17 dB at 7 kHz,
   which is real fricative energy, while minimum phase measured flat to 0.09 dB from 1–7 kHz
   with zero added latency.

7. **`SpeechAnalyzer`** — the framework's own concurrency. Fed by the `AsyncStream` of
   `AnalyzerInput` the `Transcriber` owns.

8. **The results task** — a `Task` started in `Transcriber.prepare`, reading
   `transcriber.results`. It translates each result's `CMTimeRange` by the recogniser's
   origin — once, here, so no consumer can forget to — and yields a `Transcript` into the
   `transcripts` `AsyncStream`.

9. **`Pipeline.handle(transcript:)`** — `Pipeline` actor, via the child task in `run()`'s
   task group. Volatile results go to `QuestionAssembler.volatileArrived` (kept only as a
   fallback) and, unless `--no-partials`, straight out as a `partial` line.

10. **The endpoint**, meanwhile, took a different route. `Pipeline.handle(_ event:)` calls
    `assembler.endpointDetected` *first*, then `transcriber.finalize(throughStreamSeconds:)`,
    which dispatches a detached task. Registering the pending question before requesting the
    finalise matters: the call suspends the actor, and a final arriving in that window with
    nothing pending would be filed away and only surface on the 2.5 s timeout.

11. **`QuestionAssembler.finalArrived`** — `Pipeline` actor. This is the join between the two
    halves of the design and the fiddliest part of it: the endpointer knows *when* the
    question ended, the recogniser knows *what* was said, and they arrive independently.
    Question text is built only from finalised results; a volatile stands in for a whole
    region only when the forced final demonstrably lost content it had already heard.

12. **`EventWriter.emit`** — the caller's thread, under a `Mutex`. It encodes the line with
    the hand-written `EventEncoder`, calls the observer *before* writing to stdout (so a
    browser keeps receiving events after the pipe's reader has gone away), then writes.
    `setvbuf(stdout, nil, _IOLBF, 0)` sets line buffering; `SIGPIPE` is ignored so a closed
    pipe becomes an `EPIPE` this code can handle rather than exit 141.

13. **`TranscriptServer.broadcast` / `broadcastLive`** — the observer closure, still on the
    emitting thread, taking the server's state `Mutex`. Under that one lock the frame gets
    its id, is appended to `EventLog`, and is appended to the bounded 400-entry backlog —
    one atomic step, because two events racing from the tap and the mic can otherwise be
    numbered out of the order they are retained in. The SSE frames then go out on each
    `NWConnection`, and `EventLog.syncSoon()` is called *after* the fan-out and outside the
    lock: `F_FULLFSYNC` costs 2.9 ms, and the pages are charted against a 700 ms budget.

14. **The browser** — an `EventSource` on `/events`. It reconnects on its own and cites the
    last id it saw in `Last-Event-ID`, which is how the server knows what a returning page
    already has.

The microphone — on unless `--no-mic` — is a second, parallel copy of steps 1–13 through
`MicCapture` and `MicSource`,
sharing the `EventWriter` and the `CaptureTimeline`. It is a sibling of `Pipeline` rather
than a second source inside it: `Pipeline` carries the aggregate-rebuild, device-watch and
keep-alive machinery that a live call depends on, and a microphone is not tap-backed, so
none of it applies. Keeping them apart means enabling the mic cannot regress caller capture.

One thing crosses between them, in one direction. With the call on speakers the mic hears
the caller too, so `Pipeline` writes the level of every tap buffer into a `FarEndActivity` —
before the pause check, because a paused tap is one nobody is reading, not one the speakers
have stopped playing, and before anything that can suspend — and `MicSource` asks it about
each of its own buffers. `EchoGate` decides from that whether the mic is a copy of the far
end, and if so the buffer is zeroed before the endpointer and the recogniser see it — one
step, `EchoGate.process`, in `WngmnCore` so that its order is tested. Both sides stamp by the
host clock: the tap's own timeline counts samples, and drifts from it when the output
device's crystal runs fast. It is a lock, not a message between the two actors: the question
is asked a hundred times a second about a stretch of time that ended milliseconds ago, and an
`await` into `Pipeline` would queue it behind the recogniser. A mic buffer waits in its ring
until the tap has reported past it, by sound or by `advanceIdleTime`'s silence, and for a
second at most, so a tap that is rebuilding cannot stop the half that still works.

Two things also run on a timer in the consume loop rather than in the trace: `advanceIdleTime`
walks both the endpointer and the analyser through wall-clock silence (clamped by a 60 ms
delivery-lag allowance), and `checkCaptureHealth` / `checkSilentCapture` watch for a tap that
has stopped delivering or is delivering nothing but zeros.

## Concurrency model

**The IOProc is real-time and that is a correctness requirement, not an optimisation.**
Allocating, locking, or writing to a pipe on that thread stalls it when the consumer falls
behind, and a stalled IOProc produces audible dropouts *on the live call*. So the block may
do only: read from the buffer list, arithmetic, `memcpy`, and relaxed atomic operations. It
may not touch `self`, allocate a Swift array, take a lock, or log. `Counters` and
`MonoScratch` are reference types precisely because `Atomic` is non-copyable and a bare
`UnsafeMutablePointer` cannot cross a `@Sendable` boundary, so a shared reference is the only
way to reach that state from the real-time thread.

**The ring buffer is the isolation boundary.** Everything upstream of it is real-time;
everything downstream is allowed to allocate, await and log. It is strictly
single-producer/single-consumer — one IOProc writing, one actor reading.

**Actors.** `Pipeline`, `MicSource` and `Transcriber` are actors. `Transcriber` is one
because the resampler is genuinely stateful — a second pass on the same instance without
`reset()` produces different samples — and making "drive this from one serial context" a
compiler-enforced property is cheaper than an audit.

**One request at a time is a value type's property, not an actor's.** `AutoAnswerer` is an
actor, and it used to await each answer inline. Actors are re-entrant while suspended, so with
one answer streaming the half-second ticker could close another turn and start a second
request beside it; the ledger then held both user turns before either reply. `AnswerQueue`
holds it to one: `question` and `tick` enqueue and return, a single drain task owns whatever
is out, and everything that closed meanwhile goes as one batch when it settles. A cancel is
recorded by request id rather than applied to a task, because it can arrive in the gap
between the queue handing out an id and the request's task existing. The auto toggle is read
when a turn closes and again before anything is sent, so nothing overheard leaves after it
goes off; and the end-of-call notes wait for the queue, so they are written from the whole
call.

**A screenshot is the one thing that pre-empts.** It enters the same queue as a spoken turn —
`AutoAnswerer.shot` — with `preempts: true`, so it cancels whatever answer is out, which is
usually an answer to "let me paste this here". It is exempt from the toggle at both reads:
the toggle governs what is overheard, and pressing a key is asking. With auto off a shot goes
alone, and does not carry held speech out with it. An answer to a batch that holds a shot is
keyed to the shot, not to whatever closed last, and every shot that will get no answer of its
own — cancelled by a newer one, or sent ahead of it in the same batch — is sent a frame
saying so, because on the page "Asking…" is not a state but the absence of one.

**Escape hatches, each for a stated reason.** `Pipeline.activeTap` is a `Mutex`, not actor
state, because teardown has to be callable synchronously from the signal handler: a `Task`
there loses the race against `exit()` and leaks a private aggregate device. `Transcriber`'s
`streamOrigin` is a `Mutex` because the results task translates timestamps on the way out.
`CaptureControl` is atomics rather than actor state because the audio drain loops read it and
must not suspend to ask whether they are allowed to keep going. `Transcriber.finalize` is
`nonisolated` and spawns a detached task — see *Platform lessons*.

**Queues.** `wngmn.tap` (IOProc registration), `wngmn.devices` (HAL property listeners hop
here, because the C listener API has no queue parameter and calls back on a HAL-internal
thread), `wngmn.serve` (the `NWListener` and every connection), `wngmn.eventlog.sync` (serial,
so `F_FULLFSYNC` never overlaps and never runs on the thread that wrote the line).

**Signals.** `TeardownCoordinator` uses `DispatchSourceSignal`, not a `sigaction` handler,
because a signal handler body must be async-signal-safe and Core Audio teardown is not.
Installing the source also requires `signal(sig, SIG_IGN)` first: the dispatch source only
observes delivery and does not change the kernel disposition, so without it SIGTERM still
terminates the process and the handler never runs. `atexit` alone is not enough — measured,
it does not run on SIGTERM or SIGKILL.

**How Swift 6 shaped the code.** Three visible marks. The `@Sendable` annotation on the
IOProc block is not cosmetic (below). `nonisolated(unsafe)` appears three times and nowhere
else — twice on the buffer handed to an `AVAudioConverterInputBlock`, which the converter
calls synchronously on the calling thread, and once on the C property-listener trampoline in
`AudioObjectProperty`. And the task group in `Pipeline.run`
passes only the result *stream* into the child task, never the `Transcriber` itself, which is
not `Sendable` and stays owned by the actor.

## The event protocol

`--help` and the source call this **stage 1**: capture, transcribe, endpoint, print. Stage 2 is
a separate downstream program — a message bank and an on-screen overlay — that consumes these
lines rather than linking against internals. Nothing in this repository is stage 2, and stage 1
is useful on its own. That split is the whole reason the event shape is treated as a published
contract rather than an implementation detail.

JSON Lines on stdout, one object per line. A downstream consumer reads this stream rather
than linking against internals, so the shape is a published contract — **including key order**, which
`JSONEncoder` does not preserve. `EventEncoder` is hand-written for that reason, and because
it runs on a live call: one string allocated, no reflection. Diagnostics go to stderr, so
`wngmn | jq` stays clean.

Six event types, defined in `Sources/Engine/WngmnCore/Events.swift`.

| type | fields |
| --- | --- |
| `status` | `state`, `format` (`{rate, ch}`, optional), `detail` (optional) |
| `partial` | `text`, `t`, `speaker` (optional) |
| `question` | `text`, `t0`, `t1`, `ms`, `revises` (only when true), `volatile` (only when true), `speaker` (optional) |
| `warning` | `code`, `detail` |
| `error` | `code`, `detail` |
| `metric` | `name`, `value`, `unit` |

Notes that matter to a consumer:

- `state` is one of `starting`, `capturing`, `stopped`, `control` (a capture control was
  applied), `mic` (the microphone half started), `selftest`.
- `partial` is volatile text, advisory only, and is never assembled into a question.
- `revises` means this line **supersedes the most recent `question` line** rather than
  following it. `warning` and `partial` lines can appear in between, so a consumer must track
  the last question it *displayed*, not the last line it read. Ignoring the field still
  yields a correct, briefly duplicated, transcript.
- `volatile` means the text came from the volatile stream because the forced final was lossy.
- `ms` is measured endpoint-to-final latency for that question. It starts *after* the
  hangover, which is why the served page is told the hangover value and adds it back before
  judging anything against the end-to-end budget.
- `speaker` (`caller` or `you`) is carried only when more than one source is being captured.
  With the mic off the line is byte-identical to the single-source shape, so enabling the mic
  is what introduces the key rather than an unannounced change. It is also placed last so
  every existing key keeps its position.
- `Event.isReplayable` is false for `partial` and `metric`. Both are superseded or derivable,
  and remembering them fills a bounded replay buffer with text that was obsolete on arrival:
  measured on a live run, 113 of 123 retained frames were partials, leaving three questions.
  This one property decides both what a reconnecting page is replayed and what `EventLog`
  writes to disk.

Current codes, for orientation rather than as an exhaustive contract — `warning`:
`swept_aggregates`, `listener_failed`, `feed_failed`, `capture_gap`, `no_audio`,
`silent_capture`, `rebuilding`, `rebuild_failed`, `transcriber_ended`, `question_lost`,
`final_timeout`, `volatile_fallback`, `mic_failed`, `mic_feed_failed`, `mic_unmute_failed`,
`mic_question_lost`, `mic_silent`, `mic_hears_call`, `mic_hears_call_cleared`. `error`: `fatal`, `selftest_setup`,
`selftest_no_buffers`, `selftest_no_frames`, `selftest_silent`, `selftest_too_quiet`.
`metric`: `vad_db`, `mic_db`, `echo_likeness`, `echo_gain_db`, `echo_lag_ms`, `selftest_peak`, `selftest_rms_db`, `selftest_frames`, `mic_ambient_db`,
`mic_speech_db`, `mic_recommended_db`.

`rebuild_failed` is a warning, not an error, and the distinction is the contract: `error`
means the binary is about to exit non-zero. Reported as an error it turned the page's status
pill red over a session that was still running.

### Frames the server adds

Over SSE — and only over SSE, never on stdout — the page is sent shapes the pipeline never
emits, so that the JSON Lines stream stays a transcript rather than a notepad. From the
server: `answer` (a streamed fragment), `answer_done` (the complete answer, backlogged once),
`answer_failed`, and `scroll` (one page's scroll anchor relayed to the others, live-only).
From the answerer: `auto` (the running count of calls and answers, live-only),
`summary_pending`, `summary_done` and `summary_failed` for the end-of-call notes, and `shot`
— a screenshot was taken: when, whether the screen or a region, and its size in pixels and
bytes. Never the picture. `shot` is backlogged and logged like a question line, because it is
a row in the transcript; it is built by hand rather than through `JSONSerialization`, which
spells 83.412 as 83.412000000000006, so that its `t` and its `key` agree to the digit. Each answer frame carries `key` and
`for`, so a page can drop a frame that reached the socket before the server heard its
question had been revised.

### The session log

With `--serve`, every frame that is retained is also appended to a file:
`sessions/<yyyy-MM-dd'T'HH-mm-ss>.jsonl` under `~/Library/Application Support/wngmn/` by
default, elsewhere with `--log-dir`, nowhere with `--no-log`. The replay backlog is in
memory and dies with the process, so a run that dies mid-interview otherwise takes the
transcript with it; this is the same data on disk.

A line of the log is shaped exactly like a line of stdout — the same `EventEncoder` output,
one event per line, with no envelope around the line and no wrapper around the file. So the
tooling is the tooling you already have: `jq 'select(.type == "question") | .text'
session.jsonl` reads back last week's interview exactly the way `wngmn | jq` reads a live
one.

**A line's id is its position in the file**, counting from 1. That is what makes the wrapper
unnecessary, and it is what a reader needs in order to line an old log up with what a page
saw: the `id` an SSE frame carried (step 13) is the line number of that same event here. The
invariant holds because a line is written if and only if it was issued an id, under the one
lock that issues it. `--resume` depends on the same property — it continues the most recent
session file that has anything in it and issues the next id from the line count, so ids stay
unique across the restart.

Two things a reader should expect. Only replayable events are written — `Event.isReplayable`
again, so partials and metrics are absent rather than being most of the file — and the
server's own `answer_done` and `answer_failed` frames are present, because anything
backlogged is logged. And power loss can leave a final line with no terminator: the next open
truncates back to the last newline *before* reading anything back, since appending after a
fragment would splice two events into one line and put every later id one past the line it
occupies.

## The HTTP surface

`TranscriptServer`, port 7373 by default. Loopback unless `--listen`, in which case the
listener binds every interface and a token is required on every request. On loopback there is
no token: the OS is the boundary.

Every request is gated in this order, and the order is deliberate.

1. **`Host` header.** Four shapes are accepted, and nothing else: `localhost` or any name
   ending `.localhost`; any `.local` Bonjour name; an address, meaning exactly four
   dot-separated parts that each parse as a `UInt8`; and a bracketed IPv6 literal. A real
   client never reaches this server by a registered domain, so refusing them costs nothing
   and removes DNS rebinding as a route to a loopback server. Checked first because it is the
   cheapest and the least revealing. The bracket rule is load-bearing: a port is stripped at
   the last colon, and an unbracketed host with a colon still in it is refused, because
   bracketing is what makes an IPv6 literal unambiguous in a `Host` header — treating any
   surviving colon as proof of IPv6 let `evil.example.com:8080:7373` through.
2. **Token** (`?t=`), when one is configured. Constant-time comparison, and deliberately the
   same 403 for a missing token as for a wrong one. This is checked *before* the method check:
   answering 405 first told an unauthenticated prober which paths exist.
3. **Method.** `POST` for `/ask`, `/control`, `/summarise` and `/shot`, `GET` for everything
   else.
4. **Same-origin, POST only.** `Sec-Fetch-Site` must read `same-origin` when the browser sends it; failing that,
   `Origin` is matched against `Host`. Either mismatch is a `403`. A client sending neither —
   curl, a script, the tests — is let through. Reading is deliberately not gated this way: a
   hostile page cannot read a cross-origin response without a CORS header this server never
   sends, and refusing a cross-site GET would break following a link to the page.
5. **`Content-Type: application/json`, POST only**, `415` otherwise. The second half of the
   same-origin defence and the half that does not depend on the browser volunteering
   anything: the three content types a cross-origin POST may carry without a preflight are
   all refused, and this server answers no preflight because `OPTIONS` is not an allowed
   method.
6. **This machine, `/shot` only** — checked inside that route's handler, so after every gate
   above, and before the body is parsed. Three parts. The connection's remote endpoint must
   be `127.0.0.1`, `::1`, or the first of those as an IPv4-*mapped* IPv6 address, which
   Network.framework's own `isLoopback` does not recognise and a dual-stack listener can hand
   over. Not the IPv4-*compatible* `::127.0.0.1`: `asIPv4` converts that form too, and the
   kernel, which drops `::1` and mapped sources arriving off the wire, has its check for that
   one compiled out. Then the request must carry neither `Origin` nor `Sec-Fetch-Site` — a
   browser is refused as such, because a rebound `.local` name delivers a same-origin page
   that connects *from* this machine, and nothing in a browser is a client of this route. And
   `Host` must be `127.0.0.1` or `[::1]` by address. All of it applies whatever the listener is
   bound to: under `--listen` anyone holding the token can read the transcript, and that must
   not extend to making the Mac photograph its own screen. It is the only route that looks at
   who is asking rather than at what they sent.

| Route | Method | Behaviour |
| --- | --- | --- |
| `/` | GET | `Page.render(hangoverMilliseconds:)` — the embedded page with the endpointer's hangover substituted in. |
| `/events` | GET | Opens the SSE stream, registers the connection, and replays the backlog from `Last-Event-ID` or `?after=`. An unusable cursor falls through to the whole backlog. |
| `/ask` | POST | Starts an answer and returns `202` immediately. The answer itself streams over `/events` to *every* open page, so a phone and a laptop show the same thing because they are the same path, not two kept in step. `503` when no `AskHandler` is configured. |
| `/control` | POST | Applies a capture change and replies with the resulting state as JSON — request/response rather than a stream, because the page must know the change landed before it repaints the button. `503` unconfigured, `400` on a body it will not parse. A body carrying only a `scroll` anchor is relayed live to other pages and answered `200`. |
| `/summarise` | POST | Asks for the end-of-call notes and returns `202`; they stream back as `summary_*` frames. The handler is called *before* the `202` is sent — the opposite order to `/ask`. `503` unconfigured. |
| `/shot` | POST | Asks the running wngmn to take a picture of the screen: `{"mode":"screen"}` or `{"mode":"region"}`, `400` for anything else, `403` from anywhere but this machine, `503` unconfigured. Handler before `202`, as for `/summarise`, and the handler must return at once: it runs on `wngmn.serve`, the one serial queue that carries the listener and every connection, and a region shot can sit under a crosshair for a minute. The picture never crosses this server in either direction — the request is a few bytes and the reply is `{"ok":true}` — which is the reason for the design: `receive` drops anything over 64 KB and decodes bodies as UTF-8. |
| anything else | — | `404`. |

Connection-level rules worth knowing before touching `receive`: bytes are accumulated and
decoded once (TCP splits where it likes, and a multibyte character straddling two reads
becomes U+FFFD — a question reaching the model corrupted); a header block over 64 KB is
dropped; a connection that has not produced a complete request within 15 seconds is
cancelled, and only the read phase is bounded, because a routed connection may be an event
stream living for hours; `HTTPRequest.parse` distinguishes *incomplete* from *malformed*,
because "keep reading" and "hang up" are different answers.

One answer per question is enforced server-side, in `answer(payload:on:)`. Two devices with
prefetch on both ask the instant a question lands, and a page's own latch cannot close until
the first token comes back, so the server is the only place that can refuse. A second ask
under an existing key with the same text is accepted and ignored; differing text is a
revision **only if its `t1` is later**, in which case the in-flight answer is cancelled and
everything it still emits is dropped by generation number.

A 20-second keep-alive comment frame goes out on every open stream. A quiet stretch of
interview is exactly when a NAT table or a phone's radio drops an idle connection.

## Platform lessons

Each of these looks like flakiness from outside, and each has a specific cause. They are
documented at length at their call sites; this is the index.

**The tap only clocks while the tapped device is running.** With the speakers idle,
`AudioDeviceStart` returns `noErr`, `kAudioDevicePropertyDeviceIsRunning` reads 0, and the
IOProc fires *zero times, forever*. Measured causally: 0 callbacks over 2 s with idle
speakers, 202 callbacks after attaching a silent output IOProc to them. Whether something
else happens to be playing is a coin flip, which is why the failure reads as flakiness.
`keepOutputAlive` holds the output device open with a silent IOProc for the whole session.
The same fact is why a naive no-buffer watchdog is actively harmful — it would rebuild the
capture graph during the pause before a question — hence 90 seconds to warn and 240 to
rebuild, with exponential backoff.

**Tap creation succeeding proves nothing.** `AudioHardwareCreateProcessTap` returns a fully
formed tap with a valid format for bundle IDs of apps that are not installed. Only non-zero
samples prove capture works. This, plus the fact that a denied System Audio Recording grant
returns `noErr` from every Core Audio call and yields pure digital silence, is why `selftest`
is an *active* probe: it plays a 440 Hz tone and asserts the tap hears it, and separates "no
buffers at all" (graph not clocking) from "buffers full of zeros" (permission denied),
because the two look identical and have completely different fixes.

**The aggregate's input layout puts the tap last.** An aggregate exposes the union of its
members' streams, and the sub-device's own input buffers come first. Measured: with built-in
speakers (0 inputs) the input configuration is `[(0, 1)]` and the tap is buffer 0; with a
device that has inputs it is `[(0, 2), (1, 1)]` and buffer 0 is that device's *microphone*.
Taking buffer 0 would transcribe the wrong device for the whole interview, silently, because
`readTapFormat()` validates the tap object's format and not the aggregate's layout.
`resolveTapBufferIndex()` takes `count - 1` and refuses to start if the channel count does
not match.

**`mHostTime` is in mach ticks, not nanoseconds.** `mach_timebase_info` is 125/3 on this
hardware — a 24 MHz clock at 41.666 ns per tick — so treating it as nanoseconds is wrong by a
factor of 24. It is also the `CLOCK_UPTIME_RAW` / `SuspendingClock` domain, *not*
`CLOCK_MONOTONIC_RAW` / `ContinuousClock`; never subtract one clock's instant from the
other's. Use `HostClock`, and in particular `HostClock.delta(_:minus:)` — a bare `UInt64`
subtraction of two host times yields about 1.8e19 rather than a small negative number.

**`AssetInventory.status` reports reservation, not installation.** A machine with the model
installed and nothing reserved reads `.supported`, so a readiness check written against the
status value refuses to start where everything in fact works. `Transcriber.isModelInstalled`
resolves the locale and looks for it in `SpeechTranscriber.installedLocales` instead.
Reserving a locale is not required either — verified: a fresh process with no reserved
locales transcribes correctly. Nothing downloads a model except `install-model`, asked for
explicitly, because 396 MB is not a thing to start by accident an hour before an interview.

**Awaiting `finalize(through:)` deadlocks.** It does not return until input past its boundary
has been consumed, so awaiting it inline on the task feeding audio deadlocks the process
outright — verified: zero further results, and a 20 s watchdog had to hard-exit. A background
feeder unblocked the identical inline await in 109 ms. `Transcriber.finalize` is therefore
`nonisolated` and dispatches `Task.detached`. The same property is why
`advance(toStreamSeconds:)` must keep filling silence when the tap stalls: a finalise
requested right after a question — which is exactly when the endpointer fires — would
otherwise never complete, with no error and no result.

**Overlapping analyser input kills the session, not the buffer.** `bufferStartTime` must come
from a contiguous count of frames *in the analyser's own sample rate*. Deriving it from the
48 kHz capture clock is the natural-looking trap: a 512-frame tap buffer resamples to 170 or
171 frames at 16 kHz (170.67 exactly), so a 48 kHz-derived start paired with a 171-frame
buffer covers slightly past the next buffer's start. That terminates `transcriber.results`
with `SFSpeechErrorDomain Code=2` and transcription is over for the rest of the call. The
`Pipeline` notices the stream ending and emits `transcriber_ended`, then exits non-zero.

Three smaller ones in the same family. Forcing a final on a region that begins shortly after
a previous forced boundary — which is what a mid-question hesitation produces — makes the
recogniser return punctuation where its own volatile output for the identical range was
correct; hence the volatile fallback, applied to whole regions and never spliced. Offering a
zero-frame buffer to `AVAudioConverter` as `.haveData` wedges it permanently with no error
anywhere. And `FileHandle.standardOutput.synchronizeFile()` crashes when stdout is a pipe
while working fine on a TTY, so it passes an interactive smoke test and dies the moment
anyone runs `wngmn | jq`.

Finally, two that bite during routine use. A Bluetooth headset used for **both** output and
input switches the link to duplex and the output device's sample rate with it, 48 kHz to 24
on AirPods — but `kAudioTapPropertyFormat` still reports 48, and the IOProc delivers at the
aggregate's rate, not the tap's. Read as 48 kHz that audio played at double speed and the
caller came back as fragments. `SystemAudioTap` now adopts the aggregate's rate,
`DeviceWatcher` rebuilds when the clock device's rate changes mid-call, and
`AudioRoute.duplexHeadset()` names the route at startup and in `devices`, since the caller
arrives at phone quality on it. And a private aggregate device is invisible to
`system_profiler` by construction, so one leaked by a crash would never be noticed —
`sweepLeakedAggregates()` runs at every start and destroys only devices carrying this
program's own `local.wngmn.` UID prefix.

## Suggested reading order

Follow the data, then the seams.

1. `Package.swift` — the target boundaries and why they are where they are, in its own
   comments.
2. `Sources/Engine/WngmnCore/Events.swift` — the published contract. Everything downstream is
   shaped by it.
3. `Sources/Engine/WngmnCore/Endpointer.swift` — the distinctive decision, and pure enough to read
   in one sitting.
4. `Sources/Engine/WngmnCore/QuestionAssembler.swift` — the join between "when it ended" and "what
   was said". Read `Endpointer` first or none of this will land.
5. `Sources/Engine/WngmnCore/RingBuffer.swift` — the real-time boundary, and the contract the tap
   is written against.
6. `Sources/Platform/Apple/WngmnAudio/SystemAudioTap.swift` — the three counter-intuitive facts about the
   capture graph are in the type's own doc comment.
7. `Sources/Platform/Apple/WngmnAudio/AudioClock.swift` — every number in it was measured, and the
   tick-versus-nanosecond distinction underlies every timestamp the tool emits.
8. `Sources/Platform/Apple/WngmnAudio/Transcriber.swift` — forced finalisation, the resampler, and the
   contiguity invariant.
9. `Sources/Platform/Apple/WngmnAudio/Pipeline.swift` — where all of the above is assembled, plus the
   watchdogs. The longest file in `WngmnAudio` and the last one worth reading cold.
10. `Sources/UI/WngmnServe/TranscriptServer.swift` — routing, gating, replay, and the ask
    bookkeeping.
11. `Sources/App/wngmn/Wngmn.swift` — the wiring, which is easiest to follow once you know what
    is being wired.

`Sources/UI/WngmnServe/Page.swift` is the page itself, 1,600 lines of embedded HTML, CSS and
JavaScript. Read it when you are changing the page and not before.

For the test tiers, `Tests/WngmnCoreTests/GoldenVADTests.swift` and
`Tests/WngmnAudioTests/OfflinePipelineTests.swift` show what is asserted without a
permission, and `Tests/WngmnAudioTests/CaptureHealthTests.swift` shows why the watchdog
escalation was extracted into pure functions — so it could be asserted without a capture
graph and a four-minute wait.

## The engine and the platform

Where the line is today, measured rather than hoped for:

- `WngmnCore` imports nothing from Apple but `Darwin`, in one file, to list processes for
  `wngmn stop`.
- `WngmnAsk` streams with `URLSession.bytes(for:)`, which the open-source Foundation does not
  have, and finds a token by running the `ant` command.
- `WngmnServe` has its HTTP and SSE policy in pure Swift, beside one file's worth of
  `Network.framework` listener.
- `WngmnAudio` is two thirds orchestration that happens to construct three Apple types
  itself (the tap, the microphone and the recogniser), and one third those types.
- The executable is mostly session wiring that an engine should own and test.

The work that moves each of these across is done one pull request at a time, each leaving
macOS green and installable. A Linux job in CI builds and tests whatever has already crossed,
because a layer only one operating system ever compiles is a layer in name only.
