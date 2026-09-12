# wngmn

[![CI](https://img.shields.io/github/actions/workflow/status/skhan75/wngmn/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/skhan75/wngmn/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-orange?style=flat-square&logo=swift&logoColor=white)
![deps](https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

A teleprompter for the half of the conversation you can't script.

wngmn runs on your Mac beside Zoom or Meet, transcribes the caller's question on the machine, and puts it on a page. Tap Ask and Claude drafts a reply in your voice from a profile you wrote. The answer is on your phone before the silence gets awkward. wngmn is not trying to join your meeting. It is already sitting next to you.

Job interviews, podcasts, press calls, the board review that moved up a week: if you're the one being asked, it counts. It won't make you smarter. It makes sure the answer you already had shows up on time, not an hour later in the shower.

![Question lands, Ask pressed, answer streams](docs/images/ask.gif)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash
```

Builds from source, installs wngmn.app, links `wngmn` onto your PATH. A few minutes, no sudo.

Next, the speech model, 396 MB from Apple. Without it a run stops immediately, which beats transcribing silence.

```sh
wngmn install-model --locale en-US
```

Then let it check its hearing. It plays a tone and confirms the tap heard it. If macOS denied System Audio Recording, Core Audio reports success and delivers silence, and nothing else notices.

```sh
wngmn selftest
```

Last, a key. Only Ask needs it.

```sh
export ANTHROPIC_API_KEY=sk-ant-...   # in your shell profile
```

<details>
<summary>Manual install, uninstall, no download</summary>

```sh
git clone https://github.com/skhan75/wngmn.git && cd wngmn && Scripts/install.sh
```

```sh
curl -fsSL https://raw.githubusercontent.com/skhan75/wngmn/main/Scripts/bootstrap.sh | bash -s -- --uninstall
```

No prebuilt binary: the bundle is ad-hoc signed, so a downloaded copy is quarantined and quietly loses its microphone entitlement. Copying the bare binary to /usr/local/bin skips the app bundle and breaks permissions.

</details>

## Quick start

Phone in hand, Mac on the call: wngmn binds to your LAN and prints a URL with a token in it. Open it on the phone. `--listen` implies `--serve`.

```sh
wngmn --listen --profile me.md
```

Just the Mac? `--serve` puts the page at http://127.0.0.1:7373, loopback only. `--profile` alone starts no page.

```sh
wngmn --serve --profile me.md
```

Closed the terminal mid-call? `--resume` continues the most recent session from disk. It never happens on its own; you have to ask.

```sh
wngmn --resume
```

No call handy? From a clone, run a recording through the pipeline; no audio permission needed.

```sh
wngmn offline Tests/WngmnAudioTests/Fixtures/two-questions.wav --serve --profile profiles/example-interview.md
```

## Examples

The everyday one.

```sh
wngmn --serve --profile me.md
```

Both sides, labelled Caller and You. Assumes headphones.

```sh
wngmn --serve --mic --profile me.md
```

A specific input, threshold measured instead of guessed: `miccheck` listens to the room and prints the `--mic-open-db` value. `--mic-device` implies `--mic`.

```sh
wngmn miccheck
wngmn --serve --mic-device "BuiltInMicrophoneDevice" --mic-open-db -31 --profile me.md
```

An app that isn't Zoom or Chrome, or just one of them. Run `devices` during the call to find its bundle ID; conferencing apps rarely emit audio from the obvious process. `--bundle-id` repeats, and replaces the defaults.

```sh
wngmn devices                                          # while the call is running
wngmn --serve --bundle-id <id you saw> --profile me.md
```

Everything the Mac plays, music included.

```sh
wngmn --global --serve --profile me.md
```

Page on your phone.

```sh
wngmn --listen --profile me.md
```

A bookmark that survives restarts. Implies `--listen`; `--new-token` replaces it.

```sh
wngmn --token my-long-fixed-token --profile me.md
```

Slow talker, or noisy room? Wait longer before calling a question done, or raise the speech threshold above the hum. Defaults: 250 ms hangover, -45 dBFS open, 700 ms merge.

```sh
wngmn --serve --hangover-ms 400 --open-db -38 --merge-ms 900 --profile me.md
```

No transcript on disk.

```sh
wngmn --serve --no-log --profile me.md
```

Back into the last session.

```sh
wngmn --resume
```

More thinking, or another model. Defaults: claude-opus-5, low effort.

```sh
wngmn --serve --ask-model claude-opus-5 --ask-effort medium --profile me.md
```

Everything at once.

```sh
wngmn --global --serve --listen --mic --mic-device "BuiltInMicrophoneDevice" --mic-open-db -31 --ask-effort medium
```

## Your profile

A markdown file. Exactly three `##` headings are read:

- `## Style`: how answers are shaped. Sent verbatim.
- `## Context`: the material. Be generous; it's cached.
- `## Terms`: jargon the recogniser mishears, one per line: `Canonical | what it hears | another`.

A `# Title` at the top is just a display name. Any other `##` heading is reported at startup and ignored, so don't hide your best story under `## Notes`. `###` and tables inside a section are fine.

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

A bare `--profile name` means `./profiles/name.md`; a path works too. Re-read on change, so edit mid-call. The repo ships `profiles/TEMPLATE.md` and `profiles/example-interview.md`.

## Ask, and your own key

Only Ask needs a credential. Order: `ANTHROPIC_API_KEY`, then `ANTHROPIC_AUTH_TOKEN` (OAuth), then the profile `ant auth login` writes (the Claude CLI, so a subscription works). An empty exported variable counts as absent. With none, startup warns: `wngmn: no Anthropic credentials, so Ask will fail on every question.`

`--ask-effort`: low, medium, high, xhigh, or max. Default low, because you're on a call and slow is wrong.

A prefetch toggle on the page asks every caller question as it lands, one API call each. Off by default; mic lines never prefetch.

One Ask sends the question, up to six lines before it, and your profile to api.anthropic.com, then streams the answer back; the profile is cached after the first.

## How it works

```
Zoom / Chrome ─tap─▶ endpointer ─▶ SpeechAnalyzer ─▶ page ─Ask─▶ api.anthropic.com
  (its audio)       (RMS, 250 ms)   (on-device)      (phone)     (text, on click)
```

A Core Audio process tap scoped by bundle ID captures the meeting app's own output: not your mic, not other apps, unless `--global`. An RMS endpointer marks where speech starts and stops; a pause shorter than the merge window is a hesitation, stitched on and re-emitted with `revises`. At the endpoint wngmn forces the recogniser to finalise instead of waiting for `isFinal`: about 75 ms endpoint to event (measured 57 to 90) against about 900. The page is embedded in the binary and fetches nothing.

## Output

![Partials build word by word, then a question event with its latency](docs/images/cli.gif)

JSON Lines on stdout, diagnostics on stderr:

```json
{"type":"question","text":"So tell me about the funding round.","t0":0.51,"t1":2.38,"ms":57}
```

`ms` is measured endpoint-to-final. `revises: true` supersedes the previous line (a mid-sentence pause). `volatile: true`: wording from the volatile stream. Also `partial`, `status`, `warning`.

## Privacy

What leaves the machine:

- Audio: never. Memory, discarded, not recorded.
- Ask text: to api.anthropic.com, on click.
- The speech model: from Apple, via `install-model`.
- The transcript: `~/Library/Application Support/wngmn/sessions/`, only while `--serve` runs; `--no-log` disables it.
- The page: with `--listen`, on your LAN behind the URL token.

That is the whole list.

## Is this cheating?

Your notes are a prompter. So is the second monitor with the job description on it. wngmn is the same idea with better timing. It knows only what you put in the profile, and it doesn't do the talking. You read a draft and decide, out loud, what you actually think. Some rooms ban help of any kind, and a few interviewers ask outright. Find out before you sit down.

## What wngmn is not

wngmn is not a meeting recorder designed for secretly collecting conversations. It is not intended to bypass consent requirements, workplace policies, interview rules, or local recording laws. Audio and transcription laws vary depending on where you live and who is participating in the conversation. Make sure your use complies with the rules that apply to you. It is also not trying to replace your brain. It is trying to make sure your brain has backup.

## Intentionally boring

wngmn is intentionally boring in a few places. There is no framework where a few hundred lines of Swift will do. There is no cloud service where macOS already provides the capability locally. There is no database where a file will work.

Zero third-party dependencies: HTTP/SSE server, argument parser, and Claude client, all hand-rolled on Apple frameworks.

## Contributing

If you find a bug, open an issue. If you know why the audio pipeline behaves differently on a machine it has absolutely no reason to behave differently on, definitely open an issue. Pull requests are welcome. Keep changes focused, keep dependencies justified, and try not to turn the tiny HTTP server into Kubernetes.

`swift test` runs 407 tests; four suites need the speech model. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, then [architecture](docs/ARCHITECTURE.md), [permissions](docs/PERMISSIONS.md), [the page](docs/PAGE.md), [tuning](docs/TUNING.md), and [how the GIFs are made](docs/tapes/README.md). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to everyone taking part. Security reports go through GitHub private vulnerability reporting; see [SECURITY.md](SECURITY.md).

## The name

It's wingman with the vowels taken out. A good wingman stays out of the way, and so do the vowels.

## Licence

MIT. Take it, fork it, ship it. Just don't blame the wingman.
