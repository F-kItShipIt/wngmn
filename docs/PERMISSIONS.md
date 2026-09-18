# Permissions and audio routing

[wngmn](../README.md) · [Usage](USAGE.md) · [Architecture](ARCHITECTURE.md) · [Tuning](TUNING.md) · [The page](PAGE.md) · [Security](../SECURITY.md) · [Contributing](../CONTRIBUTING.md)

The hardest thing about running wngmn is not the code. It is that macOS can deny it audio
without saying so, and that a denial and a quiet room produce byte-identical output. This
document is the operational detail behind that, and the checklist to work through before the
first interview.

Read it once. Then run `wngmn selftest` on the morning of every interview.

## Who holds the grant

macOS grants System Audio Recording, Microphone and Screen Recording to a *process*, and a command-line binary
has no identity of its own. The grant attaches to the **parent process** — the app that
launched it. Start `wngmn` from a shell and the grant belongs to Terminal, iTerm, Ghostty or
whatever else is running the shell; wngmn itself never appears in System Settings at all.

`selftest` prints which app that is, read from `TERM_PROGRAM`, so you are not guessing:

```
wngmn selftest — playing a 440 Hz tone for 3s.
  terminal app: iTerm.app  (the System Audio Recording grant belongs to this app, not to wngmn)
```

Two consequences follow. Anything else you run from the same terminal inherits the same
grant. And swapping terminals — trying a run from a different one, or from an editor's
integrated shell — starts from no grant at all, with no error to say so.

## The two ways to run, and how they differ

**From a shell.** `wngmn --serve`. Permissions are the terminal's, as above. Simplest, and
stdout is right in front of you. This is the case the rest of this document assumes unless it
says otherwise.

**Through the bundle.** `Scripts/install.sh` builds `wngmn.app`, signs it as one bundle, and
installs it. Launched through LaunchServices the parent is `launchd` rather than your shell,
so macOS treats it as its own TCC subject: it prompts under its own name, it gets its own row
in System Settings, and it remembers the answer independently of any terminal.

```sh
Scripts/install.sh
open -a /Applications/wngmn.app --stdout ~/wngmn.log --args --serve --listen
```

stdout has to be redirected, because there is no terminal attached. The bundle sets
`LSUIElement`, so it has no Dock icon — it is a terminal tool that happens to need an
identity.

Three details of that bundle exist because TCC is picky about identity, and each of them has
already caused a silent failure:

* **The identifier is fixed.** `local.wngmn.Wngmn` — `.local` is reserved by RFC 6762, so it
  cannot collide with a real domain and claims none. Changing it creates a new TCC subject,
  and every permission already granted is forgotten.
* **The bundle must not move.** TCC keys a grant to the bundle's path as well as its
  identity. `install.sh` installs into `/Applications` (or `~/Applications`) and defaults to
  wherever a bundle already is, because installing a second copy elsewhere is not an upgrade:
  the link on `$PATH` keeps launching the old one, and the new copy starts with no grants.
* **It is signed as a bundle, with usage strings.** TCC keys the grant to the signing identity
  plus the bundle id, so an unsigned or separately-signed loose executable is a different
  subject on every build and you are asked again each time. macOS also refuses a permission
  outright when the `Info.plist` key for that resource is missing, so `NSAudioCaptureUsageDescription`
  and `NSMicrophoneUsageDescription` are load-bearing, not decoration.

`install.sh` ad-hoc signs. The result is trusted by the Mac that built it and no other;
distributing it would need a Developer ID certificate and notarisation, which the script
deliberately does not set up.

## What a denial looks like

Nothing. That is the whole problem.

With System Audio Recording denied, `AudioHardwareCreateProcessTap` succeeds, the aggregate
device is created, `AudioDeviceStart` returns `noErr`, the IOProc fires on schedule, and every
buffer it delivers is filled with zeros. Every status code reads `noErr`. There is no error
event, no log line, no modal. The transcript is simply empty, exactly as it would be if the
other person had said nothing.

The microphone behaves the same way: a denial yields silence rather than an error, which is
why `MicCapture` keeps diagnostics counters at all — they are the only way to tell "nobody is
speaking" apart from "we were never allowed to listen".

## Why selftest plays a tone

The obvious check is passive: capture three seconds and see whether the samples are zero. It
cannot work, for a reason that is not about permissions at all — a tap-backed aggregate only
clocks while the tapped output device is running. With nothing playing, the correct and
healthy behaviour is to deliver no buffers. Quiet, idle and denied are indistinguishable from
the outside.

So `selftest` is an active probe. It plays a 440 Hz sine at amplitude 0.15 through the default
output using `AVAudioEngine`, taps globally — the tone comes from wngmn's own process, so a
tap scoped to Zoom would correctly capture nothing and the result would mean nothing — and
asserts that the captured peak exceeds 0.001. That threshold sits well above the noise floor
of a real capture and well below the tone's own level. The default run is three seconds;
`--seconds <n>` changes it.

It separates the failure modes explicitly, because they look identical from outside and have
completely different fixes:

| What it prints | What it means |
| --- | --- |
| `FAIL  could not build the capture graph` | The tap or the aggregate would not be created at all. Real error, in the message. |
| `FAIL  The IOProc never fired` | The capture graph is not clocking. The tapped **output** device is not running — see the keepalive section below. |
| `FAIL  The IOProc fired but no frames reached the consumer` | Not a permission problem; nothing was examined, so nothing can be concluded. Re-run; if it persists it is a bug. |
| `FAIL  Buffers arrived, and every sample was digital silence` | This is what a denied System Audio Recording grant looks like. |
| `FAIL  Captured audio is far too quiet` | Peak below 0.001. Check output volume and that the tone was audible. |
| `PASS  The tap hears system audio.` | Capture works. |

One caveat the tool states itself: if playback would not start, it says so, and a silent
result then proves nothing — there was no tone to hear. Fix playback first.

`selftest` also writes `selftest_peak`, `selftest_rms_db` and `selftest_frames` metric lines
to stdout as JSON, and exits non-zero on failure, so it can gate a script.

## The roughly thirty-day reauthorisation

macOS re-authorises the Screen & System Audio Recording category about every thirty days. The
grant does not disappear, but the prompt comes back — and it can come back mid-call. This is
the main reason `selftest` is a morning-of ritual rather than a one-time setup step: a run
that worked last week is not evidence about today.

## The microphone entitlement

Only relevant to `--mic`, `miccheck`, and only in the bundle.

Under the hardened runtime (`codesign --options runtime`), microphone access is denied by AMFI
*before TCC is ever consulted* unless the binary carries
`com.apple.security.device.audio-input`. The failure is not a refused prompt — it is no prompt
at all, and a capture full of silence. `Scripts/wngmn.entitlements` carries exactly that one
key.

Two traps around it, both already hit:

* The entitlements file carries **no XML comments**. AMFI's parser rejects them, `codesign`
  then reports "Failed to parse entitlements" and still exits 0.
* Signing can appear to succeed having silently dropped what was asked for, so `build-app.sh`
  reads the entitlements back out of the finished bundle and warns if `audio-input` is not
  there:

  ```
      WARNING  the bundle carries no microphone entitlement; --mic will capture silence
  ```

  If you see that line, `--mic` will not work no matter what System Settings says.

## Screen Recording, for `wngmn shot`

Only relevant to `wngmn shot`. Nothing else in wngmn looks at the screen.

**The running wngmn takes the picture, not the command you bound to a key.** `wngmn shot`
only posts a few bytes to the wngmn that is already serving; that process spawns
`/usr/sbin/screencapture`. So the grant that matters is the one held by whatever launched the
*long-running* wngmn — the same subject as the audio grant, by the same rule as above. From a
shell that is your terminal. Your launcher — Shortcuts, Raycast, skhd — needs no grant at all.

**It sits in the same Settings pane as the audio grant, and it is a different grant.** System
Settings → Privacy & Security → Screen & System Audio Recording has two lists. An app under
*System Audio Recording Only* can run the tap and cannot take a screenshot. It has to be in
the upper list. A terminal you have ever used to share your screen is usually already there.

**A denial is silent here too, and looks like your wallpaper.** Without the grant
`screencapture` does not fail: it exits 0 and writes a picture of the desktop with no windows
on it — the menu bar, the wallpaper, and nothing you were looking at. Sent as it is, that would
be a confident answer about an empty desk. So wngmn asks first: before every shot, until it
has once been told yes, it calls `CGPreflightScreenCaptureAccess`, which never prompts. If the
answer is no, nothing is captured and nothing is sent; the shot appears on the page as a row
with the reason on it — on the stage, not only in the side panel, which a phone does not show
— and the first refusal of a run also calls `CGRequestScreenCaptureAccess`, because the
preflight alone never makes macOS add the app to the list for you to tick.

The grant is read when the app starts. After ticking it, quit and reopen the terminal, then
start wngmn again.

**Rehearse it.** Press both keys once before the call, the way you run `selftest`. The first
shot of a machine's life is when macOS asks, and the middle of an interview is the wrong time
to be reading a permissions dialog. macOS also re-confirms this category roughly monthly — see
*The roughly thirty-day reauthorisation* above — and that prompt is just as badly timed.

Not verified on the machine this was written on, because wngmn is launched from a shell there:
how long the grant survives for the *bundle* launched through LaunchServices. `install.sh`
ad-hoc signs, and an ad-hoc signature's designated requirement is the code hash, so a rebuilt
bundle may be a new subject to TCC and need ticking again. If you run it that way, check after
every install.

## Audio routing: two traps that are not permissions

Both of these are easy to mistake for a denial, so they belong in the same document.

### A Bluetooth headset used for both output and input

Opening a Bluetooth headset's microphone switches the link into duplex mode, and the output
device's sample rate drops with it — 48 kHz to 24 on AirPods. The tap keeps delivering, but
its format property still claims 48 kHz while the aggregate it runs on delivers 24, and read
at the wrong rate the caller came back as fragments or not at all. Measured: `selftest`
counted 72,000 frames in 3 s under a format that read 48,000. The capture graph now takes its
rate from the aggregate, and rebuilds if the clock device's rate changes mid-call, so the
caller is transcribed at phone quality rather than lost:

```
{"type":"status","state":"capturing","format":{"rate":24000,"ch":1},"detail":"clock device runs at 24000 Hz, the tap advertised 48000; capturing at the clock rate"}
```

wngmn checks the *system* default input rather than its own, because the conferencing app
opens a microphone too — Zoom pointed at the headset puts the link in duplex whatever wngmn
was told to use. When both defaults are the same Bluetooth device it says so at startup and
again at the end of `wngmn devices`:

```
ROUTE NOTE
  'AirPods Max' is both the default output and the default input, so the
  Bluetooth link runs in duplex: the caller arrives at phone quality and
  wngmn captures at the link's rate.
```

Nothing needs changing for capture to work. If jargon suffers at phone quality, point the
microphone somewhere else — in System Settings **and** in the conferencing app, which opens
its own — and the link stays at full rate; you can keep listening through the headset.
`miccheck` says the same if the device it is about to measure is Bluetooth.

If the route changes mid-call, the tap keeps clocking and latency still looks fine, so the
pipeline watches for a second signature: buffers arriving whose loudest sample has stayed
below −60 dBFS for more than 120 seconds emits `{"type":"warning","code":"silent_capture",...}`.

### The aggregate only clocks while the tapped output device runs

The aggregate is clocked by the current default output device. When that device is idle,
`AudioDeviceStart` returns `noErr`, `kAudioDevicePropertyDeviceIsRunning` reads 0, and the
IOProc fires zero times, forever. Measured causally: 0 callbacks over 2 s with the speakers
idle, 202 callbacks after attaching a silent output IOProc to them.

That is what the keepalive is. wngmn holds the tapped output device open for the whole session
with an IOProc that writes explicit zeros into the output buffers — explicit, because they are
not guaranteed to arrive zeroed and handing the speakers uninitialised memory during an
interview would be loud. It is on by default; `--no-keepalive` turns it off, and `selftest`
says so in its own failure message if you have.

Because whether something else happens to be playing is a coin flip, this failure without the
keepalive looks exactly like flakiness rather than like a bug.

### Changing the output device mid-call

The aggregate pins the default output device's UID at startup. Plug in headphones, switch to
AirPods, or sleep and wake the machine, and that sub-device vanishes: the IOProc stops firing
and every status code still reads `noErr`. There are property listeners for both events and a
rebuild path behind them, and a watchdog that warns with `{"type":"warning","code":"no_audio",...}`
after 90 seconds without a buffer and rebuilds after 240. None of it has been exercised on a
real call. Decide the route before the interview and do not touch it afterwards.

## First-run checklist

Work through this well before any interview, not on the day.

1. **Choose the audio route and then leave it alone.** System Settings → Sound. For a
   run without `--mic`, the built-in microphone and built-in speakers are the safest
   combination: nothing in that route can carry your own voice back into the output stream
   the tap reads. Set the microphone explicitly in the conferencing app too — not "Same as
   System" — because a virtual audio device installed by some other application is a common
   default and may be capturing nothing. With `--mic` the same route works: the microphone
   hears the caller through the speakers, so wngmn measures whether it can and, if so,
   ignores it while the other side is talking ([TUNING.md](TUNING.md#the-microphone-endpointer)).
   What you say over them is lost with the echo; wired headphones keep it. Either way, avoid
   a Bluetooth headset whose microphone will be in use.

2. **Grant System Audio Recording.** System Settings → Privacy & Security → Screen & System
   Audio Recording → enable your terminal app. If it is not listed, run wngmn once from it
   first so macOS learns it exists.

3. **Quit and reopen the terminal.** The grant is read at launch. A terminal window opened
   before the grant does not have it.

4. **Build.**

   ```sh
   swift build -c release
   ```

5. **Install the speech model.** Transcription runs on-device, and the model is not shipped
   with macOS:

   ```sh
   ./.build/release/wngmn install-model --locale en-US
   ```

   It is a 396 MB download, which is why it is an explicit command rather than something a
   run starts for you an hour before an interview. Skip it and the first real run stops
   before it captures anything:

   ```
   wngmn: speech model unavailable: en-US is not installed (installed: en_GB); run `wngmn install-model --locale en-US`
   ```

   The same text also goes to stdout as `{"type":"error","code":"fatal",...}` and the process
   exits 1. The bracketed list is whatever locales this machine does have, so it is also how
   you check a locale you meant to use is already there — on a clean machine it can be empty.
   `selftest` does not catch this: it exercises the tap and never starts the recogniser, so a
   PASS says nothing about the model.

6. **Run the gate, by path.**

   ```sh
   ./.build/release/wngmn selftest
   ```

   By path on purpose: a bare `wngmn` resolves through `$PATH` to whatever `Scripts/install.sh`
   last installed, which is a different binary from the one step 4 just built.

7. **Find the right bundle ID.** Start a call, play audio in it, and run
   `./.build/release/wngmn devices`. Look for which process reports `output=yes`. This is the
   only way to find out: a tap is created successfully, with a valid format, for bundle IDs of
   apps that are not even installed, so a clean start proves nothing — and the default list is
   candidates, not a verified inventory.

   Of the five defaults, one is measured and the rest are guesses. On a live call, Meet audio
   came from `com.google.Chrome.helper` rather than `com.google.Chrome`; both are in the
   default scope, which costs nothing because the tap mixes only the apps listed. The three
   Zoom entries — `us.zoom.xos`, `us.zoom.CptHost`, `us.zoom.caphost` — have **not** been
   measured on a real call. Start there when you rehearse Zoom, and confirm with `devices`
   which of them reports `output=yes` before you rely on it.

8. **Solo talk-test.** Start a run, speak with nothing playing, and confirm your own voice does
   **not** appear. The tap reads the output stream and never opens the microphone, so on the
   route from step 1 it should not. Two minutes settles it either way — and if your voice does
   appear, there is monitor routing somewhere that would otherwise transcribe you as "the
   question".

9. **If you are using `--mic`, measure the threshold.** `wngmn miccheck` records for 15 seconds
   — talk for roughly half of it, at the volume and distance you would use on the call — and
   prints the `--mic-open-db` to pass. Guessing this value fails invisibly: partial text
   scrolls in the caption line while no sentence ever finalises, and that symptom is identical
   whether the threshold is too low or too high.

10. **Full rehearsal on a real call.** Five questions. Watch for false endpoints, drift over
    ten minutes, and jargon accuracy.

## What it looks like when it works

`selftest`, on a machine where everything is right:

```
wngmn selftest — playing a 440 Hz tone for 3s.
  terminal app: iTerm.app  (the System Audio Recording grant belongs to this app, not to wngmn)

  IOProc callbacks : <hundreds>
  frames captured  : <roughly three seconds at 48 kHz>
  non-zero samples : <the same, or close to it>
  peak / rms       : 0.1499xx / -19.5 dBFS

PASS  The tap hears system audio. Capture is working.
```

The counts vary with buffer size and machine, so the shape is what to read, not the figures:
callbacks well above zero, frames captured, non-zero samples equal or close to frames
captured, and a peak in the neighbourhood of the tone's own 0.15 amplitude — a continuous sine
at that level measures about −19.5 dBFS RMS. A peak of 0.000000 alongside callbacks in the
hundreds is a denial, not a quiet room.

A run, once the call starts, prints a `status` line and then questions:

```json
{"type":"status","state":"capturing","format":{"rate":48000,"ch":1}}
{"type":"question","text":"So tell me about the funding round.","t0":10.88,"t1":13.02,"ms":74}
```

`"state":"capturing"` with a 48 kHz mono format means the graph is built. It does not mean the
grant is good — that is what step 6 is for. Questions appearing within a second or two of the
other person finishing a sentence means everything is.

## Resetting and removing

`Scripts/install.sh --uninstall` removes the bundle and the `$PATH` link. Permissions granted
to it are still remembered; to clear them:

```sh
tccutil reset Microphone local.wngmn.Wngmn
tccutil reset ScreenCapture local.wngmn.Wngmn
```

The stored access token for the served page is left alone, at
`~/Library/Application Support/wngmn/token`.

To revoke the shell-launched grant instead, turn your terminal off in System Settings →
Privacy & Security → Screen & System Audio Recording, and quit and reopen it.

If a run was killed rather than asked to stop, it can leave a private aggregate device behind —
invisible to `system_profiler` by construction, so nothing else would ever show it.
`wngmn stop` stops every other running wngmn and sweeps those up; it only ever destroys
devices carrying wngmn's own UID prefix. `wngmn devices` lists any that remain, and the HAL
caches its device list for about a second after a destroy, so re-run before concluding
anything.
