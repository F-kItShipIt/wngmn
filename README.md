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

You're on a call. wngmn sits next to it on your Mac, writes down what the other person says, and slides an answer in front of you while they're still waiting for yours. Claude drafts it out of notes you wrote, so it sounds like you on a good day. Interviews, sales calls, investor calls, the meeting that should have been an email. wngmn is not trying to join your meeting. It is already sitting next to you, and nobody on the call can see it.

![The caller finishes, the answer arrives, nobody touched the page](docs/images/auto.gif)

Every other tool in this space wants an account, a subscription, an Electron shell and a virtual audio driver that outlives the uninstall. wngmn is under 4 MB with no daemon, no driver and no account. It runs when you run it and it's gone when you quit. The only bill is your own Claude key.

## 1. Install

You need a Mac on **macOS 26** ( → About This Mac will tell you) and about fifteen minutes, most of which is you watching a progress bar.

Everything in a grey box goes into **Terminal**. Hit ⌘-Space, type `Terminal`, press Return. Paste one box at a time, press Return, and wait for the line ending in `%` to come back before you paste the next one. That is the entire skill.

**Apple's developer tools.** A window pops up, you click **Install**, you wait. If it says they're already installed, thank your past self.

```sh
xcode-select --install
```

**wngmn itself.** It builds from source for a few minutes and finishes with `==> Installed.` Sudo never comes up.

```sh
git clone https://github.com/F-kItShipIt/wngmn.git ~/wngmn && cd ~/wngmn && Scripts/install.sh
```

**Apple's speech model.** 396 MB, once, and after that the listening never leaves your Mac.

```sh
wngmn install-model --locale en-US
```

**Make sure your Mac lets it listen.** It plays a beep and says `PASS` or `FAIL`. If macOS asks whether Terminal can record audio, say **Allow**.

```sh
wngmn selftest
```

**Your Claude key.** A key is a password that lets wngmn ask Claude, and it is also what pays for the asking. A Claude.ai subscription is not a key, annoyingly. Get one at [platform.claude.com/settings/keys](https://platform.claude.com/settings/keys) by signing up, adding a little credit under **Billing**, then going to **API keys** → **Create key**. It starts with `sk-ant-` and you only get to see it once, so copy it. Then save it for good by swapping your own key into this line and keeping the quote marks.

```sh
echo 'export ANTHROPIC_API_KEY=sk-ant-YOUR-KEY-HERE' >> ~/.zshrc
```

Quit Terminal with ⌘Q and open it again. You're armed.

**`command not found: wngmn`?** Scroll up. The installer printed a line that starts with `echo 'export PATH=`. Paste it, press Return, quit Terminal, open it again.

**`selftest` said FAIL?** The line after FAIL names the culprit. *Digital silence* means macOS is denying you politely, which is to say every call reports success and hands back nothing. Go to  → System Settings → Privacy & Security → **Screen & System Audio Recording** and switch on **Terminal** in the top list. If it isn't there, press **+** and find it under Applications → Utilities. Quit Terminal with ⌘Q, open it, and run `wngmn selftest` again. *Far too quiet* just means turn the volume up. The long version is in [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

<details>
<summary>One-line install, pin a version, uninstall</summary>

The one-liner. It's 142 lines of shell and you're about to pipe it into bash, so read it.

```sh
curl -fsSL https://raw.githubusercontent.com/F-kItShipIt/wngmn/main/Scripts/bootstrap.sh | bash
```

The same thing, pinned to a version. `git tag` lists them. Anything older than v0.4.0 can't take screenshots, makes you ask for every answer, and only listens to Zoom and Chrome.

```sh
curl -fsSL https://raw.githubusercontent.com/F-kItShipIt/wngmn/main/Scripts/bootstrap.sh | WNGMN_REF=v0.4.0 bash
```

Uninstall, from inside `~/wngmn`.

```sh
Scripts/install.sh --uninstall
```

It builds from source, so the app is signed for the Mac that built it and no other.

</details>

## 2. Start it

```sh
wngmn --listen
```

It prints two links and keeps running. **Leave that window open for the whole call**, because closing it is how wngmn dies. Ctrl-C does the same thing on purpose. Start it before the call and not during it, unless you enjoy debugging in front of an audience.

```
wngmn: live transcript → http://192.168.1.20:7373/?t=4fq8zj2m
wngmn:                    → http://your-mac.local:7373/?t=4fq8zj2m   (same page, stable name)
```

If it also says `no credentials`, your key didn't save. Back to step 1.

## 3. Open the link on your phone

Use the links in your own Terminal and not the example above, which belongs to nobody. Put the phone on the same Wi-Fi as the Mac, copy the second link, and AirDrop or message it to yourself. You can also type it into the phone's browser by hand, `?t=` and all, if you're into that. Bookmark it, because it's the same link every time.

You should see this. Prop the phone just under your webcam so your eyes stay where a confident person's eyes would be.

<img src="docs/images/phone.png" alt="The page on a phone, showing the transcript and an answer" width="560">

No phone? Right-click the link in Terminal and pick **Open URL**.

## 4. Join the call

That's the whole setup. They ask something and it shows up on your phone. A moment later, so does an answer. Read it, nod thoughtfully, say it in your own words.

### Try it right now, no call required

Start it, open the link, and play any video of a person talking **on the Mac, not the phone**. YouTube is fine. Their words land as lines and the answers follow. If nothing lands, skip to [Not working?](#not-working)

## What you can do

### Get answers without touching anything

This is on from the start. Somebody finishes talking, wngmn asks Claude, the answer appears. You press nothing.

- Untick **auto** on the page to make it stop, or start with `--no-auto` and it never begins.
- Small talk gets no answer, and that's deliberate. Nobody needs help with "how was your weekend".
- Every question sent to Claude costs a little on your key. The side panel on the Mac's copy of the page keeps a tally that reads `auto: 3 answered · 4 calls`, where a call is one question sent to Claude and not a phone call.

### Ask about one line

With auto off, tap **Ask** next to any line. Tap the line again later and its answer comes back for free.

![Question lands, Ask pressed, answer streams](docs/images/ask.gif)

### Screenshot a problem

They pasted the question into a doc instead of saying it out loud like a normal person. Fine. Take a picture of it. This one lets you drag a box around it, and Esc backs out.

```sh
wngmn shot --region
```

This one grabs the whole main screen.

```sh
wngmn shot
```

The answer shows up like any other. With auto on, wngmn remembers the picture, so when they follow up with "can you do that faster?" it knows what "that" is.

**Put it on a key**, because you will not be typing commands in the middle of an interview.

1. In Terminal, run `command -v wngmn`. It prints where wngmn lives. Copy that.
2. Open the **Shortcuts** app, press **+**, search for **Run Shell Script** and double-click it.
3. In its box, paste what you copied, then a space, then `shot --region`.
4. Click ⓘ, then **Add Keyboard Shortcut**, then press the keys you want.
5. Want the whole screen on a key too? Do it again with plain `shot`.

Press your key once before the call. The first time, macOS asks whether Terminal can record the screen. Allow it, quit Terminal with ⌘Q, and start wngmn again.

### Both sides of the call

It hears them and it hears you, labelled Caller and You, in whatever app the call happens to be in. The first time, macOS asks whether Terminal can use the microphone, and the answer is yes. If you only want their side, say so.

```sh
wngmn --listen --no-mic
```

It uses whatever mic and speakers your Mac is already using. The built-in ones are fine and nothing needs plugging in first. On speakers your mic can hear the other person too, so wngmn notices and ignores your mic while they're talking, which means their words show up once and as theirs. The price is that anything you say over the top of them is lost. On headphones nothing is. Wired beats AirPods, since a Bluetooth headset using its own mic drags the whole call down to phone quality.

### Stop it hearing them, or you

Two buttons at the top of the page, and they work from the phone.

- **⏸ listening** stops it hearing them when you tap it, or press `p`. Nothing they say is written down or sent while it's paused. `--start-paused` starts it that way.
- **mic on** stops wngmn hearing your mic when you tap it, or press `m`. This does **not** mute you on the call. Your call app has its own button for that, and you should probably know where it is.

### Get notes at the end

Tap **▸ notes**, or say yes when it asks whether the call is over. You get meeting notes from everything auto heard, plus any screenshots, with a **copy** button. If auto was off for the whole call there's nothing to write them from, and it will say so.

### Make the answers sound like you

Without this the answers come from general knowledge, which is to say from everybody. With it they come from your story. Make your file from the template and open it.

```sh
cp ~/wngmn/profiles/TEMPLATE.md ~/me.md && open -e ~/me.md
```

Fill it in along these lines, then hit ⌘S.

```markdown
# Me

## Style
Short sentences, real examples. Say "I don't know" when I don't.

## Context
Paste everything. Your CV, the job post, your projects, the numbers you want to get right.
The more you put here, the better the answers. It's only sent when an answer is needed.

## Terms
Kubernetes | cooper netties | goober netties
```

```sh
wngmn --listen --profile ~/me.md
```

**Style** is how you talk. **Context** is what you know, so pile it on. **Terms** fixes the words it mishears, with the right word first and then whatever nonsense it heard instead. Only those three `##` headings get read. Any other `##`, like the ones hiding inside a pasted CV, gets named at startup and then ignored along with everything under it, so turn those into `###`. When it starts, wngmn prints `profile …` with the sizes, and if it prints `could not be read` instead, the path is wrong.

There are ready-made ones for [hiring](profiles/hiring.md), [investor](profiles/investor.md) and [technical](profiles/technical.md) calls in [`profiles/`](profiles). A bare name is a shortcut, so `--profile hiring` reads `./profiles/hiring.md` from the folder you start wngmn in. Edit the file mid-call and **Terms**, plus any answer you **Ask** for, pick it up the moment you save. Auto keeps the Style and Context it started with.

## Not working?

Nothing in here prints an error. It just goes quiet, which is worse, so check the night before.

| What you see | Why | Fix |
| --- | --- | --- |
| No lines when **they** talk | macOS isn't letting Terminal listen, or the call isn't playing on this Mac | Run `wngmn selftest`. FAIL means fix the permission in step 1. PASS means check the call's sound is coming out of this Mac and not your phone |
| No lines when **you** talk | macOS isn't letting Terminal use the microphone | System Settings → Privacy & Security → **Microphone**, switch on **Terminal**, quit Terminal, start again |
| Their lines show up twice, as Caller and as You | Your mic hears them through the speakers and wngmn hasn't caught it, which takes a very echoey room or `--no-echo-gate` | Headphones, or `--no-mic` |
| My words vanish when we talk at once | On speakers, wngmn ignores your mic while they're talking | Headphones |
| It writes down my music, and every ding | It hears everything the Mac plays | `--call-apps` keeps it to Zoom and Chrome. Or turn the music off |
| Lines, but no answers | No key, or **auto** is unticked | Run `echo $ANTHROPIC_API_KEY`. Empty means it never saved. Then tick **auto** |
| Lines, a few answers, mostly nothing | It only answers questions, and small talk isn't one | Nothing is wrong |
| Screenshot says *Screen Recording is not granted* | macOS hasn't let Terminal see the screen | Same Settings pane as `selftest`, top list, then quit Terminal and start again |
| Phone can't open the link | Different Wi-Fi, or you started with `--serve`, which is this Mac only | Same Wi-Fi, and start with `--listen` |
| It died and the call didn't | Things die | Start it exactly as before and add `--resume`. The transcript comes back |

## Cheat sheet

| Type this | What it does |
| --- | --- |
| `wngmn --listen` | Start. Hears both sides, in any app. Prints the link for your phone |
| `wngmn --listen --no-mic` | Their side only |
| `wngmn --listen --call-apps` | Zoom and Chrome only, so your music stays out of it |
| `wngmn --listen --profile ~/me.md` | Answers from your notes |
| `wngmn --listen --no-auto` | Answers only when you tap **Ask** |
| `wngmn --serve` | This Mac only, at http://127.0.0.1:7373 |
| `wngmn shot --region` | Screenshot a problem (put it on a key) |
| `wngmn --listen --resume` | Pick the transcript back up after a crash |
| `wngmn stop` | Stop every wngmn that's running |
| `wngmn --help` | Every flag there is |

Flags stack, so `wngmn --listen --call-apps --profile ~/me.md` is a perfectly good sentence. The ones worth knowing, with examples, live in [docs/USAGE.md](docs/USAGE.md).

## Privacy

There is no server, so there is nothing to collect and no way for this project to reach you. No analytics, no crash reporter, no dependencies at all. Whatever leaves your Mac goes to Anthropic on your own key, and this is the whole list.

- **Audio** never leaves. Speech becomes text on your Mac, and that covers theirs, yours and anything else the Mac plays while wngmn is running. `--call-apps` and `--no-mic` shrink that.
- **auto**, which is on unless you pass `--no-auto`, sends each turn as it ends, theirs and yours, along with the conversation so far and your profile. wngmn says so when it starts.
- **Ask** sends that line, the few before it and your profile when you tap. Tick **prefetch** on the page and it goes for every line of theirs the moment it lands.
- **shot** sends a picture of your screen when you press your key. It stays in the conversation and rides along with every later answer until two newer screenshots replace it. Whatever else is on the screen goes with it, so drag a region if that matters. A copy is saved with that call's transcript, so the history has its pictures too.
- **notes** sends the conversation auto already sent, once more, when you tap **▸ notes**.
- **The transcript** is saved on your own disk, answers and screenshots included. `--no-log` turns that off.
- **`--listen`** puts the page on your Wi-Fi, locked by the secret code at the end of the link, the `?t=…` part. Anyone holding the full link can read along, so don't hand it out. Screenshots can only ever be triggered from the Mac itself.
- **`install-model`** is a download from Apple. Nothing of yours goes with it.

The fine print, including what other software on your Mac could do with all this, is in [SECURITY.md](SECURITY.md).

## Is this cheating?

It's a prompter. Newsreaders use one. It knows only what you typed into a file, and it does none of the talking. Some rooms ban help, though, and some interviewers just ask. Know which room you're walking into.

## What wngmn is not

wngmn is not a meeting recorder designed for secretly collecting conversations. It is not intended to bypass consent requirements, workplace policies, interview rules, or local recording laws. Audio and transcription laws vary depending on where you live and who is participating in the conversation. Make sure your use complies with the rules that apply to you. It is also not trying to replace your brain. It is trying to make sure your brain has backup.

## Go deeper

[More flags, with examples](docs/USAGE.md) · [the page you read during a call](docs/PAGE.md) · [permissions and audio routes](docs/PERMISSIONS.md) · [tuning the speech detector](docs/TUNING.md) · [how it's built](docs/ARCHITECTURE.md) · [security](SECURITY.md) · [regenerating the GIFs](docs/tapes/README.md)

## Contributing

If you find a bug, open an issue. If you know why the audio pipeline behaves differently on a machine it has absolutely no reason to behave differently on, definitely open an issue. Pull requests are welcome. Keep changes focused, keep dependencies justified, and try not to turn the tiny HTTP server into Kubernetes.

Start with [CONTRIBUTING.md](CONTRIBUTING.md). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) is in force. Found a security hole? Use GitHub's private vulnerability reporting, and the details are in [SECURITY.md](SECURITY.md).

## The name

It's wingman with the vowels taken out. A good wingman stays out of the way, and so do the vowels.

## Licence

MIT. Take it, fork it, ship it. Just don't blame the wingman.
