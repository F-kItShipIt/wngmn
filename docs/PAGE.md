# The page

[wngmn](../README.md) · [Usage](USAGE.md) · [Architecture](ARCHITECTURE.md) · [Permissions](PERMISSIONS.md) · [Tuning](TUNING.md) · [Security](../SECURITY.md) · [Contributing](../CONTRIBUTING.md)

`--serve` puts the event stream on a page at `http://127.0.0.1:7373`. That page is what you
look at for the whole interview — the transcript, the answer you are about to read aloud,
and the latency the whole tool exists to keep under control. This document is how to drive
it. The code is `Sources/WngmnServe/Page.swift`, embedded in the binary as one string; the
server that feeds it is `TranscriptServer.swift`.

The page loads nothing from the internet. No CDN, no font, no analytics: it is served from a
socket with nothing behind it, so an external reference would simply fail. Everything below
that looks like a library — the markdown renderer, the syntax highlighting, the chart — is
hand-rolled for that reason, and each piece is pinned by the page's own test suites in
`Tests/WngmnServeTests/PageTests.swift`.

---

## Opening it

`--serve` prints the URL to stderr:

```
wngmn: live transcript → http://127.0.0.1:7373/
```

On loopback there is no token, because the OS is already the boundary: only processes on
this machine can reach the port.

`--listen` binds the network instead, so a phone or an iPad can read the transcript, and
then there is a token in the printed URL:

```
wngmn: live transcript → http://192.168.1.24:7373/?t=k7pm4rqh
wngmn:                    → http://studio.local:7373/?t=k7pm4rqh   (same page, stable name)
```

The token is the only thing protecting the transcript once the port is on the wifi, and the
transcript carries the other person's words as well as yours. It is eight characters from a
31-symbol alphabet with no `0`/`O` or `1`/`l`/`I` in it — a little under 40 bits, which is
thousands of years of guessing against an unthrottled server on your own network, and short
enough to type into a phone at the start of a call. It is stored, so the URL is the same
every run and can be bookmarked; `--new-token` replaces it and invalidates every bookmark.
`--token <value>` sets a fixed one instead, and implies `--listen`.

Write down the `.local` URL rather than the address one. The address is handed out by
whichever router you are on and goes stale when you change networks; the Bonjour name does
not.

The token has to stay in the address bar. Every request the page makes — `/events`, `/ask`,
`/control` — appends `window.location.search`, and `/` itself is gated the same way, so a
bookmark trimmed back to the bare address is a 403 before the page is ever served.

---

## The wide layout

Above 820 px the page is a fixed frame whose panes scroll inside it. The document itself
never scrolls; on iOS Safari it did, and it took the header — and on a phone the tab bar,
which is the only way to switch panes — off the top with it.

* **The answer stage**, on the left, 65% of the width by default. It leads because the
  answer is the thing being read under time pressure — the transcript is navigation for it.
  One question is on the stage at a time, so an answer arriving for some other row cannot
  replace what is under your eyes mid-sentence.
* **The divider**, a 7 px gutter between the two. Drag it; the hit area is wider than it
  looks. It clamps between 30% and 80% — one overshoot used to collapse a pane to zero with
  no gutter left wide enough to drag back. Double-click resets it to 65%, the arrow keys
  move it 2% per press when it has focus, and the position is remembered per browser in
  `localStorage` under `wngmn.split`.
* **The transcript column**, on the right: the question rows, newest at the bottom.
* **The side panel**, above the transcript in that same column, holding the latency chart,
  the warnings list, and the raw event log behind a disclosure. `\` hides it, or the
  **panel** button in the header; the choice is remembered as `wngmn.aside`. Hidden, the
  transcript takes the whole column, which is worth having because answers are documents —
  tables and code blocks read badly in a column two thirds of a screen wide.
* **The live caption**, a strip along the bottom of the transcript column.

The header carries a connection pill with a coloured dot, the capture format, the question
count, the capture controls, the **sync** and **prefetch** toggles, the panel button, and a
clock showing the stream position of the last event.

### The side panel, in detail

The **warnings** list is newest first, each entry the warning's code, its detail, and the
stream time it arrived at; it keeps the last 40. Two warnings are also a change of state and
move the header pill: `rebuild_failed` turns it to a red "capture down", `rebuilding` to
"rebuilding…". A failed rebuild is only a warning because the process keeps going and
retries, but until the retry lands there is no capture graph, and a pill still reading
"capturing" over that is exactly the failure the watchdog exists to make visible. The next
`capturing` status restores it.

**Raw events** is the last 200 JSON Lines, newest first, behind a disclosure triangle so it
costs nothing when closed. They are the same lines going to stdout — it is there for when
the rendered view and the stream disagree.

---

## On a phone

At 820 px and below there is no room to split, so the answer and the transcript take turns
behind two tabs and the tab bar says which is up. Splitting was tried: the answer — the
thing the phone is open for — ended up with 41% of the height, below a diagnostics panel
taking 42%.

The side panel is dropped entirely at this width. The chart, the warnings and the raw log
debug capture on the machine doing the capturing, and a phone can act on none of it.

What tabs would otherwise cost is the live caption, which is the one thing on the page with
a deadline — it shows a question forming before there is a row for it. So the caption sits
outside both tabs and survives the switch, with an **Ask** button beside it pointed at the
newest question. That button reads **View** rather than Ask once the question has an
answer: pressing it then only brings the answer back to the stage, and calling it Ask would
promise a second opinion it is not going to deliver.

The Transcript tab carries a badge counting questions that arrived while it was hidden.
"Seen" means looked at, not asked and not elapsed, so only opening the transcript clears it.

Asking on a phone switches you to the Answer tab — otherwise the tap that asked leaves you
watching the transcript while the answer streams out of sight. On a wide screen both panes
are already up and nothing switches.

Rotating the phone crosses the breakpoint live, and the caption button and tabs re-render
rather than being left on a layout that has no place for them.

---

## The live caption

One line, at the bottom of the transcript column on a wide screen and under both tabs on a
phone.

* While someone is speaking it shows the partial text as it arrives, with a blinking cursor
  after it.
* When nothing is being said it shows the last finished line, in full-strength ink. It used
  to blank at every endpoint, which on a phone left an Ask button beside an empty line with
  no clue what it would ask.
* Before anything has been said at all it is just the cursor.

---

## A question row

```
04:12   So tell me a bit about the funding round you just closed.
Caller  [74 ms] [⚠ volatile — wording less reliable]  [Ask]
```

**The timestamp** is `t0`, the start of the speech, as mm:ss of stream time. It is stable
across revisions — all the lines of a question that was revised carry the same one — which
is also what identifies the row across devices, as `speaker@t0`.

**The speaker label** sits under the timestamp rather than in a column of its own, so a
single-source transcript looks exactly as it did before the microphone existed. It appears
unless `--no-mic` was passed: `speaker` is carried on the wire only when more than one source
is being captured. Your own lines are tinted and labelled **You**, the other side **Caller**.

**The latency tag** is that question's `ms` — the measured endpoint-to-final latency, the
same number in the JSON. It turns red when the question is over budget, which is not `ms`
alone: see [the latency chart](#the-latency-chart) below. Your own lines never turn red.

**The volatile tag** means the wording came from the volatile stream rather than the settled
one, and is less trustworthy than usual. The words are worth reading; do not read them back
verbatim without a glance.

**Ask** is described next. Once a question has been answered its Ask button is spent and
goes flat, and a dot appears under the timestamp. Clicking anywhere on such a row brings its
answer back to the stage rather than spending another call — which is why the row click and
the Ask button are deliberately different actions. One stray click on the transcript would
otherwise cost an API call on a line you were only glancing at.

The row currently on the stage is tinted, as is the row selected with `j`/`k`.

### A screenshot row

The one row that did not come from the recogniser. `wngmn shot` makes it: the gutter says
**Screen**, the text is what was taken and how big — `Screenshot · region · 1500×900` — and
there is no latency tag and no Ask button, because it has no latency and it is already asked.
The keypress was the Ask.

That is literal. The row is born asked, with no answer, which is the only way this page says
"Asking…" — it has no pending state of its own — and it is what keeps `Enter` on the selected
line, the phone caption's button and the stage's own Ask from posting the row's *label* to
`/ask` as though somebody had said it. A manual Ask does not see the picture, so the label is
also left out of the six lines a later Ask sends as context.

It takes the stage the moment it arrives, whatever was there. The shutter is silenced, so that
is the only sign the key did anything. A replayed frame finds the row already present and
leaves it, and the stage, alone. Its answer then follows the ordinary rule: you have not been
moved off it, so it lands under your eyes; if you have clicked away, it waits for you.

Every shot row ends, one way or another. An answer; a failure with its reason — *Screen
Recording is not granted*, *HTTP 413* — shown on the stage, not only in the side panel, which
a phone does not have; or, for a shot overtaken by a newer one before it was answered,
*Answered with the screenshot after this one*. The picture is still in the conversation that
later answer was written from.

Screenshot rows are not questions: they are left out of the header's count, the latency chart
and its tiles, **prefetch**, and the search for a row to revise.

---

## Ask, and prefetch

**Ask** puts the question on the stage and posts it to `/ask` with the last six questions
before it as context — only the ones before it, since a later question is not context for
this one. The request returns `202` at once and is only a trigger: the answer streams back
over `/events` to **every** open page, including the one that asked. That is what makes a
phone and a laptop show the same thing — they are not two implementations kept in step, they
are the same one.

The answer is never written to stdout. The JSON Lines stream stays a transcript rather than
a notepad.

One answer per question, enforced on the server as well as in the page: two devices with
prefetch on both ask the instant a question lands, and a page's own "already asked" latch
cannot close until the first token comes back. A second ask with the same text is accepted
and ignored. A question that was *revised* is a different question, so its half's answer is
cancelled and everything that answer still emits is dropped, rather than interleaving token
by token with the real one.

Your own lines are askable too — for elaborating on something you just said, or for a better
way to have said it.

**Prefetch** warms an answer for each question as it lands, so pressing Ask is instant. It
is off by default because it is one API call per question and most questions in an interview
never need one. It skips your own lines: warming an answer for every "mm-hm" is not what the
toggle is offering.

Neither toggle is remembered across a reload. The split position and the panel's visibility
are kept per browser; **sync** and **prefetch** start off every time.

While an answer is on its way the stage says "Asking…". A failure renders in red on the
stage rather than disappearing. An answer that stopped at the token cap carries a warning
strip under it — a half-written sentence is about to be read aloud, and the reader has to be
able to see that it does not end.

---

## Auto, and the end-of-call notes

**Auto** answers without anyone pressing anything. The endpointing that draws the transcript
already knows when a turn is over, so the answer is drafted while the other person is still
waiting for yours, and lands on the stage over the same `answer_done` frame a pressed Ask
uses. There is no second code path and no new surface — a page that has auto on and a page
that does not are rendering the same frames.

It is not a property of your browser, and this is where it differs from the two toggles
above. **sync** and **prefetch** are per-page and start off on every reload; auto is posted
to `/control` and held on the server next to the mic and tap state, so ticking it on the
phone ticks it on the laptop, and both are told so in the same `control` line. It still
starts **on** with every run, unless wngmn was started with `--no-auto` or found no
credentials to answer with — so what is heard is sent as each turn ends, from the first turn,
and wngmn says so at startup. Unticking it stops that at once, held turns included.

**A turn, not a line.** Answering each endpoint separately would answer half-questions, so
the batcher holds one speaker's lines open until the turn ends — the other speaker starts, or
2.5 s of silence passes — and hands over the whole thing at once. Two questions 1.2 s apart
are one turn and one call.

**One request at a time.** While an answer is on its way, turns that close are held, in
order, and go out together when it lands — so the model answers the conversation as it stands
rather than working through a backlog. The one answer is attached to the last of those turns;
the earlier ones are context and get none of their own, which is why a row in the middle of a
fast exchange can stay unanswered while the counter shows a single call.

**A screenshot cuts in.** It is the one thing that does not wait: it cancels the answer that
is out — usually an answer to "let me paste this here" — and goes at once, with whatever was
held behind it. The cancelled turn stays in the conversation as context, with no reply of its
own. It is also the one thing the toggle does not govern: auto decides what happens to speech
that was overheard, and a keypress is asking. With auto off a shot is answered, alone, and
the counter appears, because a call was made. And it stays: the picture is in the
conversation until wngmn exits, so "can you do that in place?", said aloud a minute later
with auto on, has its "that".

Not without limit. Every picture kept is sent again with every turn, and a request may be
32 MB, so the conversation keeps pictures under 24 MB encoded — a few whole-screen shots, or
dozens of dragged regions — and under twenty in number, past which the API holds every image
in a request to 2000 px. The oldest go first, five at a time at the count, because each
eviction rewrites a message near the start of the conversation and so discards the cached
prefix. A picture that goes keeps its place and its answer; its message says it is no longer
attached.

**Your own turns go too**, above a floor of four words. `--auto-own-min-words` moves the
floor and `0` removes it; the caller is never held to it, because a one-word question from
them is still a question. A shape rule was tried here first — a question mark, or an opening
interrogative — and removed: the recogniser clips exactly the words it read, so `Can you
write a program to…` arrives as `To, a program to…` and the turns most worth answering were
the likeliest to be refused. Length survives that clipping, and the model, which sees the
whole conversation, decides the rest by replying `NONE`.

A `NONE` renders nothing. The call was still made, so it is still counted, and the counter on
the panel — `auto: 1 answered · 1 call` — exists to make that visible rather than letting it
accumulate quietly.

**The notes** are one pass over the whole conversation, from **end & summarise**, or from the
prompt that appears after 20 s of quiet. That prompt waits until something has been sent: the
ledger is built from what auto answered and from screenshots, so a call with neither has
nothing to summarise, and it says so rather than summarising nothing. **No** snoozes it until the next
question resets the clock.

The notes card's **copy** button puts the markdown on the clipboard, not the rendered markup
— the same choice the code blocks make, and the form that survives a paste into a doc or a
ticket. It is hidden while the summary is still being written and when one has failed, since
neither has anything worth copying.

---

## How an answer renders

Answers arrive as markdown and are rendered by hand, block by block, because the page loads
nothing from the internet. It is deliberately not a CommonMark implementation: every feature
is one carried and kept correct here.

* Headings, shifted down two levels and clamped — a model's `##` is a sub-heading in a side
  panel, not a document title — and styled distinctly, because an answer of any length is
  navigated by scanning its headings.
* Bullet and numbered lists, nesting by indent, with the source's own numbering preserved.
  Both matter for reading aloud rather than for looks: a reopened `<ol>` has the browser
  counting from 1 again, so a step the answer calls 3 is announced as 1.
* Tables, which need both a pipe row and a separator under it — prose contains pipes often
  enough ("run | grep to filter") that a pipe alone must never restructure a line. Ragged
  rows are squared to the header rather than adding a column to the whole table.
* Thematic breaks, inline bold, italic and code spans.
* Fenced code, with the language on a caption bar and a **copy** button that puts the source
  on the clipboard rather than the escaped markup.

Escaping runs before any tag is inserted. The answer is model output going straight into
`innerHTML`, so that ordering is the whole XSS boundary rather than a style preference.

The renderer runs on every streaming delta, which is why an unclosed fence renders as a code
block while it is still arriving, and a table grows rows as they come. Code blocks and
tables scroll inside their own box: the transcript column must never scroll sideways,
because you are reading it aloud and cannot go hunting for the rest of a sentence.

Syntax highlighting is one regex per language, alternating comment, string, number, keyword
and call, matched in that order. The order is the design: a comment or a string is consumed
whole, so a keyword inside one is never painted as a keyword. Naive word replacement gets
that wrong and corrupts the code on screen, which is worse than no colour at all. A dozen
languages are covered, with the aliases a model actually writes on a fence (`py`, `ts`,
`sh`, `golang`, `psql`) resolving to them; anything unrecognised is escaped and left plain.

---

## The capture controls

Two buttons in the header, and they act on the capture, not on the page. Any device holding
the token can press them, and the resulting state comes back on a `control` status line so
every open page repaints.

**⏸ listening / ▶ paused** (`p`) stops transcribing the caller. Paused means the tap audio is
discarded before the endpointer or the recogniser sees it — not transcribed, not held, not
sent. The capture graph stays registered: tearing the tap's aggregate down and back up on
every toggle would risk the stall that the capture watchdog exists to recover from.

**mic on / mic muted** (`m`) stops your microphone. This one does stop the device outright,
so the system microphone indicator goes out — a microphone is an ordinary input device with
no aggregate and no rebuild path to get wrong, so restarting it is cheap in a way the tap is
not. Anything half-spoken is flushed and discarded rather than stitched across the mute. The
button only appears once a `mic` status has arrived; until then it would be a control over
nothing.

Both buttons are stated in amber when off, rather than greyed out: a control that has
stopped capturing is information, not an absence. Neither repaints until the server has
confirmed the change. A button reading "muted" while the microphone is in fact live is the
one outcome worth avoiding, so a failed request leaves the button showing the last state
actually confirmed.

`--start-paused` begins with the tap paused, so nothing is transcribed until you press the
button. The page learns this by sending an empty control request at load: it changes nothing
and returns the current state.

---

## Keyboard

| Key | |
| --- | --- |
| `j` / `k` | select the next / previous question |
| `Enter` | ask the selected question (a screenshot row is already asked, so it only comes to the stage) |
| `p` | pause or resume transcribing the caller |
| `m` | mute or unmute your microphone |
| `\` | show or hide the side panel |

`j` with nothing selected starts at the newest question, which is what you are looking at.
Selection clamps at both ends rather than wrapping: the transcript is read top to bottom
under time pressure, and silently jumping from the newest question to the oldest would lose
your place mid-call. Selecting scrolls the row into view but does not put it on the stage —
`Enter` does both.

Shortcuts are ignored while focus is in a text field or on a button, and any combination
with Cmd, Ctrl or Alt is left to the browser. `Enter` on a focused Ask button is already
native activation; handling it here as well would fire the request twice.

---

## Sync scroll

**sync** shares scroll position between the devices showing the page. It is off by default
so you can look back at an earlier question without dragging every screen with you.

Both sending and receiving are gated on the local checkbox, so it only moves devices that
also have it on. A laptop with sync on and a phone with it off is a perfectly good
arrangement: the laptop broadcasts and the phone ignores it.

What is shared is an anchor — which row is under the top of the viewport, and how far into
it — never a pixel offset. A phone and a laptop lay the same transcript out at different
heights, so `scrollTop` from one means nothing on the other; the receiver recomputes the
offset against its own geometry. Positions go out at most every 120 ms, and applying a
remote one suppresses the local handler briefly so the echo does not set two ends
oscillating. They are relayed live and never retained: a scroll position from ten minutes
ago replayed into a page opened later would yank it somewhere nobody is looking.

The transcript follows new questions only when it was already at the bottom, and not while a
remote position is being applied — otherwise a new question snatches every screen back to
the bottom the instant someone scrolls up on another device.

---

## The latency chart

This is the part worth reading carefully, because the number on the chart is not the number
on the row.

**The bars are `ms`** — the per-question endpoint-to-final latency, one bar per question,
the last 40. Caller questions only — not your own lines, and not screenshot rows, which have
no latency to plot.

**The budget is 700 ms, end to end**: the journalist's last syllable to the question being on
screen, Zoom or Meet transport included.

`ms` is not that total. It starts only *after* the hangover has been waited out, and it also
leaves out a delivery lag of about 30 ms — the buffer that ended the question arrives around
21 ms after its last frame and is drained within a 5 ms poll. So the local total behind a row
is `ms + hangover + 30`, and it is that total, not `ms`, that decides whether a row's tag and
its bar turn red. Read raw, a question at 450 ms looked comfortably inside a budget it had
in fact blown.

**The rule is drawn where `ms` would put the local total at the criterion** — 700 less the
hangover and the delivery lag. At the default 250 ms hangover that is a rule at 420 ms, and
the label says so. Change `--hangover-ms` and the number on the rule moves with it: the
server writes the hangover it is running into the page for exactly this, so the page can add
back what `ms` left out rather than guessing.

The rule only appears once the worst bar has passed half of it. The axis is scaled to the
data, not to the budget: latency runs an order of magnitude under 700 ms, so a
budget-scaled axis renders every bar as a 5 px stub and hides the drift that is the whole
reason to watch this during a 45-minute call. Until anything approaches the rule the top
gridline simply labels the scale, and the caption carries the headroom in words, which is
the more honest way to say "nowhere near the limit".

Three tiles above the chart: **median ms**, **worst ms**, and **over budget** — how many of
the plotted questions crossed the criterion, in red when it is not zero. The caption under
the chart says the worst case in full: the worst `ms`, what it becomes once that line's
hangover and delivery lag are added back, and what percentage of 700 ms that is, before Zoom
or Meet transport. Hovering a bar gives its `ms` and the first 80 characters of the question.

**Your own lines are not judged against it.** They are excluded from the chart, from the
tiles and from the over-budget count. The microphone's hangover is 800 ms by choice — over
three times the tap's, because nobody reads your own sentences back to you, so waiting costs
nothing — and that alone would put every one of them over a budget that was never about
them.

---

## When the connection drops

The pill goes to "reconnecting…" with a red dot, and the browser reconnects on its own. A
page left open through a laptop sleep, a phone whose radio dropped an idle socket, a Safari
tab that was suspended: all of them come back without being touched. A keep-alive frame goes
out on every open stream every 20 seconds, because a quiet stretch of interview is exactly
when a NAT table drops an idle connection.

On reconnecting, the browser cites the last event id it saw and the server sends only what
came after it, so a phone waking from sleep is not handed its whole transcript a second time.
A cursor the server cannot place — from a previous run of wngmn, or older than what is still
retained — falls through to the whole backlog: a page showing some history is more useful
than one showing none.

**A page opened mid-interview is caught up for the same reason.** The server retains the last
400 events and replays them to a fresh connection, so opening the page at minute 20 shows the
questions so far rather than an empty screen. Answers replay too: the streaming deltas are
deliberately never retained — an answer is hundreds of small frames and remembering them
would evict the entire question history from the buffer — but the finished answer is
broadcast once, complete, and it is that frame a late page replays.

Replay overlapping what a page already has is normal rather than exceptional; the server
cannot know how much reached a socket before it dropped. So the page collapses duplicates by
`speaker@t0`, and an identical redelivery returns before touching the row's answer or the
unseen badge. Without that, one tab suspension doubled every question in the transcript.

If wngmn itself died mid-call, `--resume` brings the same backlog back from disk, and what
the earlier run had answered is remembered with it — otherwise a page with prefetch on would
answer every restored question over again.
