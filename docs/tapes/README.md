# Regenerating the README media

Three assets, all captured from real runs against the recorded fixture in
`Tests/WngmnAudioTests/Fixtures/two-questions.wav`. Nothing here is mocked or hand-drawn, so
the numbers on screen are measurements and will differ slightly run to run.

All three need `wngmn` on PATH and the en-US speech model installed.

## `docs/images/cli.gif` — the JSON Lines stream

```sh
vhs docs/tapes/cli.tape
```

Needs [VHS](https://github.com/charmbracelet/vhs) and `jq`. The tape replays at `--speed 1`,
so the recording takes as long as the audio does and the latency in it is real. Playing it
faster would finish sooner and report numbers that no live call would produce.

## `docs/images/ask.gif` — the served page

Not a VHS tape: VHS records a terminal, and this is a browser. It is a Playwright screenshot
loop instead, driven against a live server.

**1.** Pad the fixture with silence, so the server outlives the capture. The clip is 6.7s and
the recording needs about 30s plus the round trip to the Claude API:

```sh
python3 - <<'PY'
import wave
w = wave.open("Tests/WngmnAudioTests/Fixtures/two-questions.wav")
p = w.getparams(); frames = w.readframes(w.getnframes()); w.close()
unit = p.framerate * p.sampwidth * p.nchannels
out = wave.open("/tmp/demo.wav", "wb"); out.setparams(p)
out.writeframes(b"\x00" * unit * 3 + frames + b"\x00" * unit * 300)
out.close()
PY
```

**2.** Serve it at real speed, with the example profile so Ask has something to answer from.
This spends one real API call, so `ANTHROPIC_API_KEY` must be set:

```sh
wngmn offline /tmp/demo.wav --serve --no-log --speed 1 \
    --profile profiles/example-interview.md
```

**3.** Drive the page and write one PNG every 250 ms into `/tmp/frames`. Viewport 1440x680:
narrower than about 1400 and the latency caption wraps to two lines, shorter than about 660
and the panel's warnings row falls below the fold.

```js
await page.setViewportSize({ width: 1440, height: 680 });
await page.goto("http://127.0.0.1:7373/");
await page.waitForSelector("button.ask", { timeout: 90000 });

let n = 0, clicked = false;
const started = Date.now();
while (Date.now() - started < 28000) {
    await page.screenshot({ path: `/tmp/frames/f${String(n++).padStart(4, "0")}.png` });
    const asks = await page.locator("button.ask").count();
    if (!clicked && asks >= 2 && Date.now() - started > 2500) {
        await page.locator("button.ask").first().click();
        clicked = true;
    }
    await page.waitForTimeout(250);
}
```

**4.** Assemble. Frames are 250 ms apart, so 4 fps is real time. The two-pass palette matters:
the page is mostly flat greys and a single shared 256-colour palette bands the answer text
badly.

```sh
ffmpeg -framerate 4 -i /tmp/frames/f%04d.png \
    -vf "scale=1180:-1:flags=lanczos,palettegen=stats_mode=diff" -y /tmp/pal.png
ffmpeg -framerate 4 -i /tmp/frames/f%04d.png -i /tmp/pal.png \
    -lavfi "scale=1180:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
    -y docs/images/ask.gif
```

## `docs/images/phone.png` — the page at phone width

Same server as the GIF, started with `--listen` instead of `--serve` so the capture uses the
token URL a phone would. Viewport 390x844, which is below the 820 px breakpoint where the
page swaps the split layout for two tabs.

Two screenshots: the **Transcript** tab once both questions have landed, then the **Answer**
tab after tapping Ask on one of them (the page switches tabs on its own). Composited side by
side with a 28 px white gutter:

```sh
ffmpeg -i phone-transcript.png -i phone-answer.png \
    -filter_complex "[0]pad=iw+28:ih:0:0:color=0xffffff[a];[a][1]hstack" -y docs/images/phone.png
```

The URL and token printed in the README's phone section are illustrative, not the ones from
this machine.

## `docs/images/use-*.gif` — one per profile

Three runs of the same pipeline against `profiles/hiring.md`, `profiles/investor.md` and
`profiles/technical.md`, to show that the answer follows the profile and nothing else.

The questions are synthesised with `say`, because no fixture in the repo asks about a burn
rate. Pick the wording carefully: the recogniser reads synthetic speech well but not
perfectly, and "after the raise" came back as "after the race", "traffic tripled" as "traffic
trickled", and "the write path" as "the right path". Those are artefacts of the synthetic
voice rather than errors a real speaker would provoke, so the question was reworded until it
transcribed clean rather than papered over with a `## Terms` entry.

```sh
say -v Samantha -o q.wav --data-format=LEI16@16000 "Tell me about a time you disagreed with your manager."
```

Pad with two seconds of lead-in and a long tail (as above), serve each on its own port at
`--speed 1`, then run the same screenshot loop at 1280x600 and assemble at 900 px wide. One
real Claude call per GIF.

## `docs/images/logo.png`, `logo-dark.png` — the mark

Supplied artwork, not generated here. Two variants of the same design: dark ink for light
backgrounds, light ink for dark ones, referenced from the README through a `<picture>` so
GitHub swaps them with the reader's theme. Either one alone disappears against one of the two.

Both are cropped to the *union* of their alpha bounding boxes, so the two files line up exactly
when the theme flips:

```sh
ffmpeg -i original.png -vf "crop=900:560:135:417,scale=-1:220:flags=lanczos" -y logo.png
```

The source images were 1254x1254 with the mark floating in the middle; uncropped, the padding
makes it impossible to sit the logo on the same line as the title.

## What is deliberately not shown

There is no recording of the two-speaker transcript, the one where lines are labelled Caller
and You. `offline` never opens the microphone — it replays a file through the tap path only —
so the "You" half cannot be produced from a fixture. Capturing it honestly needs a live call
with headphones on, because on speakers the microphone hears the caller too and the same
sentence is transcribed under both labels.
