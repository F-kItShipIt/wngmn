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

No account, no subscription, no extra audio software. Under 4 MB. It runs when you run it and it's gone when you quit. The only bill is your own Claude key.

## 1. Install

You need a Mac on **macOS 26** ( → About This Mac says which) and about fifteen minutes, most of it waiting.

Everything in a grey box is typed into **Terminal**. Open it: ⌘-Space, type `Terminal`, press Return. Paste one box at a time, press Return, and wait for the line ending in `%` to come back.

**Apple's developer tools.** A window pops up → **Install**. If it says *already installed*, good.

```sh
xcode-select --install
```

**wngmn itself.** It builds for a few minutes and ends with `==> Installed.`

```sh
git clone https://github.com/F-kItShipIt/wngmn.git ~/wngmn && cd ~/wngmn && Scripts/install.sh
```

**Apple's speech model.** 396 MB, once.

```sh
wngmn install-model --locale en-US
```

**Check your Mac lets it listen.** It plays a beep and says `PASS` or `FAIL`. If macOS asks to let Terminal record audio, say **Allow**.

```sh
wngmn selftest
```

**Your Claude key.** A key is a password that lets wngmn ask Claude, and pays for it. A Claude.ai subscription isn't one. Get it at [platform.claude.com/settings/keys](https://platform.claude.com/settings/keys): sign up → **Billing**, add a little credit → **API keys** → **Create key** → copy it. It starts `sk-ant-` and is shown once. Then save it — swap in your own key, keep the quote marks:

```sh
echo 'export ANTHROPIC_API_KEY=sk-ant-YOUR-KEY-HERE' >> ~/.zshrc
```

Quit Terminal (⌘Q) and open it again. Done.

**`command not found: wngmn`?** Scroll up: the installer printed a line starting `echo 'export PATH=`. Paste that line, press Return, quit Terminal and open it again.

**`selftest` said FAIL?** The line after FAIL names the cause. *Digital silence* means macOS hasn't let Terminal listen yet:  → System Settings → Privacy & Security → **Screen & System Audio Recording** → switch on **Terminal** in the top list (not there? press **+** and pick it from Applications → Utilities) → quit Terminal with ⌘Q, open it, run `wngmn selftest` again. *Far too quiet* means turn the volume up. [More](docs/PERMISSIONS.md).

<details>
<summary>One-line install, pin a version, uninstall</summary>

The one-liner — 142 lines of shell, so read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/F-kItShipIt/wngmn/main/Scripts/bootstrap.sh | bash
```

The same, pinned to a version (`git tag` lists them; `shot` and auto-by-default came after v0.3.1):

```sh
curl -fsSL https://raw.githubusercontent.com/F-kItShipIt/wngmn/main/Scripts/bootstrap.sh | WNGMN_REF=v0.3.1 bash
```

Uninstall, from inside `~/wngmn`:

```sh
Scripts/install.sh --uninstall
```

It builds from source. The app is signed for the Mac that built it and no other.

</details>

## 2. Start it

```sh
wngmn --listen --global
```

It prints two links and keeps running. **Leave that window open for the whole call** — close it and wngmn stops. To stop it yourself, click the window and press Ctrl-C. **Start it before the call, not during it.**

```
wngmn: live transcript → http://192.168.1.20:7373/?t=4fq8zj2m
wngmn:                    → http://your-mac.local:7373/?t=4fq8zj2m   (same page, stable name)
```

If it also says `no credentials`, your key isn't saved — back to step 1.

## 3. Open the link on your phone

Use the links in *your* Terminal, not the example above. Phone on the same Wi-Fi as the Mac. Copy the second link and AirDrop or message it to your phone — or type it into the phone's browser exactly, `?t=` and all. Bookmark it: it's the same every time.

You should see this. Prop the phone just under your webcam, so your eyes stay where they should.

<img src="docs/images/phone.png" alt="The page on a phone: the transcript, and an answer" width="560">

No phone? Right-click the link in Terminal → **Open URL**.

## 4. Join the call

That's all. When they ask something, it appears on your phone. A moment later, so does an answer.

### Try it now, without a call

Start it, open the link, and play any video of someone talking **on the Mac, not the phone** — YouTube is fine. Their words land as lines; answers follow. If nothing lands, jump to [Not working?](#not-working)

## What you can do

### Get answers by themselves

This is on from the start. Every time someone finishes talking, wngmn asks Claude and shows the answer. You press nothing.

- Untick **auto** on the page to stop. Start with `--no-auto` to have it off from the beginning.
- Small talk gets no answer. That's deliberate.
- Each question sent to Claude costs a little on your key. On the Mac's copy of the page, the side panel keeps count: `auto: 3 answered · 4 calls` — a *call* there is one question sent to Claude, not a phone call.

### Ask about one line

With auto off, tap **Ask** next to any line. Tap the line again later to bring its answer back — that one's free.

![Question lands, Ask pressed, answer streams](docs/images/ask.gif)

### Screenshot a problem

They pasted the question into a doc instead of saying it. Take a picture of it. Drag a box around it — Esc cancels:

```sh
wngmn shot --region
```

Or the whole main screen:

```sh
wngmn shot
```

The answer shows up like any other. With auto on, wngmn remembers the picture — so when they then *say* "can you do that faster?", it knows what "that" is.

**Put it on a key**, because you won't be typing mid-call:

1. In Terminal, run `command -v wngmn`. It prints where wngmn lives. Copy that.
2. Open the **Shortcuts** app → **+** → search **Run Shell Script** → double-click it.
3. In its box: paste what you copied, a space, then `shot --region`.
4. Click ⓘ → **Add Keyboard Shortcut** → press the keys you want.
5. Want the whole screen on a key too? Do it again with plain `shot`.

Press your key once before the call. The first time, macOS asks to let Terminal record the screen: allow it, quit Terminal (⌘Q), and start wngmn again.

### Get your own words too

Out of the box wngmn hears **them, not you** — it exists to catch their question. To see both sides, labelled Caller and You:

```sh
wngmn --listen --global --mic
```

It uses whatever mic and speakers your Mac is using — the built-in ones are fine, and nothing needs plugging in first. On speakers your mic hears the other person too, so wngmn notices and ignores your mic while they're talking: their words show up once, as theirs. The price: anything you say *over* them is lost. On headphones nothing is. Wired beats AirPods: a Bluetooth headset using its own mic drops the call to phone quality.

### Stop it hearing them, or you

Buttons at the top of the page, and they work from the phone:

- **⏸ listening** → tap to stop hearing them (key: `p`). Nothing they say is written down or sent while it's paused. Start that way with `--start-paused`.
- **mic on** (only there with `--mic`) → tap to stop wngmn hearing your mic (key: `m`). This does **not** mute you on the call — use the call app's own mute for that.

### Get notes at the end

Tap **▸ notes**, or say yes when it asks whether the call is over. You get meeting notes from everything auto heard, plus any screenshots, with a **copy** button. If auto was off for the whole call, there is nothing to write them from.

### Make the answers sound like you

Without this, answers come from general knowledge. With it, they come from *your* story. Make your file from the template and open it:

```sh
cp ~/wngmn/profiles/TEMPLATE.md ~/me.md && open -e ~/me.md
```

Fill it in like this, then ⌘S:

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
wngmn --listen --global --profile ~/me.md
```

**Style** is how you talk. **Context** is what you know. **Terms** fixes words it mishears: the right word first, then what it hears. Only those three `##` headings are read — any other `##` (one inside a pasted CV, say) is named when wngmn starts and everything under it is ignored, so make those `###`. wngmn says `profile …` with the sizes when it starts; `could not be read` means the path is wrong.

Ready-made ones for [hiring](profiles/hiring.md), [investor](profiles/investor.md) and [technical](profiles/technical.md) calls are in [`profiles/`](profiles). A bare name is a shortcut: `--profile hiring` reads `./profiles/hiring.md` in the folder you start wngmn from. Edit the file mid-call: **Terms**, and any answer you **Ask** for, pick it up when you save. Auto keeps the Style and Context it started with.

## Not working?

Nothing here prints an error. It just goes quiet — so check the night before.

| What you see | Why | Fix |
| --- | --- | --- |
| No lines when **they** talk | Without `--global`, wngmn only hears Zoom and Chrome | Add `--global` |
| Still no lines, with `--global` | macOS isn't letting Terminal listen — or the call isn't playing on this Mac | `wngmn selftest`. FAIL → fix the permission in step 1. PASS → make sure the call's sound is coming out of this Mac, not your phone |
| No lines when **you** talk | Your mic is off unless you ask | Add `--mic`. If macOS asks about the microphone, say yes — it's asking for Terminal |
| Their lines show up twice, as Caller and as You | Your mic hears them through the speakers, and wngmn hasn't caught it — a very echoey room, or `--no-echo-gate` | Headphones, or drop `--mic` |
| My words go missing when we talk at once | On speakers, wngmn ignores your mic while they're talking | Headphones |
| Lines, but no answers | No key, or **auto** is unticked | `echo $ANTHROPIC_API_KEY` — empty means it isn't saved. Tick **auto** |
| Lines, a few answers, mostly nothing | It only answers questions. Small talk gets none | Nothing is wrong |
| Screenshot says *Screen Recording is not granted* | macOS hasn't let Terminal see the screen | Same Settings pane as `selftest`, top list → quit Terminal, start again |
| Phone can't open the link | Different Wi-Fi, or you started with `--serve`, which is this-Mac-only | Same Wi-Fi, and start with `--listen` |
| It died and the call didn't | — | Start it exactly as before, plus `--resume`. The transcript comes back |

## Cheat sheet

| Type this | What it does |
| --- | --- |
| `wngmn --listen --global` | Start. Hears them, in any app. Prints the link for your phone |
| `wngmn --listen --global --mic` | The same, plus your side of the call |
| `wngmn --listen --global --profile ~/me.md` | Answers from your notes |
| `wngmn --listen --global --no-auto` | Answers only when you tap **Ask** |
| `wngmn --serve --global` | This Mac only → http://127.0.0.1:7373 |
| `wngmn shot --region` | Screenshot a problem (put it on a key) |
| `wngmn --listen --global --resume` | Pick the transcript back up after a crash |
| `wngmn stop` | Stop every wngmn that's running |
| `wngmn --help` | Every flag |

Flags combine: `wngmn --listen --global --mic --profile ~/me.md`. The ones worth knowing, with examples: [docs/USAGE.md](docs/USAGE.md).

## Privacy

There is no server and no account, so there is nothing to collect. No analytics, no crash reports. What leaves your Mac, all of it, and only to Anthropic on your own key:

- **Audio: never.** Speech is turned into text on your Mac.
- **auto** (on unless you pass `--no-auto`): each turn as it ends — theirs, and yours if `--mic` is on — with the conversation so far and your profile. wngmn says so when it starts.
- **Ask:** that line, the few before it, and your profile — when you tap. Tick **prefetch** on the page and it goes for every line of theirs as it lands.
- **shot:** a picture of your screen, when you press your key. It stays in the conversation and goes again with every later answer until wngmn quits. Whatever else is on the screen goes with it; drag a region if that matters. The file is deleted as soon as it's read.
- **notes:** the conversation auto already sent, once more, when you tap **▸ notes**.
- **The transcript** is saved on your own disk, answers included. `--no-log` turns that off.
- **`--listen`** puts the page on your Wi-Fi, locked by the secret code at the end of the link — the `?t=…` part. Anyone with the full link can read along, so don't share it. Screenshots can only ever be triggered from the Mac itself.
- **`install-model`** is a download from Apple. Nothing of yours goes with it.

The fine print, including what other software on your Mac could do with it, is in [SECURITY.md](SECURITY.md).

## Is this cheating?

It's a prompter. Newsreaders use one. It knows only what you typed into a file, and it does none of the talking. Some rooms ban help, though, and some interviewers just ask. Know which room you're walking into.

## What wngmn is not

wngmn is not a meeting recorder designed for secretly collecting conversations. It is not intended to bypass consent requirements, workplace policies, interview rules, or local recording laws. Audio and transcription laws vary depending on where you live and who is participating in the conversation. Make sure your use complies with the rules that apply to you. It is also not trying to replace your brain. It is trying to make sure your brain has backup.

## Go deeper

[More flags, with examples](docs/USAGE.md) · [the page you read during a call](docs/PAGE.md) · [permissions and audio routes](docs/PERMISSIONS.md) · [tuning the speech detector](docs/TUNING.md) · [how it's built](docs/ARCHITECTURE.md) · [security](SECURITY.md) · [regenerating the GIFs](docs/tapes/README.md)

## Contributing

Found a bug? Open an issue. Know why the audio behaves differently on a machine it has no reason to behave differently on? Definitely open an issue. Pull requests are welcome: start with [CONTRIBUTING.md](CONTRIBUTING.md). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) is in force, and security holes go through GitHub's private reporting — see [SECURITY.md](SECURITY.md).

## The name

It's wingman with the vowels taken out. A good wingman stays out of the way, and so do the vowels.

## Licence

MIT. Take it, fork it, ship it. Just don't blame the wingman.
