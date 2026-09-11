<div align="center">

# wngmn

### Knows when the question ended. Not what was said — *when it ended.*

Live captions tell you what someone said. Great. Useless.<br>
If something has to **react** to a question, the only thing that matters is knowing it's over.

[![CI](https://img.shields.io/github/actions/workflow/status/skhan75/wngmn/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/skhan75/wngmn/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-orange?style=flat-square&logo=swift&logoColor=white)
![deps](https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

**~75 ms** from endpoint to structured event. The Speech framework's own `isFinal` takes **~900**.<br>
Audio never leaves your machine. Not "anonymised". Not "aggregated". It just never leaves.

<img src="docs/images/ask.gif" alt="A question lands, Ask is pressed, the answer streams in" width="880">

<sub>Real run, real speed, real API call. Those millisecond numbers are measured, not marketing.</sub>

</div>

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash
```

Builds on your machine. Takes a few minutes. Doesn't ask for `sudo`.

```sh
wngmn install-model --locale en-US   # 396 MB from Apple. Yes, really.
wngmn selftest                       # plays a tone, proves the tap heard it
```

Do both. The model isn't optional — without it a run dies immediately instead of politely
transcribing an hour of digital silence. And if `selftest` fails, macOS denied System Audio
Recording, which it does *silently*: every Core Audio call returns success and hands back
nothing. That's the entire reason this command exists.

<details>
<summary><b>"Just give me a binary"</b></summary>

<br>

No. The bundle is ad-hoc signed, so it's trusted by exactly one machine — the one that built
it. A downloaded release would be quarantined by Gatekeeper and quietly stripped of its
microphone entitlement, which here means a call transcribed from pure silence with no error
anywhere. Genuinely delightful to debug.

Real binaries need a Developer ID certificate and notarisation. That costs money nobody has
spent yet. Compiling locally is the only version where the permissions actually work.

</details>

<details>
<summary><b>Manual install, version pinning, uninstall</b></summary>

<br>

```sh
git clone https://github.com/skhan75/wngmn.git && cd wngmn
Scripts/install.sh          # build, bundle, sign, link

# or don't install at all
swift build -c release && ./.build/release/wngmn selftest
```

```sh
BOOT=https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh
curl -fsSL $BOOT | WNGMN_REF=main BINDIR=~/bin bash
curl -fsSL $BOOT | bash -s -- --uninstall
```

If you keep both, bare `wngmn` resolves through `$PATH` to whatever you installed last — a
different binary with a different permission grant than `./.build/release/wngmn`. Run local
builds by path.

</details>

## Try it without bothering anyone

```sh
git clone https://github.com/skhan75/wngmn.git && cd wngmn

wngmn offline Tests/WngmnAudioTests/Fixtures/two-questions.wav \
  --serve --profile profiles/example-interview.md
```

Open http://127.0.0.1:7373. Two questions land. Hit **Ask**. That's the whole product.

## Actually using it

```sh
wngmn --serve                                    # Zoom and Chrome, page on loopback
wngmn --serve --mic                              # both sides, labelled Caller and You
wngmn --serve --listen                           # read it on your phone instead
wngmn --serve --global                           # tap literally everything
wngmn --serve --resume                           # it crashed. carry on.
wngmn --serve --no-log                           # nothing touches disk
```

**Not on Zoom or Chrome?** Run `wngmn devices` *during* a call to find the bundle ID, then
`--bundle-id <that>`. Conferencing apps almost never emit audio from the process you'd guess,
which is why the default list has five entries and still misses things. `--global` skips the
detective work at the cost of transcribing your music.

**Mic sounds wrong?** `wngmn miccheck` measures your actual room and prints the number:

```sh
wngmn --serve --mic --mic-device "BuiltInMicrophoneDevice" --mic-open-db -31
```

**Everything at once**, which is a real setup and not a flex:

```sh
wngmn --global --serve --listen --mic \
  --mic-device "BuiltInMicrophoneDevice" \
  --mic-open-db -31 --ask-effort medium
```

Assumes headphones. On speakers your mic hears the caller too and every sentence shows up
twice, once under each name. Physics, not a bug.

## Answers, and your own damn key

Capture, transcription, endpointing: all local, no account, no network. **Ask is the only
thing here that talks to the internet**, and only when you press the button.

Three credential sources, first one wins:

| | |
|---|---|
| `ANTHROPIC_API_KEY` | normal API key |
| `ANTHROPIC_AUTH_TOKEN` | OAuth access token |
| `ant auth login` | the Claude CLI's profile — how a subscription gets used instead of pay-as-you-go |

```sh
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.zshrc && exec zsh
```

An exported-but-empty variable counts as *absent*, not as a broken key, because a half-written
shell profile is always the real cause and `401 unauthorized` is a garbage hint. You'll also be
told at startup rather than mid-interview:

```
wngmn: no Anthropic credentials, so Ask will fail on every question.
```

`--ask-effort` goes `low` to `max` and defaults to **low** on purpose. A brilliant answer that
lands after you've already stammered through the question is worth nothing.

One Ask, one API call. The **prefetch** toggle answers *every* caller question the moment it
lands — instant, and you pay for all the questions you were never going to ask. Off by default.
Your own mic is never prefetched, so `--mic` doesn't double the bill.

## Profiles

One markdown file. Without it, Ask is answering from the question alone, which is exactly as
good as it sounds.

| Section | |
|---|---|
| `## Style` | how answers should read. Sent verbatim — it does nothing you didn't ask for. |
| `## Context` | the actual material. Be greedy; it's cached after the first ask. |
| `## Terms` | words the recogniser mangles: `Canonical \| what it hears \| also this` |

Only `##` starts a section, so `###` and tables inside one are fine. Typo a heading and it
tells you instead of silently dropping it.

```sh
wngmn --serve --profile interview          # → ./profiles/interview.md
wngmn --serve --profile ~/notes/board.md
```

Steal [example-interview.md](profiles/example-interview.md) or start from
[TEMPLATE.md](profiles/TEMPLATE.md). Re-read on change, so you can edit it mid-call.
`--profile` beats `--notes`; passing both silently ignores the notes.

## Output

JSON Lines on stdout, diagnostics on stderr, so pipes stay clean.

<img src="docs/images/cli.gif" alt="Partials building word by word, then an endpointed question" width="880">

- `ms` — measured endpoint-to-final for that question
- `revises` — supersedes the previous line. They paused mid-sentence; you get the whole thing.
- `volatile` — came from the volatile stream, trust it less

## Flags

| | |
|---|---|
| `--serve` `--port` `--listen` `--token` | the page; `--listen` puts it on your LAN behind a token |
| `--mic` `--mic-device` `--mic-open-db` | your half of the conversation |
| `--bundle-id` `--global` | what gets tapped |
| `--profile` `--ask-model` `--ask-effort` | answers |
| `--hangover-ms` `--open-db` | endpointing. Defaults 250 ms and -45 dBFS. |
| `--no-log` `--resume` `--log-dir` | the transcript on disk |

`--port`, `--listen`, `--token`, `--new-token`, `--start-paused`, `--resume` and `--log-dir`
all imply `--serve`. `--mic-device` implies `--mic`. `wngmn --help` has the rest, plus
`selftest`, `devices`, `miccheck`, `offline`, `install-model` and `stop`.

## What leaves your machine

- **Audio: never.** Processed in memory, discarded. Nothing is recorded.
- **Ask:** the question, six previous ones, and your profile go to `api.anthropic.com`. Only on click.
- **`install-model`:** downloads from Apple. That one command, when you run it.
- **Transcript:** written to disk only while `--serve` is running, so `--resume` can work.
- **`--listen`:** your page, on your LAN, behind the token in the printed URL.

That's the complete list.

## Scope

Built for when you supply the material in advance and want it back at the right second:
interviews, panels, podcasts, rehearsing against a recording.

The code has no idea what conversation it's in. It hears what your Mac is playing, and a call
is a call. Nothing distinguishes an interview from an exam or a technical screen, and nothing
could. Whether using it is fine is your call, under whatever rules you're actually bound by.

For the avoidance of doubt: **it isn't for assessments.** That's the author's position, not a
technical limitation, and you'll notice nothing stops you.

## Docs

| | |
|---|---|
| [PERMISSIONS](docs/PERMISSIONS.md) | why denial is silent, and how to fix it |
| [PAGE](docs/PAGE.md) | every control on the page |
| [TUNING](docs/TUNING.md) | endpointer knobs worth touching, and what to measure |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | the tap, the ring buffer, forced finalisation |
| [tapes](docs/tapes/README.md) | regenerating the GIFs above |

## Contributing

```sh
swift test   # 407 tests. No audio permission needed. Four suites want the speech model.
```

`WngmnCore` deliberately can't see Core Audio or Speech, which is why most of the suite runs
anywhere. The tier that can't be automated is a real call with a real human.

[CONTRIBUTING.md](CONTRIBUTING.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Security

`--listen` puts someone else's words on your local network behind one token. If you get past
it, use GitHub's private vulnerability reporting, not a public issue. [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE). Do what you want.
