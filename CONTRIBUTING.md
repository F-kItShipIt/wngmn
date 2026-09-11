# Contributing to wngmn

wngmn listens to the audio a conferencing app is playing, transcribes it on-device, and
decides when the other person's question has ended. The endpointing is the hard part; most
of the rest exists to keep it honest. Contributions are welcome, and the notes below are
mostly about the things that are not obvious from the source.

## What you need

* **macOS 26.** `Package.swift` pins `platforms: [.macOS(.v26)]`, and the system-audio tap,
  `SpeechTranscriber` and the aggregate-device handling are all macOS-26-era APIs. There is no
  fallback path for older systems. Nothing pins an architecture — `Scripts/build-app.sh`
  defaults to a universal `arm64 x86_64` build — but every measurement recorded in the
  comments was taken on Apple Silicon, so a report from an Intel Mac is genuinely new
  information.
* **A Swift 6.2 or newer toolchain.** `// swift-tools-version: 6.2`, and every target is
  built in Swift 6 language mode with warnings treated as errors. The toolchain this was
  last built with reports `Apple Swift version 6.3.3`, target `arm64-apple-macosx26.0`.
* **The en-US on-device speech model.** Install it once with
  `swift run wngmn install-model --locale en-US`. It is a 396 MB download, which is why
  nothing downloads it implicitly. This is a prerequisite for the tool, not for a test tier:
  `Pipeline.run` calls `requireModel` before it starts capture and throws
  `Transcriber.Failure.modelUnavailable` if the locale is not installed, so a live run does
  not start at all without it. `offline` goes through the same check, in `OfflineRunner`.
  The message names the installed locales and the command to fix it, because failing fast is
  the only alternative to transcribing silence for a whole call and finding out afterwards.
  `selftest`, `devices`, `miccheck` and `stop` do not touch the recogniser and need no model.
* **Node**, for the embedded page's tests. Without it those tests are skipped rather than
  failed: 76 of the 81 `@Test` declarations in `PageTests.swift` carry
  `.enabled(if: PageTests.nodeIsAvailable)`, which shells out to `node --version` and reports
  false if that fails. The other five assert against `Page.html` as a Swift string — that an
  element id is present, that every heading level has a style — and need nothing. Everything
  else still runs.

There are **no third-party dependencies**, and that is a constraint rather than an accident:
`swift build` works on a machine with no network at all. The HTTP/1.1 and Server-Sent Events
server in `WngmnServe` is hand-rolled on Network.framework for exactly that reason. A pull
request that adds a package to `Package.swift` needs to argue the point first.

## Build and run

```sh
swift build                     # debug
swift build -c release          # what you should actually test against
./.build/release/wngmn selftest # the go/no-go gate; see Permission below
./.build/release/wngmn
```

The five targets and what each may touch:

| Target | Contents | Constraint |
| --- | --- | --- |
| `WngmnCore` | Endpointer, question assembler, text normaliser, ring buffer, options, events | Deliberately free of Core Audio and Speech, so its tests run in any terminal |
| `WngmnAudio` | Process tap, clocks, capture timeline, transcriber, pipeline, offline runner | The only target that touches the system |
| `WngmnServe` | HTTP/1.1 + SSE listener and the embedded page | Depends on `WngmnCore` only — it renders events, it does not know where they came from |
| `WngmnAsk` | Claude credentials, prompt assembly, streaming | Kept apart from `WngmnServe` on purpose, so the Claude dependency stays on one side of that line |
| `wngmn` | The executable: `run`, `selftest`, `devices`, `offline`, `miccheck`, `stop`, `install-model` | Wiring and command dispatch |

If you find yourself importing AVFoundation or Speech into `WngmnCore`, that is the signal
that the logic and the system call have not been separated yet, not that the rule is wrong.

## The four test tiers

```sh
swift test                              # everything the machine can run
swift test --filter WngmnCoreTests      # unit + golden VAD
swift test --filter WngmnServeTests     # server, token store, page
swift test --filter WngmnAudioTests      # includes the four model-backed suites
swift test --filter OfflinePipelineTests # offline replay; needs the en-US model
```

1. **Unit.** Pure logic in `WngmnCoreTests`, `WngmnServeTests`, `WngmnAskTests`, and the
   parts of `WngmnAudioTests` that exercise arithmetic and state machines — the clock, the
   capture timeline, the silent-capture and route-conflict detectors. No audio permission,
   no device, no model.
2. **Golden file.** `GoldenVADTests` replays real recorded speech through the real
   endpointer. The fixtures are headerless 16 kHz mono little-endian Int16, produced with
   `say`, and they open and close with silence because a live call does — the tap is already
   running before the other person starts talking, and the hangover has to complete after
   they stop. No audio permission.
3. **Offline replay.** Four suites, all driving the real recogniser over recorded speech.
   `OfflinePipelineTests` runs the whole pipeline except the tap — resampler, real
   `SpeechTranscriber`, endpointer, assembler, event writer — and two more suites in the same
   file, `ContinuationWindowTests` and `HangoverPauseTests`, go through the same runner to
   pin what the merge window and the hangover do to a real mid-sentence pause.
   `TranscriberTimelineTests` runs
   a narrower thing: where the recogniser's own timestamps land on the shared capture
   timeline when a source starts after the origin, or before it. Neither needs an audio
   permission, both need the en-US model installed, and neither skips when it is missing —
   they fail. Install the model before running the full suite. The pipeline path is also
   available from the command line, which is how a rehearsal recording gets retuned without
   booking another call:

   ```sh
   swift run wngmn offline clip.wav          # 8x real time, the default
   swift run wngmn offline clip.wav --speed 1
   ```

   The pacing is not cosmetic. The endpointer forces finalisation 250 ms after speech stops,
   and the recogniser has to have decoded that speech by then; feeding a whole file at once
   puts the forced finalise far ahead of the decoder.
4. **Live rehearsal.** A real call, on a machine with a real permission grant. This is the
   only tier that exercises TCC, device changes mid-call, and genuine conversational speech,
   and it is not automatable. If you change anything in the tap, the aggregate device, the
   keepalive IOProc or the route watcher, rehearse it and say so in the pull request — the
   unit tiers cannot tell you that a tap stopped clocking.

### Permission, and why `selftest` plays a tone

System Audio Recording is granted to the **parent** process. Run wngmn from a shell and the
grant belongs to your terminal app; launch the signed bundle that `Scripts/install.sh`
builds and it is its own subject under its own name. Either way, a denial is silent: every
Core Audio call still returns `noErr`, the stream keeps clocking, and every sample is zero.

That is why `wngmn selftest` plays a known tone and asserts the tap hears it. A passive "did
we see three seconds of zeros" check cannot work, because a quiet room and a denied
permission are the same bytes. Grant the permission in System Settings → Privacy & Security
→ Screen & System Audio Recording, then quit and reopen the terminal — the grant is read at
launch — and run the selftest by path so you are testing the binary you just built rather
than whatever is on `$PATH`.

Ordinary development does not need any of this. Tiers 1 to 3 run in any terminal, which is
the point of keeping `WngmnCore` free of the audio frameworks.

## House conventions

**Swift 6 language mode, warnings as errors.** This is not tidiness. The data-race
diagnostics that matter here — sending a buffer pointer across an isolation boundary, a
global `var` silently inferred `@MainActor` — are the ones that produce a crash on the audio
thread rather than a compile failure. Do not silence one; fix the ownership.

**Comments explain why, and cite the measurement or the failure.** The codebase's comments
are its best documentation, and they are written to a standard: name the number you measured
or the failure you observed. Compare

```swift
// Preload the model.
```

with the comment that is actually there:

```swift
/// Builds the resampler and preloads the model. Call before the first buffer:
/// `prepareToAnalyze` costs 51–59 ms that would otherwise land on the first question.
```

The second one survives a refactor because it says what would break. If you cannot cite a
number or a failure, the comment is probably restating the code and can go.

**Test names read as behaviours.** `@Test("Two spoken questions come out as two questions
with the right words")`, `@Test("A revision replaces the last row from the same speaker")`,
`@Test("An anchor past the end clamps instead of throwing")`. Not `testTwoQuestions`. The
name is the specification; when it fails in isolation on someone else's machine, the
name is all they have.

**A bug fix starts with a failing test.** Write the test that reproduces the defect, watch it
fail, then fix it. Several suites here are explicitly regression suites and say so in their
header comment — `CaptureHealthTests` opens by describing the two multi-hour runs that
stalled with `deviceAlive=true ioProcRegistered=true` while the page kept showing a green
"capturing" pill. That comment is why the test cannot be deleted by someone who does not
know the history.

**British spelling and em-dashes** in prose and comments, to match what is already there.

## Working on the embedded page

The transcript page lives in `Sources/WngmnServe/Page.swift` as a Swift string literal, so
nothing on the way in compiles its JavaScript. A stray escape produces a page that returns
200, renders its markup, and runs none of its script — the transcript simply never fills in.
That has been shipped once already. Two things guard it:

* `PageTests.scriptParses` extracts the last `<script>` body and runs `node --check` over it.
* `PageTests.evaluate` runs the same script under Node with the browser globals it touches at
  load stubbed out — `document`, `window`, `navigator`, `EventSource` — and returns what an
  expression printed, so the page's pure helpers (`md()`, `nextSelection()`, the revision and
  scroll-anchor logic) are asserted on from Swift, where the rest of the suite lives.

Practical consequences when you edit the page:

* Keep the logic worth testing in pure helpers that take arguments and return values. Only
  the DOM wiring around them needs a browser, and only that part goes untested.
* The stubs are deliberately minimal. If your change reaches for a new browser global at
  load, add it to `PageTests.stubs` — and note the comment there about `navigator`: Node
  ships a read-only one, and a plain assignment fails silently.
* The page loads nothing from the internet, by design, so that it works on a machine with
  none. No CDN, no font fetch, no framework.
* Run `swift test --filter PageTests` with Node on `$PATH` before you push. The tests skip
  silently without it, and skipping looks exactly like passing in the summary line.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request, on a
`macos-26` runner, with a 30-minute timeout, `contents: read` and a concurrency group that
cancels the previous run on the same ref. The image is the whole reason this is possible:
`Package.swift` declares `platforms: [.macOS(.v26)]`, so nothing older compiles at all.

Four steps:

* **Toolchain** — `xcode-select -p` and `swift --version`, printed rather than pinned. A path
  like `/Applications/Xcode_26.1.app` breaks the day the image bumps its point release, and a
  wrong-toolchain failure is legible from the printed version anyway.
* **Build** — `swift build -c release`. There are no dependencies to resolve, so this is a
  cold compile of our own code and nothing else, and warnings are errors, so a warning fails
  the job.
* **Node present** — `node --version`, and the job fails if it is missing. 76 of the 81
  tests in `PageTests.swift` are gated on `.enabled(if: PageTests.nodeIsAvailable)`, which
  shells out to exactly that, and a skipped test is indistinguishable from a passing one in
  the summary line. Failing loudly beats a green tick that checked less than it looks like.
* **Test** — `swift test` with the four model-backed suites skipped by name.

What it does not run, and why:

* **The four model-backed suites.** `OfflinePipelineTests`, `ContinuationWindowTests`,
  `HangoverPauseTests` and `TranscriberTimelineTests` need the en-US model and a clean
  runner has none. They are named individually because `--skip` matches the suite type, and
  three of the four live in one file.
  `wngmn install-model --locale en-US` would fetch one, but that is a 396 MB Apple asset
  download on every run which can fail for reasons that have nothing to do with the change
  under test. They are skipped rather than installed, which is why the pull-request template
  asks you to tick that you ran the full `swift test` locally.
* **`wngmn selftest`, and everything above it.** System Audio Recording is a TCC grant to the
  launching process and there is nobody on a runner to approve the prompt — and a denial
  returns `noErr` from every Core Audio call, so a "passing" selftest there would mean
  nothing at all. That tier stays manual, on a real machine.

Gating the four model suites instead of skipping them — install the model once, cache it, and
run them when the cache is warm — is a welcome contribution. Gate on
`Transcriber.isModelInstalled`, and not on the API that looks like the obvious one:
`AssetInventory.status` reports *reservation*, not installation. A fresh process that has
reserved no locales reads `.supported` on a machine where the model is installed and
transcription works perfectly, so a job gated on that value would refuse to start where
everything is fine. `isModelInstalled` checks `SpeechTranscriber.installedLocales` instead,
which is the list that answers the question actually being asked.

### The rest of `.github`

* `ISSUE_TEMPLATE/bug_report.yml` asks for the macOS version and Mac model, how you launched
  it — from a shell or from the bundle `Scripts/install.sh` builds, which decides who holds
  the System Audio Recording grant and is the most common cause of silent capture — the
  `selftest` output, the `status`, `warning` and `question` JSON Lines around the problem, and
  stderr. It opens by asking you to redact question text to `[redacted]`; the timings and
  flags are what diagnose the bug, and the words are somebody's interview.
* `ISSUE_TEMPLATE/feature_request.yml` asks for the failure in a real interview before the
  proposal, and has checkboxes for the two constraints anything new has to respect: no audio
  or transcript leaves the machine, and no third-party package dependency.
* `ISSUE_TEMPLATE/report.yml` is for everything that is neither a bug nor a proposal — a
  rehearsal report, or a measurement that contradicts something written here. It asks what
  you did and saw, the numbers if you have any, and the build, and nothing else.
* `pull_request_template.md` is the verification checklist from this file in short form.

CI is the floor. It cannot tell you that a tap stopped clocking, so say what you ran.

## Where the rest is written

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the five targets, why the boundaries are
  where they are, the live data path, the concurrency model, and the platform lessons worth
  not rediscovering. Read it before changing anything.
* [docs/PERMISSIONS.md](docs/PERMISSIONS.md) — who actually holds the audio grant, and the
  routes that silence the tap with no error anywhere.
* [docs/TUNING.md](docs/TUNING.md) — every endpointer knob and the measurements behind its
  default.
* [docs/PAGE.md](docs/PAGE.md) — the served page, which has more behaviour in it than any
  other single file.

## What a good pull request looks like

* **One change.** A fix to the endpointer and a tidy-up of the page are two pull requests.
* **The failing test first**, in the same pull request as the fix, so a reviewer can check
  out the parent commit and watch it fail.
* **`swift build -c release` clean**, with warnings as errors, and `swift test` passing. Say
  in the description which tiers you ran and which you could not: "unit and golden file;
  offline replay with the en-US model; no live rehearsal" is a useful sentence, and an honest
  one.
* **Rehearsal notes for anything touching capture.** Which app, which devices, how long, what
  you watched for. `wngmn devices` output is often the fastest way to show what you tested
  against.
* **Numbers where you changed behaviour.** The defaults here were measured, not guessed — the
  250 ms hangover exists because a mid-sentence pause measures 530 ms on the test recording
  and two separate questions measure 1.2 s apart, so no single threshold separates them. If
  you move a default, show the measurement that moved it.
* **No new dependency** unless the pull request makes the case for it.
* **Commit messages that say what changed and why**, in the present tense, matching the log.

Questions, measurements that contradict something written here, and rehearsal reports are all
worth opening an issue for, even with no patch attached. A reproducible failure on a real
call is the most valuable thing anyone can send.

## Conduct, and what not to put in a public issue

The expectations for taking part are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and they
are short.

Do not open a public issue for a vulnerability, or for anything that would let someone else
reach a transcript, a serve token or the Anthropic credential.
[SECURITY.md](SECURITY.md) has the private route — GitHub's private vulnerability reporting
on this repository — and what to include. The same care applies to ordinary issues: this tool
handles interview audio, and a bug report with real question text in it has published
somebody's interview to fix a timing bug.

## Licence

By contributing you agree that your contributions are licensed under the MIT Licence, the
same terms as the rest of the project. See [LICENSE](LICENSE).
