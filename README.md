# wngmn

A macOS command-line tool that listens to the person on the other end of a Zoom or Meet call,
transcribes them on-device, and decides the moment their question has ended.

Live captions tell you what is being said. They do not tell you when a question is *over*, which
is the only thing that matters if something has to react to it. wngmn does that endpointing
itself and emits one structured event per question 67–121 ms after the endpoint fires; waiting
for the Speech framework's own `isFinal` instead costs 857–921 ms after the last speech sample.
Audio never leaves the machine.

## What it looks like

JSON Lines on stdout, one object per line, so anything downstream — `jq`, a test harness,
another program — consumes it without coupling to internals. Diagnostics go to stderr, so a
pipe stays clean.

```json
{"type":"status","state":"capturing","format":{"rate":48000,"ch":1}}
{"type":"partial","text":"so tell me about the","t":12.31}
{"type":"question","text":"So tell me about the funding round.","t0":10.88,"t1":13.02,"ms":74}
{"type":"question","text":"So tell me a bit about the funding round you just closed.","t0":10.88,"t1":16.21,"ms":66,"revises":true}
{"type":"question","text":"Are you able to hear me properly?","t0":27.19,"t1":29.26,"ms":94,"volatile":true}
{"type":"warning","code":"no_audio","detail":"no buffers for 92s; deviceAlive=true ioProcRegistered=true"}
```

`ms` is the measured endpoint-to-final latency for that question. `revises` marks a question
that supersedes the previous one rather than following it — the speaker paused mid-sentence and
carried on. `volatile` marks one whose wording came from the volatile stream and is less
trustworthy than usual. The full contract is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

`--help` and the source call this **stage 1** — capture, transcribe, endpoint, print. Stage 2 is
a separate downstream program, a message bank and an on-screen overlay, that consumes these lines
rather than linking against internals; that is why the shape is a published contract down to key
order. Nothing in this repository is stage 2, and stage 1 is useful on its own.

`--serve` puts the same stream on a page at `http://127.0.0.1:7373` — finished questions with
their latency, a live caption line, warnings, and latency charted against the 700 ms budget. It is
embedded in the binary and fetches nothing, so it works with no network. `--listen` binds the
network instead of loopback, with a token in the printed URL, so a phone or iPad can read it —
which is also the only way to be *certain* the transcript is not on screen if the call is ever
screen-shared: an overlay can be excluded from capture, a browser window on the shared screen
cannot. The page is what you actually look at for the whole interview;
[docs/PAGE.md](docs/PAGE.md) describes it control by control.

## Requirements

* macOS 26. `Package.swift` pins `platforms: [.macOS(.v26)]` and there is no fallback path for
  anything older. No architecture is pinned and `Scripts/build-app.sh` produces a universal
  binary by default, but everything here was built and measured on Apple Silicon only.
* A Swift 6.2 toolchain; the package builds in Swift 6 language mode with warnings as errors.
* No third-party dependencies. `Package.swift` has none: the HTTP/1.1 and Server-Sent Events
  server, the argument parser and the Claude client are hand-rolled on Apple frameworks, so a
  clean machine builds with no network fetch.
* A speech model for your locale, installed before the first run. It is an unconditional
  prerequisite rather than something fetched on demand: `Pipeline.requireModel` runs before
  capture starts, so on a machine without it the run ends there with a non-zero exit and this
  on stderr:

      wngmn: speech model unavailable: en-US is not installed (installed: ); run `wngmn install-model --locale en-US`

  Failing there is the point — starting anyway means transcribing digital silence for the
  length of a call. `wngmn install-model --locale en-US` fetches it from Apple (396 MB, which
  is why nothing downloads it implicitly), and the same command is how you check: with the
  model already present it prints `wngmn: en-US is already installed; nothing to do.` and
  downloads nothing.
* Capture, transcription and endpointing need no credentials at all. Only the Ask button does —
  it reads `ANTHROPIC_API_KEY`, then `ANTHROPIC_AUTH_TOKEN`, then the profile written by
  `ant auth login`.

## Install and quick start

Building from source is the only way to install wngmn. There are no releases, no prebuilt
binaries and no Homebrew tap, and there will not be: the app bundle is ad-hoc signed, so it is
trusted by the machine that built it and no other, and distributing one would need a Developer
ID certificate and notarisation that this project does not set up.

```sh
swift build -c release
./.build/release/wngmn selftest     # go/no-go gate; run it by path
./.build/release/wngmn --serve
```

Run `selftest` **by path**, not as a bare `wngmn`: a bare name resolves through `$PATH` to
whatever `Scripts/install.sh` last installed, which is a different binary from the one you just
built, holding a different permission grant.

`Scripts/install.sh` is an optional extra step, not the normal way to install. All it buys you
is identity: it builds and installs a signed `wngmn.app` into `/Applications`, so the System
Audio Recording grant belongs to wngmn under its own name and at a fixed path, rather than to
whichever terminal launched it. Everything above works without it. See
[docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## Commands and flags

| Command | |
| --- | --- |
| `run` (default) | capture, transcribe, endpoint, emit questions |
| `selftest` | play a 440 Hz tone and assert the tap hears it |
| `devices` | list audio processes, their bundle IDs, and every device |
| `offline <file>` | run a recording through the same pipeline; needs no permission |
| `miccheck` | measure this room and this voice, print the `--mic-open-db` to use |
| `stop` | stop every running wngmn and release its audio devices |
| `install-model` | download the speech model for `--locale` |

| Flag | |
| --- | --- |
| `--serve`, `--port <n>`, `--listen` | serve the transcript; bind the network for a second device |
| `--bundle-id <id>`, `--global` | which app to tap (default: Zoom and Chrome, several processes each) |
| `--mic`, `--mic-device <uid>` | also capture your microphone as a second speaker |
| `--profile <name>`, `--notes <path>` | the prepared material answers draw on |
| `--ask-model <id>` | which model answers (default `claude-opus-5`) |
| `--ask-effort <level>` | `low` (default) to `max`; low because latency is the constraint |
| `--hangover-ms <n>` | silence before a question is considered over (default 250) |
| `--no-log`, `--resume`, `--log-dir <path>` | the on-disk transcript |

Seven flags turn `--serve` on by themselves — `--port`, `--listen`, `--token`, `--new-token`,
`--start-paused`, `--resume` and `--log-dir` — and `--mic-device` turns on `--mic`. Each of
them is meaningless without the thing it implies, and the alternative is a silent no-op: a
token means nothing until the port is on the network, and the log exists to catch a
reconnecting page up, so `--resume` with no server used to write no file, restore nothing, and
say nothing about either.

`wngmn --help` prints the full surface of flags. Three endpointer values have no flag at all —
the analysis window, the hysteresis and the noise margin — because moving them has never been
needed; they are in `EndpointerConfig` if a room ever demands it.
[docs/TUNING.md](docs/TUNING.md) covers all of them, and which are worth moving and what to
measure.

## How it works

A Core Audio process tap, scoped by bundle ID, mixes the conferencing app's output into a ring
buffer without opening a microphone. An RMS endpointer runs over 10 ms windows and decides when
speech has started and stopped; at the stop it calls `finalize(through:)` on the Speech
framework's analyser instead of waiting for the framework to decide on its own, which is where
the latency comes from. A pause shorter than the merge window is a hesitation rather than an
ending, so the continuation is stitched back on and re-emitted with `revises`.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the detail, including why the tapped output
device is held open with a silent IOProc.

## Permission

System Audio Recording is granted to the *parent process*, so a shell-launched `wngmn` runs on
the terminal app's grant, not its own. A denial is silent in the worst possible way: every Core
Audio call still returns `noErr` and the stream is pure digital silence, indistinguishable from a
quiet room. That is why `selftest` plays a real tone and asserts the tap hears it, and why it is
worth running on the morning of an interview — [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## What leaves the machine

* **Audio never does.** Buffers are processed in memory and discarded; nothing is recorded, and
  the tap and the transcriber both run locally with no network.
* **Pressing Ask sends text.** The question, up to six preceding questions, and your notes or
  profile go to the Claude API, and the answer streams back. Nothing is sent until you press the
  button — unless you turn on the prefetch toggle in the page header, which starts answering
  every *caller* question as it lands, so questions you would never have asked about are sent
  too. Lines from your own microphone are never prefetched; the page checks the speaker first,
  so `--mic` does not double the traffic.

  Prefetch exists because it is the whole difference between Ask being instant and Ask being a
  round trip: the latency hides behind your decision to press rather than behind the request.
  It is off by default because it costs one API call per question, including the many that
  never need one.
* **`install-model` downloads from Apple.** Explicit, and only that command.
* **The transcript is written to disk, but only when the server is running.** The log is opened
  inside `startServerIfRequested`, so a plain `wngmn run` with no `--serve` writes no session
  file at all. With `--serve`, sessions land under
  `~/Library/Application Support/wngmn/sessions/`, so a run that dies mid-call can be resumed
  with `--resume`. `--no-log` turns it off; `--log-dir` moves it.
* **`--listen` puts the page on your local network**, gated by a token that appears in the
  printed URL. Without it the server binds loopback only.

## Scope

wngmn is built for the case where you supply the substance in advance and the tool retrieves it
at the right moment: press and podcast interviews, panels, rehearsal against a recording of one.
That is what the profile format is shaped around, and answers are only ever as good as the
material you wrote into it.

The mechanism has no idea what kind of conversation it is in. It hears audio the machine is
already playing, and a call is a call. Nothing in the code distinguishes an interview from an
exam, a certification, or a technical screen, and nothing in it could — so where the tool is
appropriate is a judgement you make, under whatever rules apply to the conversation you are in,
and not one this repository can make for you.

The author's own position, stated plainly so the paragraph above is not mistaken for
indifference: it is not for assessments.

## Contributing

```sh
swift build -c release
swift test                        # 407 tests; needs no audio permission
./.build/release/wngmn offline clip.wav   # the real pipeline, without the tap
```

`WngmnCore` is deliberately free of Core Audio and Speech, which is what lets its tests —
endpointing, text repair, the ring buffer, the output protocol — run in any terminal. The tier
that cannot be automated is a live rehearsal on a real call.

`offline` needs no audio permission, because it never opens the tap — but it does need the
speech model. It runs the same `Pipeline.requireModel` check a live run does and stops with the
same message without it, so install the model before you reach for it. `swift test` needs no
audio permission either, but four of its suites drive the real recogniser and fail without the
model, so install it before running the full suite.

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest: the toolchain, what the test tiers cover, and
the things about the source that are not obvious from reading it.
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to everyone taking part.

## Security

The surface worth attention is the served page: `--listen` exposes a transcript of someone
else's words on your local network, gated only by the token. If you find a way past it, use
GitHub's private vulnerability reporting on this repository rather than a public issue.
[SECURITY.md](SECURITY.md) sets out what is in scope, what the tool sends where, and the
failure modes worth knowing about before a real call.

## Licence

MIT. See [LICENSE](LICENSE).
