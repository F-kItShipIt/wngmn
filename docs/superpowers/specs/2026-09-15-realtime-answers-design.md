# Real-time answers, a shared ledger, and end-of-call notes

Design spec. Status: **awaiting review** (no code written). Author brainstorm: 2026-09-15.

## Goal

While a call runs, answer the caller's questions as they land — without the user
pressing **Ask** on each one — batching a caller turn at a time, remembering every
answer as context for the next, and writing meeting notes when the call ends.

## Current state (grounded in the tree)

- **Answers are stateless.** `WngmnAsk/AnswerPrompt.swift` rebuilds a one-shot prompt
  per question: the question, the last 6 transcript lines (`recentLimit = 6`), and the
  profile. `WngmnAsk/ClaudeClient.swift` sends one request with the profile under
  `cache_control`. No memory survives between questions.
- **Answers are triggered from the page.** A `POST /ask` (`TranscriptServer.swift:414`)
  starts an answer; the answer streams back over `/events` to *every* open page as
  `answer` / `answer_done` / `answer_failed` frames (handled in `Page.swift:1583`).
  Answers deliberately never reach `EventWriter`, so stdout stays a pure transcript.
- **The server already dedupes answers** by a question key (`asks: [String: AskRecord]`
  in `TranscriptServer`): one answer per key, a revision cancels the in-flight one.
- **`prefetch`** (page toggle, `Page.swift:389`) is the closest existing thing: with it
  on, the page `POST /ask`s each question as it lands. It is per-question, page-driven,
  and stateless — exactly what this feature generalises.
- **Capture controls** (`WngmnCore/CaptureControl.swift`: `mic`, `tap` flags) round-trip
  through `POST /control` → `controlHandler` (`Wngmn.swift:320`). Toggles on the page
  (`controlState`, `setControl`, `parseControlDetail` in `Page.swift`) follow this path.
- **No "call ended" signal exists** — only process exit and a `status: stopped` frame
  (`Pipeline.swift:213`).
- **Events**: `WngmnCore/Events.swift` defines `status`, `question`, `partial`,
  `warning`, `metric`, `error`. Answer/summary frames are server-only (over `/events`,
  not the Event enum), which is how they stay off stdout.

## Locked decisions (from the brainstorm)

| Decision | Choice |
|---|---|
| Timing | Answer a beat after the caller stops (turn-end trigger; no speculative revise) |
| Consent | A page toggle, **off by default** — same posture as `prefetch`/`sync` |
| Trigger | Every caller **turn**; the model answers or replies `NONE` |
| Ledger | The Messages-API conversation itself is the ledger |
| Call ended | `Ctrl-C`/quit summarises (best-effort); **and** on a long silence the page asks "Has the conversation ended? Yes/No" → summarise only on **Yes** |
| Auto-answers UI | Stream into the **existing answer panel**, like a manual Ask |
| Cost | A small counter on the panel (answers given / calls made) |
| Scope | Build **both** real-time answers and end-of-call notes |

## Architecture

Batch by **caller turn**, not by fixed time windows. A turn is consecutive `Caller`
questions until either a `You` question arrives or the caller is silent past a turn gap.
The endpointer's per-utterance `question` events plus their `speaker` label already give
the raw material; grouping them into a turn is the one genuinely new bit of live logic.

The "meaningful context that needs an answer?" decision is **an instruction inside the
answer call**, not a second model pass: send the turn, tell Claude to answer if there is
something worth answering, else reply `NONE`. One call per turn; `NONE` turns are cheap
and still recorded as context.

The **ledger is the conversation**: one Messages-API conversation per call. Each closed
turn becomes a user message; each answer is Claude's reply; the profile is the cached
system prefix. Past answers are context for free (they are prior messages), and prompt
caching keeps the growing prefix nearly free (~10–15k tokens for a 45-minute call).

### Components

1. **`TurnBatcher`** (new; `WngmnCore`, pure and unit-testable). Consumes caller
   `question` events. Closes the current turn when a `You` question arrives, or when
   `turnGapSeconds` (default ~2.5 s, tunable) pass with no new caller question. Emits a
   `Turn { text, t0, t1 }`. Pure time-in/events-in, turns-out so it can be tested without
   a socket, the way `QuestionAssembler` is.

2. **`CallConversation`** (new; `WngmnAsk`). Owns the Messages-API conversation for the
   call. `answer(turn:) -> AnswerOutcome` appends the turn as a user message on top of the
   cached profile + prior turns/answers, calls Claude (streaming), and returns either the
   streamed answer or `.none` when the reply is `NONE`. `summarise() -> String` appends one
   final high-effort message. Holds the message array; caches the growing prefix.

3. **Auto toggle** (extend `CaptureControl` with `auto`, default off; wire `POST /control`
   and a page checkbox next to `prefetch`/`sync`). When on, the server feeds closed turns
   to `CallConversation` and emits the answer over the existing `answer` frame path (or
   nothing on `NONE`). Off by default; a manual **Ask** keeps working in both states.

4. **Summary trigger**. Three ways in, one path out (`CallConversation.summarise()` →
   `summary` / `summary_done` frames → page notes view):
   - Page **silence prompt**: after `callGapSeconds` (default ~20 s, tunable) with no new
     question, the page shows "Has the conversation ended? Yes/No". Yes → `POST /summarise`.
     No → dismiss and back off so it does not nag.
   - Explicit **End & summarise** control on the page (also useful to get notes without
     quitting).
   - **Clean shutdown** (`Ctrl-C` / `wngmn stop`): best-effort summary with a short timeout
     before teardown, printed to stdout; skipped if the call had no content.

5. **Cost counter** (page-side). Counts `answer`/`summary` frames it receives and shows
   "N answers · M calls" on the stats panel (near the existing latency panel). Not a hard
   budget; an optional cap is a later addition.

### Data flow

```
caller question events ─▶ TurnBatcher ─(turn on gap / you-speaks)─▶ [auto on?]
   ─yes─▶ CallConversation.answer(turn)
             ├─ answer ─▶ answer frame ─▶ every page's answer panel
             └─ NONE   ─▶ nothing shown; turn kept in the conversation as context
   long silence ─▶ page asks "ended?" ─Yes─▶ /summarise ─▶ CallConversation.summarise()
                                                              └─▶ summary frame ─▶ notes view
Ctrl-C / stop ─▶ best-effort summarise ─▶ stdout + summary frame
```

## Prompt design

- **Per-turn answer.** System = the cached profile (unchanged shape). The turn is the new
  user message. The instruction: *answer the caller's most recent question or request from
  the profile; if the turn contains nothing that calls for an answer, reply exactly
  `NONE`.* Reuse `AnswerPrompt`'s style/context assembly; the change is that the message
  list carries the whole call rather than 6 recent lines.
- **Summary.** One final user message: *summarise this call as meeting notes — decisions,
  questions asked and how they were answered, open items.* High effort is fine (no live
  deadline). Runs against the same conversation, so it sees everything.

## Privacy

Auto-answer sends the caller's words continuously — the same property as `prefetch`, and
a real change to the trust story. Therefore:

- Off by default; a per-call page toggle turns it on.
- `README.md` Privacy section must name auto-answer in "the complete list of things that
  leave your Mac", next to the existing `prefetch` line.
- `WngmnCore/Options.swift` help gains a line describing auto and its default.

## Error handling & failure modes

- **Answering the wrong half** (a real mid-question pause longer than the turn gap). The
  turn gap plus the endpointer's merge window absorb hesitations; the gap is tunable, and
  can run longer when auto is on.
- **Cost surprise.** Every turn is a call. `NONE` turns are cheap and cached; the counter
  keeps spend visible; an optional cap is deferred.
- **Answer failures.** Reuse the existing `answer_failed` path; a failed turn is forgotten
  so a later turn or a manual Ask retries cleanly (matches today's `asks` behaviour).
- **Summary during shutdown.** Bounded by a timeout; if it cannot finish, teardown
  proceeds and the notes are simply not produced (never blocks exit indefinitely).
- **Latency creep** as the conversation grows. Caching covers the prefix; if a call ever
  runs long enough to matter, the curated-summary ledger (rejected for now) becomes the
  migration.

## Testing strategy (TDD)

- `TurnBatcher`: pure unit tests — grouping across a gap, closing on a `You` question,
  a single-utterance turn, a hesitation shorter than the gap staying one turn. Mirrors
  `QuestionAssemblerTests`.
- `CallConversation`: the message array grows correctly across turns; a `NONE` reply
  yields `.none` and still appends the turn; the summary call sees the whole conversation.
  Claude itself is stubbed at the `ClaudeClient` boundary.
- Page: the `auto` toggle round-trips through `/control`; an `answer` frame from an
  auto-answer renders in the answer panel; the silence prompt appears after
  `callGapSeconds` and `POST /summarise` on Yes; the counter increments. Node-driven, as in
  `PageTests`.
- Server: `/summarise` route; auto feeds turns once (dedup holds); a `summary` frame
  reaches every page.

## Phasing

Build both, in this order so each ships behind green tests:

1. **Turn batching + auto-answer + conversation ledger** — `TurnBatcher`,
   `CallConversation`, the `auto` toggle, answers into the panel, the counter, privacy.
2. **End-of-call notes** — `summarise()`, the silence prompt, `/summarise`, the notes
   view, best-effort summary on shutdown. Small, because it is one more pass over the
   conversation phase 1 already maintains.

## Open / deferred

- Exact home of `TurnBatcher` (WngmnCore vs the serve layer) — settle in the plan.
- `turnGapSeconds`, `callGapSeconds` defaults — settle in rehearsal, as the endpointer
  thresholds were.
- Hard budget cap — deferred until the counter shows it is wanted.
- Curated-summary and on-disk ledgers — rejected for now; documented as the migration if a
  multi-hour call ever needs bounded context.
