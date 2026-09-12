# wngmn

[![CI](https://img.shields.io/github/actions/workflow/status/skhan75/wngmn/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/skhan75/wngmn/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-orange?style=flat-square&logo=swift&logoColor=white)
![deps](https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

A teleprompter for the half of the conversation you can't script.

wngmn runs on your Mac alongside Zoom or Meet, transcribes the caller's question on the machine, and puts it on your phone. Tap Ask and Claude drafts a reply from your profile. wngmn is not trying to join your meeting. It is already sitting next to you.

![Question lands, Ask pressed, answer streams](docs/images/ask.gif)

## Install

```sh
git clone https://github.com/skhan75/wngmn.git && cd wngmn
Scripts/install.sh
```

Builds from source, installs wngmn.app, puts `wngmn` on your PATH. No sudo.

Shortcut, same result. `Scripts/bootstrap.sh` is 142 lines; read it before you pipe it.

```sh
curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash
```

Then:

```sh
wngmn install-model --locale en-US    # 396 MB speech model from Apple. Required.
wngmn selftest                        # plays a tone, confirms the audio tap works
export ANTHROPIC_API_KEY=sk-ant-...   # only Ask needs it. Put it in your shell profile.
```

If `selftest` fails, grant System Audio Recording: [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

<details>
<summary>Pin a version, uninstall</summary>

```sh
git checkout v0.1.0 && Scripts/install.sh                 # from a clone
curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | WNGMN_REF=v0.1.0 bash
Scripts/install.sh --uninstall
```

No prebuilt binary; build from source.

</details>

## Quick start

**1. Write a profile.** Format is below. Save it as `me.md`.

**2. Start wngmn before the call.**

```sh
wngmn --listen --profile me.md
```

**3. Open the printed URL on your phone.** Bookmark it.

```
wngmn: live transcript → http://192.168.1.20:7373/?t=4fq8zj2m
wngmn:                    → http://your-mac.local:7373/?t=4fq8zj2m   (same page, stable name)
```

**4. Prop the phone under your webcam and join the call.**

Page on the Mac instead: `wngmn --serve --profile me.md`, then http://127.0.0.1:7373.

Process died mid-call:

```sh
wngmn --resume
```

No call handy? From a clone of the repo:

```sh
wngmn offline Tests/WngmnAudioTests/Fixtures/two-questions.wav --serve --profile profiles/example-interview.md
```

## On your phone, during the interview

<img src="docs/images/phone.png" alt="Left: the Transcript tab. Right: the Answer tab after asking" width="720">

- **Transcript tab.** Every question, its latency, an Ask on each. The badge counts questions you haven't looked at.
- **Answer tab.** The reply streams here. Asking switches you to it.
- **Live caption**, bottom of the screen. The question forming as they speak. Its Ask targets the newest question, and reads **View** once that question has an answer.
- **prefetch.** Answers every caller question as it lands, one API call each. Off by default.
- **sync.** Keeps the laptop and the phone on the same row.

## Examples

Both sides, labelled Caller and You. Wear headphones.

```sh
wngmn --serve --mic --profile me.md
```

Pick the input and measure the threshold. `--mic-device` implies `--mic`.

```sh
wngmn miccheck
wngmn --serve --mic-device "BuiltInMicrophoneDevice" --mic-open-db -31 --profile me.md
```

An app that isn't Zoom or Chrome. Run `devices` during the call to find its bundle ID.

```sh
wngmn devices                                          # while the call is running
wngmn --serve --bundle-id <id you saw> --profile me.md
```

Everything the Mac plays, music included.

```sh
wngmn --global --serve --profile me.md
```

A URL that survives restarts. Implies `--listen`; `--new-token` replaces it.

```sh
wngmn --token my-long-fixed-token --profile me.md
```

Slow talker or noisy room. Defaults: 250 ms hangover, -45 dBFS open, 700 ms merge.

```sh
wngmn --serve --hangover-ms 400 --open-db -38 --merge-ms 900 --profile me.md
```

Nothing written to disk.

```sh
wngmn --serve --no-log --profile me.md
```

More thinking, or another model. Defaults: `claude-opus-5`, `low`.

```sh
wngmn --serve --ask-model claude-opus-5 --ask-effort medium --profile me.md
```

Everything at once.

```sh
wngmn --global --serve --listen --mic --mic-device "BuiltInMicrophoneDevice" --mic-open-db -31 --ask-effort medium
```

## Your profile

Three `##` headings are read. Any other `##` is reported at startup and ignored.

- `## Style`: how answers should sound.
- `## Context`: what answers are built from. Be generous.
- `## Terms`: words the recogniser mishears, one per line: `Canonical | what it hears | another`.

```markdown
# Me, for interviews

## Style
Short sentences, concrete examples. Say "I don't know" when I don't.
Never use the word synergy.

## Context
I run infrastructure for a 12-person payments startup. Before that,
four years at a large company building experimentation tooling.

When asked about a failure, tell the one about the migration that
rolled back twice and what I changed afterward.

Don't mention that I've never actually read the Kubernetes docs.

## Terms
Kubernetes | cooper netties | goober netties
```

`--profile name` resolves to `./profiles/name.md`; a path works too. Edit it mid-call; it's re-read on change. Start from [profiles/TEMPLATE.md](profiles/TEMPLATE.md) or [profiles/example-interview.md](profiles/example-interview.md).

## Ask, and your own key

Checked in order: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, then `ant auth login`. With none set, startup prints `wngmn: no Anthropic credentials, so Ask will fail on every question.`

- `--ask-effort low|medium|high|xhigh|max`. Default `low`.
- `--ask-model`, default `claude-opus-5`.
- One Ask sends the question, up to six before it, and your profile to api.anthropic.com.

## How it works

```
Zoom / Chrome ─tap─▶ endpointer ─▶ SpeechAnalyzer ─▶ page ─Ask─▶ api.anthropic.com
  (its audio)       (RMS, 250 ms)   (on-device)      (phone)     (text, on click)
```

Detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Output

![Partials build word by word, then a question event with its latency](docs/images/cli.gif)

JSON Lines on stdout, diagnostics on stderr.

```json
{"type":"question","text":"So tell me about the funding round.","t0":0.51,"t1":2.38,"ms":57}
```

`ms` is the latency. `revises: true` replaces the previous line. `volatile: true` means less certain wording.

## Privacy

What leaves the machine:

- Audio: never.
- Ask: the question, recent questions, your profile. To api.anthropic.com, on click.
- `install-model`: from Apple.
- Transcript: local disk, only while `--serve` runs. `--no-log` disables it.
- `--listen`: the page on your LAN, behind the URL token.

## Is this cheating?

It's a prompter. It knows only what you put in the profile and it doesn't do the talking. Some rooms ban help and some interviewers ask. Find out before you sit down.

## What wngmn is not

wngmn is not a meeting recorder designed for secretly collecting conversations. It is not intended to bypass consent requirements, workplace policies, interview rules, or local recording laws. Audio and transcription laws vary depending on where you live and who is participating in the conversation. Make sure your use complies with the rules that apply to you. It is also not trying to replace your brain. It is trying to make sure your brain has backup.

## Intentionally boring

wngmn is intentionally boring in a few places. There is no framework where a few hundred lines of Swift will do. There is no cloud service where macOS already provides the capability locally. There is no database where a file will work.

## Contributing

If you find a bug, open an issue. If you know why the audio pipeline behaves differently on a machine it has absolutely no reason to behave differently on, definitely open an issue. Pull requests are welcome. Keep changes focused, keep dependencies justified, and try not to turn the tiny HTTP server into Kubernetes.

`swift test` runs 407 tests; four suites need the speech model. Read [CONTRIBUTING.md](CONTRIBUTING.md), then [permissions](docs/PERMISSIONS.md), [the page](docs/PAGE.md), [tuning](docs/TUNING.md), [architecture](docs/ARCHITECTURE.md), [the GIFs](docs/tapes/README.md). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies. Security reports: GitHub private vulnerability reporting, see [SECURITY.md](SECURITY.md).

## The name

It's wingman with the vowels taken out. A good wingman stays out of the way, and so do the vowels.

## Licence

MIT. Take it, fork it, ship it. Just don't blame the wingman.
