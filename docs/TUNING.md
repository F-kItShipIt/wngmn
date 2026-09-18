# Tuning

[wngmn](../README.md) · [Usage](USAGE.md) · [Architecture](ARCHITECTURE.md) · [Permissions](PERMISSIONS.md) · [The page](PAGE.md) · [Security](../SECURITY.md) · [Contributing](../CONTRIBUTING.md)

Making wngmn work well on a particular voice, a particular room and a particular
conversation. Nearly all of it is a command-line flag or a file you write, and needs no
rebuild; the three values that are not are named under *The knobs* below.

Most of it you will never touch. The order worth going in:

1. `wngmn selftest` — the go/no-go gate. Nothing below matters until the tap hears a tone.
2. `wngmn miccheck` — unless you run with `--no-mic`. It measures your room and prints the
   threshold to use.
3. A terms file or a profile `## Terms` section — jargon is the failure you will notice
   first and the one that is cheapest to fix.
4. `--hangover-ms`, and only against a recording. Retuning it from memory after a call is
   guessing; `wngmn offline` replays the call instead.

---

## What the endpointer actually does

`Sources/WngmnCore/Endpointer.swift` runs over the raw tap frames, ahead of the recogniser.
It computes RMS over non-overlapping 10 ms windows, converts to dBFS (floored at −120), and
walks a four-state machine. Two properties matter more to it than accuracy:

* **It must not fire mid-question.** A false boundary is worse than a late one, because it
  puts half a question in front of you while the other person is still talking.
* **It must fire even when the tap stops delivering buffers.** The tap elides silence rather
  than zero-filling it, so a pause in the conversation looks identical to a dead capture
  graph. `idle(upTo:)` advances the same state machine from the host clock — synthesising
  −120 dB windows — so the hangover completes whether or not audio is still flowing. (A very
  long stall, sleep/wake, is bounded: after 2000 synthesised windows the cursor jumps
  forward rather than spinning.)

The states:

| State | Leaves when |
| --- | --- |
| `silence` | a window reaches the open threshold → `onset`. The noise floor is tracked here. |
| `onset` | the level falls below the close threshold → back to `silence`; or it stays up for `onsetMs` → `speech`, and `speechStarted` is emitted. |
| `speech` | the level falls below the close threshold → `hangover`; or the utterance reaches `maxSpeechMs` → a forced endpoint. |
| `hangover` | the level reaches the open threshold again → back to `speech` (that was an inter-word gap); or the silence reaches `hangoverMs` → the endpoint fires. |

Onset is a confirmation delay, not a trim: the speech start recorded is the beginning of the
first above-threshold window, so raising `--onset-ms` delays *detection* without moving the
question's `t0`.

An endpoint carries `speechStart` (the question's `t0`), `speechEnd` (`t1`), and a
`decisionTime` that deliberately **includes** the hangover silence — that is what is passed
to `finalize(through:)`, and the recogniser transcribes trailing consonants better with a
little silence after them. It also carries `forced`, `continuesPrevious` and `chainStart`;
see *The trade-off* below.

An utterance shorter than `minSpeechMs` is discarded rather than emitted. A discarded blip
does not break a continuation chain: a cough or a notification ding between two halves of a
question must not stop the second half from being stitched onto the first.

---

## The knobs

Defaults are from `EndpointerConfig` in `Sources/WngmnCore/Endpointer.swift`; the flags are
parsed in `Options.swift`.

| Flag | Default | What it does |
| --- | --- | --- |
| `--hangover-ms` | 250 | Silence after speech before the endpoint fires. The primary knob, and it behaves linearly: it is added to the latency of every question. Real inter-word gaps in continuous speech are typically well under 200 ms, so 250 clears them while still firing long before the framework's own `isFinal` would. Must be positive. |
| `--onset-ms` | 80 | How long speech must stay above the open threshold before a question counts as started. Lower is twitchier; higher misses short questions. |
| `--min-speech-ms` | 350 | Utterances shorter than this are discarded as blips — mouse clicks, notification dings. A 150 ms ding trips onset but not this. Must be positive. |
| `--max-speech-ms` | 30000 | A monologue longer than this is force-endpointed, so the tool never goes mute during a long answer. Must be positive and at least `--min-speech-ms`. |
| `--open-db` | −45 | The absolute speech threshold in dBFS. Must be negative — a dropped minus sign would put the threshold above anything the tap can produce and no question would ever be detected, silently, for the whole interview, so the parser rejects it and suggests the flip. |
| `--merge-ms` | 700 | Speech resuming within this long of the last endpoint is a continuation of the same question rather than a new one. `0` never stitches. Must not be negative. |
| `--no-adaptive-floor` | off | Stop tracking the ambient noise floor and trust `--open-db` alone. |

Three further values have **no flag at all** — not a hidden one, not an environment variable,
and `--help` does not print them — because moving them has never been needed. Changing one
means editing its default in `EndpointerConfig` (`Sources/WngmnCore/Endpointer.swift`) and
rebuilding with `swift build -c release`. They are there if a room ever demands it:

* `windowMs` = 10 — the analysis window.
* `hysteresisDB` = 6 — the close threshold sits this far below the open one, which is what
  stops the detector chattering at the boundary.
* `noiseMarginDB` = 10 — speech must clear the tracked noise floor by this much.

### The open threshold, exactly

```
open  = adaptive ? min( max(openThresholdDB, noiseFloor + 10), openThresholdDB + 12 )
                 : openThresholdDB
close = open − 6
```

The noise floor starts at −70 dBFS and is updated only while the detector is out of speech —
in `silence`, and on the window that abandons an `onset` — with an asymmetric
tracker: it falls toward a quieter room fast (α 0.25) and rises slowly (α 0.002), so a
single loud window cannot desensitise the detector. It is clamped to [−100, −20].

Because the floor only ever *raises* the threshold, adaptation can hurt as well as help,
which is what `maximumAdaptationDB` = 12 is for. Without a ceiling the adaptation ratchets:
sustained hold music at −30 dBFS is never loud enough to count as speech, so it feeds the
floor, which raises the threshold, which lets still louder audio feed the floor. The
detector ends up deaf to someone speaking at −25 dBFS — mid-interview, with no error
anywhere. Twelve dB covers a noisy room; beyond that the absolute threshold is the safer
authority. At the default `--open-db -45`, the effective threshold can therefore never
exceed −33 dBFS.

---

## The trade-off at the centre of it

This is the measurement the whole design turns on.

Someone pausing mid-sentence to choose their words leaves a gap of **530 ms** on the
`hesitation` fixture. Two genuinely separate questions on the `two-questions` fixture are
**1.2 s** apart. Those overlap in the way that matters: **no single silence threshold
separates a hesitation from an ending.**

Raising the hangover does close the split — at **600 ms** the hesitation fixture yields one
endpoint instead of two, and the two-question fixture still yields two
(`Tests/WngmnCoreTests/GoldenVADTests.swift`). But it spends 350 ms more of the end-to-end
budget on every question in order to protect the rare one. The served page charts
endpoint-to-final latency against a 700 ms end-to-end budget, drawing the rule at
`700 − hangover − 30 ms` of delivery lag: at the default 250 ms hangover that leaves 420 ms
for the recogniser, and at 600 ms it leaves 70 ms. The common case pays for the rare one.

So wngmn does not wait longer. It emits the half immediately, and stitches the rest on when
it arrives:

* When speech resumes within `--merge-ms` of the previous endpoint's `speechEnd`, the new
  endpoint carries `continuesPrevious` and a `chainStart` pointing at the first utterance in
  the chain.
* `QuestionAssembler` then re-emits **the whole joined question**, keeping the original
  `t0`, with `"revises":true`. It is a replacement, not an append — a consumer should track
  the last `question` line it displayed, since `warning` and `partial` lines can appear in
  between. A consumer that ignores the field still shows a correct transcript, briefly
  duplicated.
* The seam is repaired in `TextNormalizer.joinContinuation`: a trailing `.` or `,` on the
  first half is an artifact of a forced boundary and is dropped, while a `?` or `!` is not —
  the speaker really did finish a clause there. If the first half did not end a sentence and
  the second begins with a capitalised word from a closed list of continuation words (`the`,
  `and`, `that`, `how`, `because`, …), it is lower-cased. Lower-casing an arbitrary
  capitalised word would mangle a name, which is why the list is closed.

Chaining is bounded in three ways, each from a specific failure:

* A chain may not outgrow `--max-speech-ms`, or one long uninterrupted answer would keep
  extending the same question forever.
* A **forced** cut never starts a chain. The cut lands mid-speech, so the "gap" is zero and
  an unguarded chain would survive the very split meant to bound it: a 30 s question, then a
  60 s revision of it, then 90 s.
* A discarded blip neither extends nor restarts the window — the merge window is measured
  from the end of the last *real* utterance.

**When to change it.** If rehearsal shows splits are common in this speaker's rhythm and the
revisions are distracting, `--hangover-ms 600` removes them outright at the latency cost
above. `--merge-ms 0` goes the other way: never stitch, every pause is a new line.

**Raising the hangover does not slow the live caption.** The caption line costs nothing
extra: it is driven by the volatile results the transcriber already produces, so its lag is
the recogniser's own, and the `--hangover-ms` wait only ever delays the finished question
lines above it. Whatever you set here, words still appear on the page as they are spoken.

---

## Retuning against a recording: `offline`

```sh
wngmn offline clip.wav                      # 8x real time, the default
wngmn offline clip.wav --speed 1            # real time
wngmn offline clip.wav --hangover-ms 600    # the same clip, a different boundary
wngmn offline clip.wav --serve              # replay it into the transcript page
```

`offline` runs a recorded file through the same endpointer, resampler, analyser and
assembler as a live call and emits the same JSON Lines. It exercises everything except the
tap itself, so it needs no System Audio Recording permission and runs in any terminal — and
it is how a rehearsal recording gets replayed afterwards to tune `--hangover-ms` without
booking another call. Any format `AVAudioFile` reads works; it is decoded to Float32 mono at
48 kHz, the tap's own format, so the resampler configuration is identical too.

It uses the **tap's** endpointer settings (`--hangover-ms`, `--open-db`, `--merge-ms`, …),
not the microphone's.

### Why it paces playback

`--speed` defaults to 8, and the pacing is not cosmetic. The endpointer forces finalisation
250 ms after speech stops, and the recogniser has to have actually decoded that speech by
then. On a live call it has — decoding runs at about 0.007x real time — but feeding a whole
file at once puts the forced finalise far ahead of the decoder, which then returns a final
containing nothing but punctuation and the words are lost for good. So the file is fed in
512-frame chunks with a sleep between them, keeping the decoder within reach of the
endpointer as it would be live. `--speed` must be positive; raise it and you are betting on
your machine, lower it and you are only spending time.

### What to watch in the output

* `"revises":true` — how often this speaker's pauses are being stitched. A steady stream of
  them is the signal to consider a longer hangover.
* `{"type":"warning","code":"question_lost",…}` — a boundary that produced no usable text.
  These are not recoverable, but they must be visible: a silent drop looks exactly like a
  quiet stretch of interview, which is the distinction you are trying to make.
* `"volatile":true` on a question, and the `volatile_fallback` warning — the forced final
  lost content the recogniser had already heard, and the volatile text was used instead. The
  question is still the best available transcription; the flag says its wording is less
  trustworthy than usual.
* `ms` — endpoint-to-final latency, emitted per question.

---

## `--debug-vad`

Emits one metric line carrying the most recent window's level:

```json
{"type":"metric","name":"vad_db","value":-52.4,"unit":"dBFS"}
```

One per buffer delivered by the tap (or per 512-frame chunk offline), so it is very noisy —
threshold tuning only, and never left on for a real call. It applies to `run` and `offline`.
With the microphone on, `run` adds `mic_db` for every mic buffer — as captured, before any
silencing — and, each time the echo gate refits, `echo_likeness`, `echo_gain_db` and
`echo_lag_ms` ([below](#the-microphone-endpointer)). Metrics are not replayable, so they go
to stdout but are never held for a page that reconnects.

The point of it is to pick `--open-db` from a distribution rather than from a guess:

```sh
wngmn offline clip.wav --debug-vad 2>/dev/null \
  | jq -r 'select(.name=="vad_db") | .value' \
  | sort -n | uniq -c
```

You are looking for two humps — the room and the voice — and a value between them, at least
6 dB above the room's loud end so the close threshold still finds silence. That is the same
arithmetic `miccheck` does automatically for the microphone.

---

## The microphone endpointer

Your own microphone is captured as a second speaker, labelled `you` against the caller's
`caller`, unless you pass `--no-mic`. It runs a **separate** `Endpointer` with its own configuration, and three
of its defaults differ from the tap's on purpose — the two sources are not the same problem.

| Flag | Mic default | Tap default | Why |
| --- | --- | --- | --- |
| `--mic-open-db` | −35 | −45 | Your mouth is inches from the microphone while the caller arrives through the tap at conversational level, so a threshold tuned for one is wrong for the other. This one is **a starting point written without measurement** — run `miccheck`. |
| `--mic-hangover-ms` | 800 | 250 | Waiting longer costs nothing here. The tap's 250 ms is buying latency: the caller's question has to be on screen fast enough to answer. Your own speech is never read back, so the only thing a longer wait affects is whether a natural mid-sentence pause is mistaken for the end of the sentence — and people pause for half a second mid-thought routinely. |
| `--mic-merge-ms` | 250 | 700 | The two sources pause for opposite reasons. The caller asks one question and hesitates inside it, so a gap is usually the middle of a thought and stitching it back is right. You speak several sentences in a row, so a gap is usually the end of one — and stitching there merges them into a single row that keeps being rewritten, which reads as the later sentences never arriving at all. `0` never stitches. |

Everything else — onset, minimum and maximum speech, hysteresis, the adaptive floor — is
shared with the tap's defaults. `--mic-open-db` is dBFS and must be negative;
`--mic-hangover-ms` must be positive; `--mic-merge-ms` must not be negative.

`--mic-device <uid>` picks an input other than the system default. Use
`wngmn devices` to find the UID.

**The mic half works on speakers.** There the microphone hears the caller as well as you.
Measured on a MacBook Pro at volume 81: the built-in mic heard the built-in speakers at
−17.8 dBFS over a −56.1 dBFS room, and every sentence the caller spoke arrived twice — once
from the tap as `caller`, once from the mic as `you`, 32 ms apart and word for word. So while
the far end's echo is loud enough to be taken for speech, the mic's audio is replaced with
silence before its endpointer or its recogniser hears it. The tap already has that half,
clean.

That is half-duplex, not echo cancellation: **what you say while they are talking is lost
with the echo.** On headphones there is no echo and nothing should be lost, and a device's
name is only a guess at the route, so the gate measures it — and measures the one thing an
echo is and your voice is not: a copy. For each lag from 0 to 500 ms it keeps the newest five
seconds *of loud far end* at that lag (above −35 dBFS; counted in far-end sound, not by the
clock, so an interviewer who only ever says "mm-hm" still adds up), and looks for the lag at
which the mic's level best follows the far end's, buffer by buffer. When Pearson's r there is
0.65 or more the mic is a copy. Built-in speakers into the built-in mic measured 0.74 to 0.82;
two recorded voices talking over each other never passed 0.54. The median difference in level
is then the route's gain (−6 dB, measured), and a buffer is silenced when the far end, through
that gain, could open the mic's detector — from the moment they speak until 200 ms after they
stop, for the room. An echo that could never open the mic (earbuds leaking a murmur, a speaker
turned right down, a fan behind the caller) is left alone.

Nothing is concluded until every lag has two seconds of evidence, and until then it assumes
speakers and silences the mic while the far end is loud and for 0.7 s after. Deaf for a moment
on headphones costs an interjection; open for a moment on speakers is the caller's first
sentence, twice. A failed fit does not end that doubt by itself: an echo is a floor under the
mic, so "no echo" needs moments when the far end was loud and the mic sat quietly under it —
which on headphones is the first time the caller talks while you listen, and which a call that
opens with both of you talking is not. Once found, an echo is not forgotten because you talked
over it. A copy in the newest two seconds alone is the same echo at a new volume, and takes
its new gain; otherwise it is forgotten only when the mic goes 10 dB *under* what the echo
should be, which an echo cannot do: that is a pair of headphones going in, and it takes about
two seconds of them talking. The other direction takes around five. A mic below −80 dBFS is
muted or stopped, not a room, and counts as nothing. An output more than half a second late —
AirPlay — is not recognised as an echo; use headphones there.

The decision is reported when it is made, as `{"type":"warning","code":"mic_hears_call",...}`,
and withdrawn as `mic_hears_call_cleared`. `--no-echo-gate` turns it off. `--debug-vad` adds
`mic_db` for every mic buffer, and `echo_likeness`, `echo_gain_db` and `echo_lag_ms` for every
fit.

A Bluetooth microphone has a cost of its own: using it puts the link into duplex mode and
the caller arrives at phone quality. The tap follows the link's rate, so they are still
transcribed; a different microphone keeps the link at full rate. Earbuds can also leak the
call into their own microphone — one pair, out of the ear, measured −21.8 dBFS against a
−54 dBFS room — and the gate treats that as what it is.

---

## `miccheck`

```sh
wngmn miccheck
wngmn miccheck --mic-device BuiltInMicrophoneDevice
```

`--mic-open-db` sits in a band with two hard edges, and **missing either produces the same
symptom from outside**: partial text scrolling in the caption line while no question ever
finalises.

* **Too low**, and the room itself never falls below the close threshold. The detector opens
  and never closes, so speech is "still happening" forever and no endpoint fires.
* **Too high**, and your voice never sustains above it for the onset window, so speech is
  never detected at all.

That is why this needs an instrument rather than another guess. `miccheck` discards one
second of device settling, records **15 seconds**, and separates the room from your voice
**by level, not by timing** — talk for roughly half of it, at the volume and distance you
would use on the call, and stay quiet for the rest. The order does not matter. (An earlier
two-phase version asked you to talk on cue, and any wrapper that buffers output delays the
cue past the window; the measurement then inverts and reports the room as *louder* than the
voice, which is impossible and was the first sign that the method rather than the room was
at fault.)

If you pass no `--mic-device` it says so — the system default input is not necessarily the
one you will run with, and a threshold measured on the wrong microphone is worse than none,
because it looks authoritative and describes a device that is not in the path.

### Reading the output

```
  room (loud end)    -58.2 dBFS
  voice (loud end)   -31.4 dBFS
  separation          26.8 dB

  PASS  Use:  --mic-open-db -43
```

* **room (loud end)** — the 95th percentile of the quiet group. A high percentile rather than
  the median, because the median of a room misses the fridge, and what decides whether the
  detector *closes* is the loud end.
* **voice (loud end)** — the 90th percentile of the loud group. The median of a speech
  recording is mostly the gaps between words.
* **separation** — voice minus room.

The two groups are found by Otsu's method: the split that maximises the variance *between*
them. A fixed percentile would have to assume how much of the recording is speech, and being
wrong about that moves the room's estimated ceiling, which is the number the whole threshold
hangs from. The split is rejected unless the two group means are at least 4 dB apart and at
least five windows fall on each side — a split through the middle of one distribution always
"wins" on variance.

**PASS** means a threshold exists that clears the room *and* catches the voice. The
recommendation is the midpoint of the band `[room + 6, voice − 2]`. The 6 is the hysteresis:
the close threshold sits 6 dB below the open one, so to hear silence at all the room has to
fall below `open − 6`. The 2 leaves onset windows to sustain on rather than clipping the
start of every sentence. The band is non-empty only when separation exceeds 8 dB.

**MARGINAL** means it does not exist. You still get a number — the top of the band, `voice −
2` — with the fact that it will not work well, because a confident number that cannot
succeed sends you hunting for a bug that is really a noisy room. It also names the likely
cause:

* separation under 2 dB — almost always that **no speech was recorded at all**. Run it again
  and talk through the middle of the recording.
* otherwise — move closer to the microphone, use a headset, or quiet the room.

**FAIL** is either no audio at all — microphone access is granted to the terminal app, not
to wngmn — or too few samples to measure.

`miccheck` exits 0 on PASS and 1 otherwise, and emits `mic_ambient_db`, `mic_speech_db` and
`mic_recommended_db` as metric lines so a script can read them without parsing the prose.

---

## Jargon repair

The on-device recogniser mangles domain terms, and there is no vocabulary-biasing lever on
this path: `AnalysisContext.contextualStrings` is a proven no-op for `SpeechTranscriber`. So
correction is necessarily post-hoc. Observed, on real calls: `ARR` → "the air", `Series A` →
"series 8", `Mixstream` → "Mixedream".

Correction runs on **finalised text only**. Volatile text is never repaired — it is replaced
milliseconds later anyway, and rewriting it would make the caption flicker.

### The file

One term per line. `#` starts a comment. Fields are separated by `|`; the first field is the
canonical spelling that gets emitted, and the rest are aliases.

```
# terms.txt
Kubernetes | cuber netties | kubernets
ARR | the air | a r r
Series A | series 8 | series eight
Mixstream
```

Line endings are normalised first, because a file saved with Windows or classic-Mac endings
would otherwise parse as a single enormous term that matches nothing and quietly disables
jargon correction for the whole interview. A term wider than 6 tokens is skipped, as is an
alias wider than 6 — the scan window is capped there so a pathological file cannot make
correction quadratic in a long sentence.

Where the list comes from, in order:

* `--terms <path>`, otherwise `./terms.txt` in the working directory.
* A missing `terms.txt` is not an error; the list is simply empty. A missing `--terms` path
  **is** reported — silence there would mean correction is off for the whole interview while
  you believe your list is loaded.
* A profile's `## Terms` section **replaces** the file entirely when it is non-empty, rather
  than merging with it. An investor call and a technical one mangle different words, and the
  point of a profile is that switching domains switches everything about it, jargon
  included. The startup line tells you how many terms came from where.

### How a match is decided

Text is scanned left to right, longest window first, against a case-folded,
punctuation-free, numeral-normalised match key — which is why `Series A`, `series 8` and
`series eight` all land in the same place (number words up to twenty, the tens, and
hundred/thousand/million/billion are mapped to digits). Three rules, in order:

1. **An explicit alias always wins.** You asked for it by name.
2. **The canonical spelling matched exactly**, which fixes capitalisation — but only if its
   key is at least 6 characters.
3. **The canonical matched approximately**, again only for keys of at least 6 characters,
   and only against a window spanning the same number of tokens as the canonical. The budget
   is one edit up to 7 characters and two beyond, and any non-zero match must also share the
   first 3 characters.

**Short acronyms need explicit aliases.** Anything under 6 characters is matched only
through the alias list, and deliberately so: one edit on a three-letter acronym is a third of
the word, so a fuzzy `ARR` would swallow "are", "art" and "air" — and "are" is one of the
commonest words in an interview question. Write out what the recogniser actually hears.

**Longer names are matched approximately**, because recognition errors are not enumerable in
advance — nobody would have predicted "Mixedream". The budget is deliberately tight: three
edits on a nine-character term rewrites "mainstream" into "Mixstream", while two catches the
errors actually observed. The shared-prefix rule is what separates them, since a recognition
error preserves the onset and a real word need not: "mixedream" and "mainstream" are both
two edits from "mixstream", and only the prefix tells them apart. An error further away than
that belongs in the alias list, not behind a wider radius.

A span already spelled exactly as the canonical is left alone. A canonical you deliberately
spelled lower-case is also left alone by the sentence-capitalisation pass.

### The other jargon knob

`--no-fast-results` drops the `.fastResults` option, which Apple documents as "faster but
also less accurate". Latency now comes from `finalize(through:)` rather than from waiting on
the framework's own `isFinal`, so dropping it may cost little and improve jargon accuracy.
It is a rehearsal experiment rather than a default — measure it on a recording.

### When a term list cannot rescue it

If rehearsal shows jargon accuracy is unusable and a term list cannot rescue it, that is the
one trigger for replacing the on-device recogniser with a cloud one that has a real
vocabulary lever — Deepgram Flux's `keyterm` is the candidate that was measured. It is the
only trigger. Do not switch for latency: the two measure as a tie, so there is nothing to
win, and the switch adds a network dependency in the middle of a live call to a path that
today needs none.

---

## Profiles

A profile is one markdown file per conversation domain: what to say, how to say it, and the
words it uses. A founder pitch, an investor panel and a product demo want different substance
*and* a different shape of answer, and they mangle different jargon. Keeping all three in one
file means switching domains is switching files — no flags to remember, and nothing shared
between them that could leak from one call into the next.

```markdown
# Investor panel

## Style
Three to five bullets, each a sentence I can say as written. Never invent a figure.

## Context
Raised $12M Series A in March 2026. ARR is $4.1M, up 3.2x year on year.

## Terms
Kubernetes | cuber netties
ARR | the air | a r r
```

Only `## ` opens a section, so `###` and deeper inside one are your own structure and survive
untouched. A `# ` line before the first section is the profile's name, and is cosmetic.

* **`## Style`** — how answers should be shaped. It becomes the instruction half of the
  system prompt and is passed through verbatim, so anything you do not say here, the model
  will not do. Worth being specific about length and form, whether it is read aloud, what to
  do with gaps, and register. A profile with no `## Style` is reported at startup, because
  answers then get no shaping at all.
* **`## Context`** — the substance the answer is built from. Be generous: it is sent on every
  request but cached after the first, so length costs very little after the first ask of a
  session.
* **`## Terms`** — this domain's jargon, in exactly the format above. Non-empty, it replaces
  the global terms file.

**What the tool adds, exactly.** `## Style` opens the system turn verbatim, with nothing in
front of it. Between it and your material, `AnswerPrompt.build` inserts exactly one line:

```
Prepared material — this is the substance to draw on. Prefer it over anything else you know:
```

and that is the whole of the tool's contribution to the system turn. There is no house style
underneath it: nothing says be concise, nothing says do not make things up, nothing sets a
length. So an instruction like *never invent a figure* has to be in your `## Style`, because
nothing else supplies it. A house style invented here would be indistinguishable, in the
answer, from one you chose. (The question and the few before it go in the user turn, under
`Earlier in this interview:` and `The question to answer now:`; nothing else is sent.)

A heading that is not one of those three is reported at startup as an unknown section. It is
almost always a typo, and a silently ignored section is material you wrote that never reaches
the model.

`--profile <value>`: a bare word resolves to `profiles/<value>.md`, so switching domains is
`--profile investor`; anything containing a `/` or ending `.md` is taken as written. The file
is re-read when its modification date changes — checked when an answer is requested — so a
profile can be edited mid-session, and the moment you want to change how answers are shaped
is usually the moment you have just discovered the current shape is wrong. A read that fails
keeps the version already in memory, rather than losing your prepared material because an
editor had the file half-written.

`--notes <path>` is the context-only shorthand: the whole file becomes `## Context`, and its
own `##` headings are demoted one level so they stay structure instead of opening sections.
`profiles/TEMPLATE.md` is the shape to start from.

At startup the binary prints the profile's name, whether `## Style` is present, the size of
the context and the number of terms. Read that line — it is the cheapest confirmation that
the file you meant to load is the file that loaded.
