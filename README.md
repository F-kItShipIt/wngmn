<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/logo-dark.png">
    <img src="docs/images/logo.png" alt="" height="44" align="absmiddle">
  </picture>
  wngmn
</h1>

<sub>pronounced <b>wing-man</b></sub>

[![CI](https://img.shields.io/github/actions/workflow/status/F-kItShipIt/wngmn/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/F-kItShipIt/wngmn/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-orange?style=flat-square&logo=swift&logoColor=white)
![deps](https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

A teleprompter for the half of the conversation you can't script.

**It heard the question. You take the credit.**

You're on a call. wngmn sits beside it on your Mac, writes down what the other person says, and puts an answer in front of you — drafted by Claude, out of notes you wrote — while they are still waiting for yours. Interviews, sales calls, investor calls, any meeting. It never joins the call, and nobody on it can see it.

![The caller finishes, the answer arrives, nobody touched the page](docs/images/auto.gif)

No account, no subscription, no driver. 2.9 MB. It runs when you run it and it's gone when you quit. The only bill is your own Anthropic key.

## 1. Install

A Mac on **macOS 26**, and about five minutes.

```sh
git clone https://github.com/F-kItShipIt/wngmn.git && cd wngmn
Scripts/install.sh
```

Then three things, once:

```sh
wngmn install-model --locale en-US    # Apple's speech model. 396 MB.
wngmn selftest                        # plays a beep. PASS = your Mac is letting wngmn listen
export ANTHROPIC_API_KEY=sk-ant-...   # your Claude key. Add this line to ~/.zshrc so it sticks
```

**`selftest` said FAIL?** macOS hasn't let your terminal listen yet. System Settings → Privacy & Security → **Screen & System Audio Recording** → switch on your terminal app → quit the terminal and open it again. [More](docs/PERMISSIONS.md).

<details>
<summary>One-line install, pin a version, uninstall</summary>

```sh
curl -fsSL https://raw.githubusercontent.com/F-kItShipIt/wngmn/main/Scripts/bootstrap.sh | bash     # 142 lines of shell. Read it first.
git checkout v0.3.1 && Scripts/install.sh                 # pin a version, inside a clone
Scripts/install.sh --uninstall
```

It builds from source. The app is signed for the Mac that built it and no other.

</details>

## 2. Start it

```sh
wngmn --listen --global
```

It prints a link. **Start it before the call, not during it.**

```
wngmn: live transcript → http://192.168.1.20:7373/?t=4fq8zj2m
wngmn:                    → http://your-mac.local:7373/?t=4fq8zj2m   (same page, stable name)
```

## 3. Open the link on your phone

Same Wi-Fi as the Mac. Bookmark the second one — it's the same every time. Prop the phone just under your webcam, so your eyes stay where they should.

No phone? Open the link on the Mac.

## 4. Join the call

That's all. When they ask something, it appears on your phone. A moment later, so does an answer.

### Try it now, without a call

Start it, open the link, and play any video of someone talking — YouTube is fine. Their words land as lines; answers follow. If nothing lands, jump to [Not working?](#not-working).

## What you can do

### Get answers by themselves

This is on from the start. Every time someone finishes talking, wngmn asks Claude and shows the answer. You press nothing.

- The header counts what it spent: `auto: 3 answered · 4 calls`. Each call costs a little on your key.
- Untick **auto** on the page to stop. Start with `--no-auto` to have it off from the beginning.
- Small talk gets no answer. That's deliberate.

### Ask about one line

With auto off, tap **Ask** next to any line. Tap the line again later to bring its answer back — that doesn't cost another call.

### Screenshot a problem

They pasted the question into a doc instead of saying it. Take a picture of it:

```sh
wngmn shot --region    # drag a box around it. Esc cancels
wngmn shot             # or the whole screen
```

The answer shows up like any other, and wngmn remembers the picture — so when they then *say* "can you do that faster?", it knows what "that" is.

**Put them on keys**, because you won't be typing mid-call. Shortcuts app → new shortcut → **Run Shell Script** → the full path to wngmn, then `shot --region` → ⓘ → **Add Keyboard Shortcut**. Get the path from your terminal with `command -v wngmn`. Press each key once before the call: the first time, macOS asks to let your terminal record the screen.

### Get your own words too

Out of the box wngmn hears **them, not you** — it exists to catch their question. To see both sides, labelled Caller and You:

```sh
wngmn --listen --global --mic
```

It uses whatever mic and speakers your Mac is using — the built-in ones are fine, and nothing needs plugging in first. One catch on speakers: your mic hears the other person too, so their lines can show up twice. Headphones fix that. Wired beats AirPods: a Bluetooth headset using its own mic drops the call to phone quality.

### Mute yourself, or stop listening

Two buttons at the top of the page, and they work from the phone:

- **mic on** → tap to mute your mic (key: `m`).
- **listening** → tap to stop hearing them (key: `p`). Nothing is written down or sent while it's paused.

Start paused with `--start-paused`.

### Get notes at the end

Tap **▸ notes**, or say yes when it asks whether the call is over. You get meeting notes from the whole conversation, with a **copy** button.

### Make the answers sound like you

Without this, answers come from general knowledge. With it, they come from *your* story. Make a file, `me.md`:

```markdown
# Me

## Style
Short sentences, real examples. Say "I don't know" when I don't.

## Context
Paste everything: your CV, the job post, your projects, the numbers you want to get right.
The more you put here, the better the answers. It's only sent when an answer is needed.

## Terms
Kubernetes | cooper netties | goober netties
```

```sh
wngmn --listen --global --profile me.md
```

**Style** is how you talk. **Context** is what you know. **Terms** fixes words it mishears: the right word first, then what it hears. Edit the file mid-call and it's picked up when you save. Start from [profiles/TEMPLATE.md](profiles/TEMPLATE.md); ready-made ones for [hiring](profiles/hiring.md), [investor](profiles/investor.md) and [technical](profiles/technical.md) calls are in [`profiles/`](profiles).

## Not working?

Nothing here prints an error. It just goes quiet — so check the night before.

| What you see | Why | Fix |
| --- | --- | --- |
| No lines when **they** talk | Without `--global`, wngmn only hears Zoom and Chrome | Add `--global` |
| Still no lines, with `--global` | macOS isn't letting your terminal listen — or the call isn't playing on this Mac | `wngmn selftest`. FAIL → fix the permission in step 1. PASS → make sure the call's sound is coming out of this Mac, not your phone |
| No lines when **you** talk | Your mic is off unless you ask | Add `--mic`. If macOS asks about the microphone, say yes — it's asking for your terminal |
| Every line shows up twice | `--mic` on speakers: your mic is hearing them | Headphones, or drop `--mic` |
| Lines, but no answers | No API key, or **auto** is unticked | `echo $ANTHROPIC_API_KEY` — empty means it isn't set. Tick **auto** |
| `auto: 0 answered · 5 calls` | It heard talking, but no question | Nothing is wrong |
| Screenshot says *Screen Recording is not granted* | macOS hasn't let your terminal see the screen | Same Settings pane as `selftest`, top list → restart the terminal |
| Phone can't open the link | Different Wi-Fi, or you used `--serve` | Same Wi-Fi, and start with `--listen` |
| It died and the call didn't | — | `wngmn --resume` |

## Cheat sheet

```sh
wngmn --listen --global                       # start. Hears them, in any app. Link for your phone
wngmn --listen --global --mic                 # + your side of the call
wngmn --listen --global --profile me.md       # answers from your notes
wngmn --listen --global --no-auto             # answer only when you tap Ask
wngmn --serve --global                        # this Mac only → http://127.0.0.1:7373
wngmn shot --region                           # screenshot a problem (bind it to a key)
wngmn --resume                                # pick up the transcript after a crash
wngmn stop                                    # stop every wngmn that's running
wngmn --help                                  # everything
```

Every flag, with examples: [docs/USAGE.md](docs/USAGE.md).

## Privacy

There is no server and no account, so there is nothing to collect. No analytics, no crash reports. What leaves your Mac, all of it, and only to Anthropic on your own key:

- **Audio: never.** Speech is turned into text on your Mac.
- **auto** (on unless you pass `--no-auto`): each turn of the conversation, as it ends, plus your profile. wngmn says so when it starts.
- **Ask:** that line, the few before it, and your profile — when you tap.
- **shot:** a picture of your screen, when you press your key. It stays in the conversation until wngmn quits. Whatever else is on the screen goes with it; drag a region if that matters. The file is deleted as soon as it's read.
- **The transcript** is saved on your own disk. `--no-log` turns that off.
- **`--listen`** puts the page on your Wi-Fi, locked by the token in the link. Screenshots can only ever be triggered from the Mac itself.

The fine print, including what other software on your Mac could do with it, is in [SECURITY.md](SECURITY.md).

## Is this cheating?

It's a prompter. Newsreaders use one. It knows only what you typed into a file, and it does none of the talking. Some rooms ban help, though, and some interviewers just ask. Know which room you're walking into.

## What wngmn is not

wngmn is not a meeting recorder designed for secretly collecting conversations. It is not intended to bypass consent requirements, workplace policies, interview rules, or local recording laws. Audio and transcription laws vary depending on where you live and who is participating in the conversation. Make sure your use complies with the rules that apply to you. It is also not trying to replace your brain. It is trying to make sure your brain has backup.

## Go deeper

[Every flag](docs/USAGE.md) · [the page you read during a call](docs/PAGE.md) · [permissions and headphones](docs/PERMISSIONS.md) · [tuning the speech detector](docs/TUNING.md) · [how it's built](docs/ARCHITECTURE.md) · [security](SECURITY.md)

## Contributing

Found a bug? Open an issue. Know why the audio behaves differently on a machine it has no reason to behave differently on? Definitely open an issue. Pull requests are welcome: start with [CONTRIBUTING.md](CONTRIBUTING.md). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) is in force, and security holes go through GitHub's private reporting — see [SECURITY.md](SECURITY.md).

## The name

It's wingman with the vowels taken out. A good wingman stays out of the way, and so do the vowels.

## Licence

MIT. Take it, fork it, ship it. Just don't blame the wingman.
