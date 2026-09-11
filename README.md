# wngmn

**Hears the question on a call, transcribes it on your Mac, and knows the moment it ended.**

Live captions tell you what was said. They don't tell you when a question is *over*, which is
the only thing that matters if something has to react to it. wngmn endpoints the question
itself instead of waiting on the Speech framework. Audio never leaves your machine.

![The wngmn page: an answer on the left, latency and the question list on the right](docs/images/page.png)

<sub>An offline replay of a test fixture, not a live call.</sub>

## Requirements

- macOS 26, and a Swift 6.2 toolchain.
- No third-party dependencies. A clean machine builds with no network fetch.
- A speech model, installed once. Step 2 below.
- No credentials, except for the Ask button.

## Install

Build from source. There are no releases or Homebrew tap: the bundle is ad-hoc signed, so it is
trusted only by the machine that built it.

**1. Build.**

```sh
git clone https://github.com/skhan75/wngmn.git
cd wngmn
swift build -c release
```

**2. Install the speech model.** 396 MB from Apple, which is why nothing fetches it implicitly.
Without it a run stops immediately rather than transcribing silence for a whole call.

```sh
./.build/release/wngmn install-model --locale en-US
```

**3. Check the audio tap.** This plays a tone and asserts the tap heard it.

```sh
./.build/release/wngmn selftest
```

Run it **by path**. A bare `wngmn` resolves through `$PATH` to whatever was installed last,
which is a different binary holding a different permission grant.

If it fails, macOS denied System Audio Recording. The grant belongs to your *terminal app*, not
to this binary, and a denial is silent: every Core Audio call still returns success and the
stream is digital silence. That is why this check exists —
[docs/PERMISSIONS.md](docs/PERMISSIONS.md).

**Optional:** `Scripts/install.sh` installs a signed `wngmn.app` into `/Applications`. It buys
identity only — the grant belongs to wngmn under its own name, at a fixed path. Everything here
works without it.

## Use it

```sh
# Normal use: transcript on a page at http://127.0.0.1:7373
./.build/release/wngmn --serve

# Both sides of the call, each line labelled Caller or You (assumes headphones)
./.build/release/wngmn --serve --mic

# With prepared material, so Ask has something to answer from
./.build/release/wngmn --serve --profile profiles/system_design.md

# Read it on a phone, so it isn't on the screen you're sharing
./.build/release/wngmn --serve --listen

# Rehearse against a recording; needs no audio permission
./.build/release/wngmn offline clip.wav --serve
```

`wngmn --help` prints every flag.

## The page

Embedded in the binary, fetches nothing, works offline. It is what you look at for the whole call.

- Questions as they finish, each with its latency and an **Ask** button.
- A live caption line for the sentence in progress.
- Latency charted against the 700 ms budget.
- Warnings, such as the tap going quiet mid-call.
- `j` / `k` to select a line, `Enter` to ask.

[docs/PAGE.md](docs/PAGE.md) covers it control by control.

## Flags worth knowing

| Flag | |
| --- | --- |
| `--serve`, `--port <n>`, `--listen` | serve the transcript; bind the network for a second device |
| `--mic`, `--mic-device <uid>` | also capture your microphone as a second speaker |
| `--profile <name>` | prepared material answers draw on |
| `--bundle-id <id>`, `--global` | which app to tap (default: Zoom and Chrome) |
| `--hangover-ms <n>` | silence before a question counts as over (default 250) |
| `--ask-model <id>`, `--ask-effort <level>` | which model answers, and how hard it thinks |
| `--no-log`, `--resume`, `--log-dir <path>` | the on-disk transcript |

`--port`, `--listen`, `--token`, `--new-token`, `--start-paused`, `--resume` and `--log-dir` all
imply `--serve`; `--mic-device` implies `--mic`. `--profile` supersedes `--notes`.

## Commands

| Command | |
| --- | --- |
| `run` (default) | capture, transcribe, endpoint, emit questions |
| `offline <file>` | run a recording through the same pipeline; needs no permission |
| `selftest` | play a tone and assert the tap hears it |
| `devices` | list audio processes, bundle IDs, and every device |
| `miccheck` | measure this room and this voice, print the `--mic-open-db` to use |
| `install-model` | download the speech model for `--locale` |
| `stop` | stop every running wngmn and release its audio devices |

## Output

JSON Lines on stdout, one object per line. Diagnostics go to stderr, so a pipe stays clean.

```json
{"type":"question","text":"So tell me about the funding round.","t0":10.88,"t1":13.02,"ms":74}
{"type":"question","text":"So tell me a bit about the funding round you just closed.","t0":10.88,"t1":16.21,"ms":66,"revises":true}
{"type":"warning","code":"no_audio","detail":"no buffers for 92s"}
```

- `ms` — measured endpoint-to-final latency for that question.
- `revises` — supersedes the previous line rather than following it. The speaker paused
  mid-sentence and carried on.
- `volatile` — the wording came from the volatile stream and is less trustworthy.

## What leaves the machine

- **Audio never does.** Buffers are processed in memory and discarded. Nothing is recorded.
- **Ask sends text** to the Claude API: the question, up to six preceding ones, and your
  profile. By default this happens only when you press the button.
- **The prefetch toggle removes that guarantee.** It answers every caller question as it lands,
  including ones you'd never have asked. Off by default; it costs an API call per question.
- **`install-model` downloads from Apple.** Explicit, and only that command.
- **The transcript hits disk only with `--serve`**, under
  `~/Library/Application Support/wngmn/sessions/`, so a run that dies mid-call can resume.
  `--no-log` turns it off.
- **`--listen` puts the page on your local network**, gated by the token in the printed URL.

## Scope

wngmn is for the case where you supply the substance in advance and the tool retrieves it at the
right moment: press and podcast interviews, panels, rehearsal against a recording.

The mechanism has no idea what kind of conversation it is in. Nothing in the code distinguishes
an interview from an exam or a technical screen, and nothing in it could. Where the tool is
appropriate is your judgement, under whatever rules apply to the conversation you are in.

The author's own position, so the above is not mistaken for indifference: it is not for
assessments.

## Docs

| | |
| --- | --- |
| [PERMISSIONS](docs/PERMISSIONS.md) | why a denial is silent, and how to get the grant |
| [PAGE](docs/PAGE.md) | the page, control by control |
| [TUNING](docs/TUNING.md) | endpointer values, which are worth moving, what to measure |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | the tap, the ring buffer, forced finalisation, the event contract |

## Contributing

```sh
swift test          # 407 tests; needs no audio permission, but four suites need the model
```

`WngmnCore` is deliberately free of Core Audio and Speech, which is what lets its tests run in
any terminal. The tier that cannot be automated is a live rehearsal on a real call.

[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to everyone taking part.

## Security

`--listen` exposes a transcript of someone else's words on your local network, gated only by the
token. If you find a way past it, use GitHub's private vulnerability reporting rather than a
public issue. [SECURITY.md](SECURITY.md) has the details.

## Licence

MIT. See [LICENSE](LICENSE).
