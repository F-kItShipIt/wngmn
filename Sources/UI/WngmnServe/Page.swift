import Foundation

/// The transcript page, embedded in the binary.
///
/// Embedded rather than shipped as a file so the binary stays self-contained: there is no
/// asset path to resolve, nothing to install, and `swift build && wngmn --serve` works
/// from any directory. Everything the page needs is inline for the same reason — it is
/// served from a socket with no internet behind it, so a CDN reference would simply fail.
public enum Page {
    /// The placeholder `render` fills in. Kept out of the script so `html` still parses as
    /// JavaScript on its own, which is what the page's own test checks.
    static let hangoverPlaceholder = "__HANGOVER_MS__"

    /// The page with the endpointer's hangover written into it.
    ///
    /// `ms` on a question is endpoint-to-final: it starts only after the hangover has been
    /// waited out. The page charts that number against the end-to-end budget, so it has to
    /// know how long the wait was to add it back — and the wait is a command-line knob.
    /// The caller's hangover only: the budget is about the journalist's question.
    public static func render(hangoverMilliseconds: Double) -> String {
        html.replacingOccurrences(
            of: hangoverPlaceholder, with: String(Int(hangoverMilliseconds.rounded()))
        )
    }

    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>wngmn — live transcript</title>
<link rel="icon" href="data:,">
<style>
:root {
  color-scheme: light dark;
  --plane:#f9f9f7; --surface:#fcfcfb;
  --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --rule:rgba(11,11,11,0.10);
  --series:#2a78d6; --good:#0ca30c; --warn:#fab219; --crit:#d03b3b;
  --t-com:#7d7c74; --t-str:#0a7a58; --t-num:#8f5000; --t-kw:#9b2f8c; --t-fn:#2a6fc4;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --plane:#0d0d0d; --surface:#1a1a19;
    --ink:#ffffff; --ink-2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --rule:rgba(255,255,255,0.10);
    --series:#3987e5;
    --t-com:#8b8a82; --t-str:#6fce9f; --t-num:#e0a463; --t-kw:#e691d6; --t-fn:#6ab3f5;
  }
}
* { box-sizing:border-box; }
/* The page is a fixed frame with panes scrolling inside it, never a document that scrolls
   as a whole. `height:100dvh` with `overflow:hidden` expresses that but does not enforce it:
   on iOS Safari the document still scrolls, and it takes the header and the tab bar off the
   top with it — which on a phone means losing the only way to switch panes. Pinning the
   body to the viewport is the version that actually holds, and it also removes the dead
   strip that appeared at the bottom when the two heights disagreed. */
html { height:100%; overflow:hidden; overscroll-behavior:none; }
body {
  position:fixed; inset:0; overflow:hidden; overscroll-behavior:none;
  margin:0; background:var(--plane); color:var(--ink);
  font:14px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;
  display:grid; grid-template-rows:auto 1fr;
  -webkit-text-size-adjust:100%;
}
header {
  display:flex; align-items:center; gap:14px; flex-wrap:wrap;
  padding:10px 16px; background:var(--surface); border-bottom:1px solid var(--rule);
}
h1 { font-size:13px; font-weight:640; margin:0; letter-spacing:.01em; }
.pill {
  display:inline-flex; align-items:center; gap:6px; padding:2px 9px;
  border:1px solid var(--rule); border-radius:999px;
  font-size:12px; color:var(--ink-2); font-variant-numeric:tabular-nums;
}
.dot { width:7px; height:7px; border-radius:50%; background:var(--muted); flex:none; }
.dot.live { background:var(--good); }
.dot.down { background:var(--crit); }
.spacer { flex:1; }

/* Answer stage, drag handle, transcript. The stage leads because the answer is the thing
   being read under time pressure; the transcript is navigation for it. */
main {
  display:grid;
  grid-template-columns: var(--split, 65%) 7px minmax(260px, 1fr);
  grid-template-rows: minmax(0,1fr) auto;
  min-height:0;
}
#stage   { grid-column:1; grid-row:1 / span 2; }
.gutter  { grid-column:2; grid-row:1 / span 2; }
#chat    { grid-column:3; grid-row:1; }
#caption { grid-column:3; grid-row:2; }

/* ---- phone tabs ---- */
#tabs { display:none; }
#tabs button {
  font:inherit; font-size:14px; font-weight:560; padding:10px 0; min-height:44px;
  display:flex; align-items:center; justify-content:center; gap:7px;
  border:0; border-radius:8px; background:transparent; color:var(--ink-2); cursor:pointer;
}
#tabs button[aria-selected="true"] { background:var(--series); color:#fff; }
#tabs .cnt {
  font-size:11px; font-weight:600; padding:0 6px; border-radius:999px; min-width:18px;
  font-variant-numeric:tabular-nums;
  background:color-mix(in oklab, var(--series) 18%, transparent); color:var(--series);
}
#tabs button[aria-selected="true"] .cnt { background:rgba(255,255,255,0.24); color:#fff; }
/* Collapsed, the transcript takes the whole width. Worth having because the answers are
   documents — tables and code blocks read badly in a column two thirds of a screen wide. */
/* Widened well past its 7px to make it catchable, without taking layout space. */
.gutter {
  position:relative; cursor:col-resize; background:var(--rule);
  border:0; padding:0;
}
.gutter::after {
  content:""; position:absolute; inset:0 -5px; /* the real hit area */
}
.gutter:hover, .gutter.dragging { background:var(--series); }
.gutter:focus-visible { outline:2px solid var(--series); outline-offset:1px; }
/* While dragging, the pointer crosses text and iframes; without this the browser starts a
   selection and the drag ends up highlighting the transcript instead of moving the divider. */
body.resizing { user-select:none; cursor:col-resize; }

#chat { display:grid; grid-template-rows:auto 1fr; min-height:0; background:var(--surface); }
#chat.no-panel aside { display:none; }

/* Copy that only makes sense on one of the two layouts. The base state is the wide one, so
   this pair has to sit above the breakpoint block — at equal specificity the later rule
   wins, and a base rule written below it would override the phone one at every width. */
.phone-only { display:none; }

/* Too narrow to split, so the panes take turns instead of sharing. Splitting a phone
   screen leaves both halves too small to use: the answer — the thing the phone is open for
   — ended up with 41% of the height, below a diagnostics panel that took 42%. */
@media (max-width:820px) {
  body { grid-template-rows:auto auto 1fr; }
  #tabs {
    display:grid; grid-template-columns:1fr 1fr; gap:4px; padding:5px;
    background:var(--surface); border-bottom:1px solid var(--rule);
  }
  main { grid-template-columns:minmax(0,1fr); grid-template-rows:minmax(0,1fr) auto; }
  .gutter { display:none; }
  /* The latency chart, warnings and raw-event log debug capture on the machine doing the
     capturing. On a phone they cost 42% of the screen and can act on nothing. */
  aside { display:none; }
  #stage, #chat { grid-column:1; grid-row:1; }
  #caption { grid-column:1; grid-row:2; border-top:1px solid var(--rule); }
  body[data-pane="transcript"] #stage { display:none; }
  body:not([data-pane="transcript"]) #chat { display:none; }
  #stage { padding:16px 16px 24px; }
  #stageHead { margin:-16px -16px 14px; padding:13px 16px 11px; top:-16px; }
  #lines { padding:6px 0 4px; }
  .q { padding:11px 14px; gap:11px; align-items:flex-start; }
  /* A finger, not a cursor. The desktop chip is 20px tall — fine for a pointer, well under
     the 44px touch target every mobile HIG asks for. */
  .ask { min-height:44px; min-width:62px; font-size:12.5px; border-radius:8px; }
  .tags { margin-top:0; align-items:center; }
  /* The home indicator sits on top of the caption otherwise. */
  #caption { padding-bottom:calc(14px + env(safe-area-inset-bottom)); }
  /* Header controls that address a layout this width does not have, plus two readouts the
     phone already answers: the tab badge counts arrivals, and the status bar has a clock. */
  #fmt, #panel, #clock, #state, #countPill, h1, .wide-only { display:none; }
  .phone-only { display:block; }
  header { padding:8px 11px; gap:6px; }
  header .pill { font-size:11px; padding:2px 7px; }
  header .spacer { display:none; }
}
/* A flick that reaches the end of a pane must not chain to the page: on iOS that is
   pull-to-refresh, which drops the connection and empties the transcript. */
#stage, #lines, aside { overscroll-behavior:contain; }

/* ---- transcript ---- */
#stage { overflow-y:auto; min-height:0; padding:22px 26px 32px; }
#stageHead {
  position:sticky; top:-22px; z-index:1; margin:-22px -26px 18px; padding:16px 26px 13px;
  background:var(--plane); border-bottom:1px solid var(--rule);
}
#stageHead .who {
  font-size:10px; font-weight:600; letter-spacing:.07em; text-transform:uppercase;
  color:var(--muted); margin-bottom:4px;
}
#stageHead .q-text { font-size:17px; line-height:1.4; color:var(--ink-2); }
.stage-empty { color:var(--muted); max-width:46ch; padding-top:8vh; }
.stage-empty p { font-size:15px; }
.stage-empty .hint { font-size:13px; line-height:1.7; }
.stage-empty kbd {
  font:12px ui-monospace,SFMono-Regular,Menlo,monospace; padding:1px 5px;
  border:1px solid var(--rule); border-radius:4px; color:var(--ink-2);
}
#lines { overflow-y:auto; padding:18px 20px 8px; }
.q { display:flex; gap:12px; padding:9px 0; border-bottom:1px solid var(--grid); cursor:pointer; }
.q:hover { background:color-mix(in oklab, var(--ink) 4%, transparent); }
/* Already answered: clicking brings it back to the stage rather than spending another call. */
.q.answered .text { color:var(--ink); }
.q.answered .t::after {
  content:"●"; display:block; margin-top:3px; font-size:9px; color:var(--series);
}
.q.onstage { background:color-mix(in oklab, var(--series) 10%, transparent); }
.q.onstage .t { color:var(--series); }
.q:last-child { border-bottom:0; }
.t { color:var(--muted); font-size:12px; font-variant-numeric:tabular-nums; padding-top:3px; flex:none; width:46px; }
.body { min-width:0; }
.text { font-size:15px; line-height:1.45; }
.tags { display:flex; gap:6px; margin-top:5px; flex-wrap:wrap; }
.tag {
  font-size:11px; padding:1px 7px; border-radius:4px;
  border:1px solid var(--rule); color:var(--ink-2);
}
.tag.slow { border-color:var(--crit); color:var(--crit); }
.tag.vol  { border-color:var(--warn); }
.q.you { background:color-mix(in oklab, var(--ink) 3%, transparent); }
.q.you .text { color:var(--ink-2); }
.t .who {
  margin-top:3px; font-size:10px; font-weight:600; letter-spacing:.06em;
  text-transform:uppercase; color:var(--muted);
}
.q.you .t .who { color:var(--ink-2); }
.q.selected { background:color-mix(in oklab, var(--series) 8%, transparent); }
.q.selected .t { color:var(--series); }
/* A visible keyboard position. Without this the Ask button is reachable by Tab but gives
   no sign of where focus actually is, which on a custom-styled button reads as broken. */
.ask:focus-visible, .copy:focus-visible {
  outline:2px solid var(--series); outline-offset:2px;
}
.empty { color:var(--muted); padding:8px 0; }
.ask {
  font:inherit; font-size:11px; padding:1px 9px; border-radius:4px; cursor:pointer;
  border:1px solid var(--series); color:var(--series); background:transparent;
}
.ask:hover { background:color-mix(in oklab, var(--series) 12%, transparent); }
.ask[disabled] { opacity:.5; cursor:default; }
.answer {
  margin-top:9px; padding:10px 12px; border-left:2px solid var(--series);
  background:color-mix(in oklab, var(--series) 6%, transparent); border-radius:0 6px 6px 0;
}
/* On the stage the answer is the page, not an annotation on a row: no rail, no tint, and a
   measure capped in characters rather than pixels — long lines are the thing that makes
   text hard to read aloud without losing your place. */
#stageBody.answer {
  margin:0; padding:0; border-left:0; background:none; border-radius:0; max-width:78ch;
}
#stageBody.answer p, #stageBody.answer li { font-size:16px; line-height:1.62; }
#stageBody.answer h3 { font-size:21px; margin:24px 0 8px; }
#stageBody.answer h4 { font-size:17px; margin:20px 0 6px; }
#stageBody.answer h5 { font-size:12.5px; margin:16px 0 6px; }
#stageBody.answer ul, #stageBody.answer ol { padding-left:22px; }
#stageBody.answer li { margin:5px 0; }
#stageBody.answer table { font-size:14px; }
#stageBody.answer th, #stageBody.answer td { padding:6px 11px; }
#stageBody.answer .code pre code { font-size:13px; line-height:1.55; }
#stageBody.answer > :first-child { margin-top:0; }
.answer ul, .answer ol { margin:6px 0; padding-left:18px; }
.answer li { margin:3px 0; font-size:15px; line-height:1.5; }
.answer p { margin:6px 0; font-size:15px; line-height:1.5; }
.answer > :first-child { margin-top:0; }
.answer > :last-child { margin-bottom:0; }
/* Real hierarchy, not three identical labels. An answer of any length is navigated by
   scanning its headings, and a document whose h1, h2 and h3 look the same is a wall of
   text with decorations. Sized down the scale rather than up: this is a side panel being
   read under time pressure, so even the top level stays modest. */
.answer h3 {
  margin:16px 0 6px; font-size:17px; font-weight:640; line-height:1.3; color:var(--ink);
  border-bottom:1px solid var(--rule); padding-bottom:4px;
}
.answer h4 {
  margin:14px 0 5px; font-size:14.5px; font-weight:640; line-height:1.35; color:var(--ink);
}
.answer h5 {
  margin:11px 0 4px; font-size:12px; font-weight:600; letter-spacing:.05em;
  text-transform:uppercase; color:var(--ink-2);
}
.answer h6 {
  margin:10px 0 3px; font-size:11px; font-weight:600; letter-spacing:.06em;
  text-transform:uppercase; color:var(--muted);
}
.answer code {
  font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;
  background:color-mix(in oklab, var(--ink) 8%, transparent);
  padding:1px 4px; border-radius:3px;
}
.answer .code {
  margin:8px 0; border:1px solid var(--rule); border-radius:6px;
  overflow:hidden; background:var(--surface);
}
.answer .code figcaption {
  display:flex; align-items:center; justify-content:space-between; gap:8px;
  padding:3px 8px; border-bottom:1px solid var(--rule);
  background:color-mix(in oklab, var(--ink) 4%, transparent);
}
.answer .code .lang { font-size:11px; color:var(--muted); letter-spacing:.04em; }
/* #notesCopy joins the selector rather than repeating the declarations, and joins it rather
   than loosening it to a bare `.copy`: the same four lines, and the code block's specificity
   is left exactly where it was. */
.answer .code .copy, #notesCopy {
  font:inherit; font-size:11px; padding:1px 8px; border-radius:4px; cursor:pointer;
  border:1px solid var(--rule); color:var(--muted); background:transparent;
}
.answer .code .copy:hover, #notesCopy:hover { color:var(--ink); border-color:var(--series); }
/* Long lines scroll inside the block. The transcript column must never scroll sideways —
   the user is reading it aloud and cannot go hunting for the rest of a sentence. */
.answer .code pre { margin:0; padding:8px 10px; overflow-x:auto; }
.answer .code pre code { background:none; padding:0; font-size:12.5px; }
/* Highlighting is hand-rolled (see `highlight` below) — five classes is the whole palette.
   A finer-grained one would need a real parser per language, and the point here is to make
   structure scannable at a glance, not to reproduce an editor. */
.answer .t-com { color:var(--t-com); font-style:italic; }
.answer .t-str { color:var(--t-str); }
.answer .t-num { color:var(--t-num); }
.answer .t-kw  { color:var(--t-kw); font-weight:560; }
.answer .t-fn  { color:var(--t-fn); }
/* Comparison tables scroll rather than cramming into the column, for the same reason
   code blocks do: the transcript is read aloud and must not reflow into a wall. */
.answer .tablewrap { overflow-x:auto; margin:8px 0; }
.answer table { border-collapse:collapse; font-size:13px; }
.answer th, .answer td {
  border:1px solid var(--rule); padding:4px 9px; text-align:left;
  vertical-align:top; white-space:nowrap;
}
.answer th {
  background:color-mix(in oklab, var(--ink) 5%, transparent);
  font-weight:600; color:var(--ink-2);
}
.answer hr { border:0; border-top:1px solid var(--rule); margin:10px 0; }
.answer .pending { color:var(--muted); font-size:13px; }
.answer .failed { color:var(--crit); font-size:13px; }
.answer .cut {
  margin-top:8px; padding:5px 8px; border-radius:4px; font-size:12px;
  border:1px solid var(--warn); color:var(--warn);
}
.toggle { display:inline-flex; align-items:center; gap:6px; cursor:pointer; user-select:none; }
.pill.ctl { font:inherit; font-size:12px; cursor:pointer; background:transparent; color:var(--ink-2); }
.pill.ctl:hover { border-color:var(--series); color:var(--ink); }
/* Off states are stated in the accent of a warning, not greyed out: a control that has
   stopped capturing is information, not an absence. */
.pill.ctl.off { border-color:var(--warn); color:var(--warn); }
.pill.ctl:focus-visible { outline:2px solid var(--series); outline-offset:2px; }
#panel { font-variant-numeric:normal; }

#caption {
  border-top:1px solid var(--rule); background:var(--surface);
  padding:14px 20px; min-height:64px; display:flex; gap:10px; align-items:flex-start;
}
/* Phone only, and only while the newest question is unanswered — see `peekTarget`. */
#peekAsk { margin-left:auto; align-self:center; flex:none; }
#caption .arrow { color:var(--series); flex:none; padding-top:2px; }
#caption .live-text { font-size:15px; line-height:1.45; color:var(--ink-2); min-height:1.45em; }
#caption .live-text .settled { color:var(--ink); }
.cursor { display:inline-block; width:8px; height:1.05em; background:var(--series);
          vertical-align:-2px; animation:blink 1.05s step-end infinite; }
@keyframes blink { 50% { opacity:0; } }

/* ---- side panel ---- */
aside { border-bottom:1px solid var(--rule); background:var(--surface); overflow-y:auto; padding:14px 16px; max-height:42vh; }
h2 { font-size:11px; font-weight:600; letter-spacing:.07em; text-transform:uppercase;
     color:var(--muted); margin:0 0 10px; }
section + section { margin-top:22px; }
.tiles { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
.tile { border:1px solid var(--rule); border-radius:8px; padding:9px 10px; }
.tile .v { font-size:21px; line-height:1.15; }
.tile .k { font-size:11px; color:var(--muted); margin-top:2px; }
.tile .v.over { color:var(--crit); }
#chart { width:100%; height:132px; display:block; }
.cap { font-size:11px; color:var(--muted); margin-top:6px; }
#warnings { list-style:none; margin:0; padding:0; font-size:12px; }
#warnings li { padding:6px 0; border-bottom:1px solid var(--grid); color:var(--ink-2); }
#warnings li:last-child { border-bottom:0; }
#warnings code { color:var(--ink); font-size:11px; }
#raw {
  font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; color:var(--ink-2);
  max-height:190px; overflow:auto; white-space:pre-wrap; word-break:break-all;
  border:1px solid var(--rule); border-radius:8px; padding:9px;
}
summary { cursor:pointer; }
  /* ---- end-of-call notes ---- */
  #endprompt { position:fixed; left:50%; bottom:calc(18px + env(safe-area-inset-bottom));
    transform:translateX(-50%); background:var(--surface); border:1px solid var(--rule);
    border-radius:12px; padding:10px 14px; display:none; gap:10px; align-items:center;
    z-index:40; box-shadow:0 8px 30px rgba(0,0,0,0.28); font-size:14px; }
  #endprompt.show { display:flex; }
  #endprompt button { border:0; border-radius:8px; padding:5px 12px; cursor:pointer; font:inherit; }
  #endprompt .yes { background:var(--series); color:#fff; }
  #endprompt .no { background:transparent; color:var(--ink-2); }
  #notes { position:fixed; inset:0; background:rgba(0,0,0,0.45); display:none;
    place-items:center; z-index:50; padding:24px; }
  #notes.show { display:grid; }
  #notesCard { background:var(--surface); border:1px solid var(--rule); border-radius:14px;
    max-width:640px; width:100%; max-height:82vh; overflow:auto; padding:20px 22px; }
  #notesCard h2 { margin:0 0 12px; font-size:16px; }
  #notesClose { float:right; border:0; background:transparent; color:var(--ink-2);
    font-size:20px; line-height:1; cursor:pointer; }
  /* Floated after the close button, so it lands to its left; nudged down to sit on the
     heading's baseline rather than the taller ×. */
  #notesCopy { float:right; margin:3px 10px 0 0; }
  #notesBody .pending { color:var(--muted); }
  #notesBody .failed { color:var(--crit); }
</style>
</head>
<body data-hangover-ms="__HANGOVER_MS__">
<header>
  <h1>wngmn</h1>
  <span class="pill"><span class="dot" id="dot"></span><span id="state">connecting…</span></span>
  <span class="pill" id="fmt">—</span>
  <span class="spacer"></span>
  <span class="pill" id="countPill"><span id="count">0</span> questions</span>
  <button class="pill ctl" id="tapctl" type="button"
          title="Stop transcribing the caller (p). Audio is discarded before it is read — not transcribed, not held, not sent.">⏸ listening</button>
  <button class="pill ctl" id="micctl" type="button" hidden
          title="Stop capturing your microphone (m). The input device is stopped, so the system microphone indicator goes out.">mic on</button>
  <label class="pill toggle" title="Scroll the other devices showing this page to wherever you scroll. Off by default so you can look back at an earlier question without dragging every screen with you.">
    <input type="checkbox" id="syncscroll"> sync
  </label>
  <label class="pill toggle" title="Start answering each question as it lands, so pressing Ask is instant. Costs an API call per question.">
    <input type="checkbox" id="prefetch"> prefetch
  </label>
  <label class="pill toggle" title="Answer each turn automatically as the call runs, building on every earlier answer. On from the start unless wngmn was run with --no-auto; sends what is heard to Claude as each turn ends, and costs an API call per turn. Untick to stop.">
    <input type="checkbox" id="autoanswer"> auto
  </label>
  <button class="pill ctl" id="endbtn" type="button"
          title="Write meeting notes from the whole call so far: what auto answered, and any screenshots.">▸ notes</button>
  <button class="pill ctl" id="panel" type="button"
          title="Hide the latency and warnings panel (\\) so the transcript gets the full width.">▸ panel</button>
  <span class="pill" id="clock">00:00</span>
</header>

<!-- Phone only. Above the breakpoint both panes are on screen and there is nothing to
     switch between, so this is display:none there rather than merely unused. -->
<nav id="tabs" role="tablist" aria-label="Pane">
  <button id="tabAnswer" type="button" role="tab" aria-selected="true" aria-controls="stage">Answer</button>
  <button id="tabTranscript" type="button" role="tab" aria-selected="false" aria-controls="chat">
    Transcript <span class="cnt" id="unseen" hidden>0</span>
  </button>
</nav>

<main>
  <section id="stage">
    <div id="stageHead" hidden></div>
    <div id="stageBody" class="answer">
      <div class="stage-empty">
        <p>Answers appear here.</p>
        <p class="hint wide-only">Press <strong>Ask</strong> on any line in the transcript, or select one
        with <kbd>j</kbd>/<kbd>k</kbd> and press <kbd>Enter</kbd>. Drag the divider to resize.</p>
        <p class="hint phone-only">Press <strong>Ask</strong> next to the live line at the bottom,
        or open <strong>Transcript</strong> and pick any line.</p>
      </div>
    </div>
  </section>

  <div class="gutter" id="gutter" role="separator" aria-orientation="vertical"
       aria-label="Resize the answer pane" tabindex="0"></div>

  <div id="chat">
    <aside>
      <section>
        <h2>Latency</h2>
        <div class="tiles">
          <div class="tile"><div class="v" id="med">—</div><div class="k">median ms</div></div>
          <div class="tile"><div class="v" id="worst">—</div><div class="k">worst ms</div></div>
          <div class="tile"><div class="v" id="over">0</div><div class="k">over budget</div></div>
        </div>
        <svg id="chart" role="img" aria-label="Endpoint-to-final latency per question"></svg>
        <div class="cap" id="chartCap">Endpoint&nbsp;→&nbsp;final per question.</div>
        <div class="cap" id="autoStat" hidden></div>
      </section>

      <section>
        <h2>Warnings</h2>
        <ul id="warnings"><li class="empty">None.</li></ul>
      </section>

      <section>
        <details>
          <summary><h2 style="display:inline">Raw events</h2></summary>
          <div id="raw"></div>
        </details>
      </section>
    </aside>

    <div id="lines"><div class="empty">Waiting for the first question…</div></div>
  </div>

  <div id="caption">
    <span class="arrow">▸</span>
    <div class="live-text" id="live"><span class="cursor"></span></div>
    <button class="ask" id="peekAsk" type="button" hidden>Ask</button>
  </div>
</main>

<!-- Before the script, not after: it wires these up as it runs, and a null lookup throws
     before connect(), so the page would never open its event stream. -->
<div id="endprompt" role="dialog" aria-live="polite">
  <span>Has the conversation ended?</span>
  <button class="yes" id="endYes" type="button">Yes, write notes</button>
  <button class="no" id="endNo" type="button">No</button>
</div>
<div id="notes" role="dialog" aria-modal="true" aria-label="Meeting notes">
  <div id="notesCard">
    <button id="notesClose" type="button" aria-label="Close">×</button>
    <button id="notesCopy" type="button" hidden>copy</button>
    <h2>Meeting notes</h2>
    <div id="notesBody"></div>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
const lines = $("lines"), live = $("live");
const questions = [];   // {text, t0, ms, volatile, el}
let streamT = 0;

const mmss = s => {
  s = Math.max(0, Math.floor(s));
  return String(Math.floor(s/60)).padStart(2,"0") + ":" + String(s%60).padStart(2,"0");
};
const esc = s => s.replace(/[&<>"']/g, c =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

// The end-to-end criterion: the journalist's last syllable to a question on screen,
// Zoom/Meet transport included.
const BUDGET = 700;
// What `ms` leaves out before transport, besides the hangover: the buffer that ended the
// question is delivered ~21 ms after its last frame and drained within a 5 ms poll.
const DELIVERY_LAG_MS = 30;

// The endpointer's hangover, written into the page by the server. `ms` is endpoint-to-final
// and starts only after that wait, so it has to be added back before `ms` says anything
// about the budget — a question at 450 ms read as comfortably inside a budget it had blown.
function hangoverMs() {
  const v = parseInt(document.body.dataset.hangoverMs, 10);
  return Number.isFinite(v) ? v : 250;
}
// The local total behind one line's `ms`: what it cost before Zoom/Meet transport.
function localLatency(q) { return q.ms + hangoverMs() + DELIVERY_LAG_MS; }
// The budget is the journalist's question to the screen. Your own lines are never judged
// against it: their hangover is over three times longer by choice, because nobody reads
// them back, and it alone would put every one of them over.
function overBudget(q) { return !isYou(q) && localLatency(q) > BUDGET; }

// Your own lines are askable too — for elaborating on something you just said, or for a
// better way to have said it. Prefetch still skips them: warming an answer for every
// "mm-hm" would spend an API call on each, which is not what the toggle is offering.
function isYou(q) { return q.speaker === "you"; }

// Identifies a question across devices. `t0` is the start of the speech and is stable
// across revisions — all three lines of a revised question carry the same one — and the
// speaker separates the two sources. No schema change needed: both are already on the wire.
//
// A screenshot's row keeps the key its frame carried rather than rebuilding one. The frame
// already spells it, and a second spelling of one number is how an answer once failed to
// find its row.
function questionKey(q) { return q.key || ((q.speaker || "caller") + "@" + q.t0); }

// A screenshot: the one row that did not come from the recogniser. It has no latency, no
// speaker who is the caller or you, and it is never asked from here — it was asked by the
// keypress that took it.
function isShot(q) { return q.kind === "shot"; }

function speakerLabel(q) {
  return isShot(q) ? "Screen" : q.speaker === "you" ? "You" : "Caller";
}

function questionNode(q) {
  const el = document.createElement("div");
  el.className = "q" + (isYou(q) ? " you" : "");
  const tags = [];
  if (!isShot(q)) {
    tags.push(`<span class="tag${overBudget(q) ? " slow" : ""}">${q.ms} ms</span>`);
    if (q.volatile) tags.push('<span class="tag vol">⚠ volatile — wording less reliable</span>');
    tags.push('<button class="ask">Ask</button>');
  }
  // The gutter already carries the timestamp; the speaker rides with it rather than adding
  // another column, so a one-source transcript looks exactly as it did.
  const who = q.speaker ? `<div class="who">${esc(speakerLabel(q))}</div>` : "";
  el.innerHTML =
    `<div class="t">${mmss(q.t0)}${who}</div>` +
    `<div class="body"><div class="text">${esc(q.text)}</div>` +
    `<div class="tags">${tags.join("")}</div></div>`;
  // The whole row activates it. Once answered the Ask button is spent, and without this
  // there would be no way back to an answer you had scrolled away from.
  el.addEventListener("click", () => activate(q));
  const button = el.querySelector(".ask");
  if (button) button.addEventListener("click", ev => { ev.stopPropagation(); ask(q); });
  return el;
}

// `revises` supersedes the most recent question FROM THE SAME SPEAKER. Pure, so the
// two-source rule can be tested without a DOM. A falsy speaker means single-source output,
// where the target is simply the last row — exactly the behaviour before the mic existed.
//
// A screenshot is never the target. With a speaker on the wire it could not be — "screen" is
// neither — but single-source output carries no speaker at all, and "the last row" would
// then be the shot: replaced by a line of speech, and, being asked, asked again as one.
function lastIndexForSpeaker(list, speaker) {
  for (let i = list.length - 1; i >= 0; i--) {
    if (isShot(list[i])) continue;
    if (!speaker || list[i].speaker === speaker) return i;
  }
  return -1;
}

// --- phone panes ---------------------------------------------------------
//
// A phone has room for one pane, not two, so the answer and the transcript take turns and
// the tab bar says which is up. What tabs would otherwise cost is the live caption, and
// that is the one thing on the page with a deadline — it shows a question forming before
// there is a row for it. So the caption sits outside both panes and survives the switch,
// with an Ask button for the newest question beside it.

// Matches the CSS breakpoint. Read live rather than cached: rotating a phone crosses it.
const PHONE = "(max-width: 820px)";
function isPhone() {
  return !!(window.matchMedia && window.matchMedia(PHONE).matches);
}

let unseen = 0;

/// Questions that arrived while the transcript was hidden.
///
/// "Seen" means looked at — not asked, and not elapsed. The badge exists to answer "did I
/// miss anything while I was reading", so only opening the transcript can clear it.
function bumpUnseen(current, transcriptVisible) {
  return transcriptVisible ? 0 : current + 1;
}

/// What the caption's Ask button points at: the newest question, answered or not.
///
/// Not "the newest unanswered one". The caption shows that line's text, and a button that
/// disappeared the moment the line was answered would leave the text stranded with no way
/// back to the answer it already has. `ask` refuses to spend a second call on a question
/// that has one, so pointing at it is safe in both states — only the label changes.
//
// The newest thing that was *said*. A screenshot row is last in the list for as long as nobody
// speaks, and the caption is a line of speech with a button that asks it: showing a shot's
// label there read as something somebody had said, over a button naming a different row.
function peekTarget(list) {
  for (let i = list.length - 1; i >= 0; i--) {
    if (!isShot(list[i])) return list[i];
  }
  return null;
}

// Speech in progress, if any. Held rather than read back off the element because the
// caption also has to render when there is none, and "" is a meaningful state.
let partialText = "";
// Whose speech it is. A partial from the tap carries no speaker; the mic labels its own.
let partialSpeaker = "caller";

/// Whether the partial still in progress belongs to a side that was just silenced.
///
/// Muting mid-sentence discards the audio, but the words already sent as a partial were
/// sitting in the caption and stayed there for the rest of the session. Each control
/// clears only its own side: muting yourself must not blank a caller mid-question.
function captionStale(speaker, control) {
  return (speaker === "you" && control.mic === "muted")
      || (speaker === "caller" && control.tap === "paused");
}

/// The caption line: speech in progress, or failing that the last thing that was said.
///
/// It used to blank on every endpoint, which is the whole bug: the words moved into the
/// transcript, and on a phone the transcript is behind a tab, so what was left was an Ask
/// button beside an empty line with no clue what it would ask.
function renderCaption() {
  if (partialText) {
    live.innerHTML = esc(partialText) + '<span class="cursor"></span>';
    return;
  }
  const last = peekTarget(questions);
  live.innerHTML = last
    ? `<span class="settled">${esc(last.text)}</span>`
    : '<span class="cursor"></span>';
}

function transcriptVisible() {
  return !isPhone() || document.body.dataset.pane === "transcript";
}

function setPane(name) {
  document.body.dataset.pane = name;
  if (name === "transcript") unseen = 0;
  renderTabs();
}

function renderTabs() {
  const onTranscript = document.body.dataset.pane === "transcript";
  $("tabAnswer").setAttribute("aria-selected", String(!onTranscript));
  $("tabTranscript").setAttribute("aria-selected", String(onTranscript));
  const badge = $("unseen");
  badge.hidden = unseen === 0;
  badge.textContent = unseen;
}

const peekAsk = $("peekAsk");
let peekQ = null;

function renderPeek() {
  peekQ = isPhone() ? peekTarget(questions) : null;
  peekAsk.hidden = !peekQ;
  // The control says what pressing it does. On a line that already has an answer this only
  // brings it back to the stage, and calling it Ask would promise a second opinion it is
  // not going to deliver.
  peekAsk.textContent = peekQ && peekQ.asked ? "View" : "Ask";
}

// Crossing the breakpoint changes what these render, and nothing else re-runs them:
// rotating a phone to landscape, or dragging a desktop window narrow, otherwise leaves the
// caption's Ask button on a layout that has no caption bar to put it in.
if (window.matchMedia) {
  window.matchMedia(PHONE).addEventListener("change", () => { renderTabs(); renderPeek(); });
}

$("tabAnswer").addEventListener("click", () => setPane("answer"));
$("tabTranscript").addEventListener("click", () => setPane("transcript"));
peekAsk.addEventListener("click", () => { if (peekQ) ask(peekQ); });
setPane("answer");

// --- answers -------------------------------------------------------------

const BULLET  = /^\s*[-*•]\s+/;
const ORDERED = /^\s*\d+[.)]\s+/;
// The first word is the language; anything after it is ignored, as CommonMark does. Models
// write ```python title=limiter.py and ```js {1,3}, and refusing those lines outright was
// far worse than dropping the extra: the code rendered as literal backticks AND the closing
// fence then opened a block of its own that swallowed the prose after it.
const FENCE   = /^\s*```\s*([A-Za-z0-9_+#-]*)[^\n]*$/;
const HEADING = /^(#{1,6})\s+(.*)$/;
// Tested before the list markers: `---` is a rule, `- ` is a bullet. BULLET requires the
// trailing space, so they cannot collide, but the order makes that independent of it.
const RULE    = /^\s*([-*_])\1{2,}\s*$/;
// A table needs BOTH a pipe row and a separator under it. Prose contains pipes often enough
// ("run | grep to filter") that a pipe alone must never restructure a line.
const TABLE_ROW = /^\s*\|.*\|\s*$/;
const TABLE_SEP = /^\s*\|(?:\s*:?-{3,}:?\s*\|)+\s*$/;

// Inline markup. Escaping runs BEFORE any tag is inserted — the answer is model output
// written straight into innerHTML, so that ordering is the whole XSS boundary, not a style
// preference. Code spans are lifted out first so that `**` inside one stays literal.
function inlineMd(s) {
  const spans = [];
  // Stripped first. U+0000 is the sentinel this function lifts code spans out behind, so
  // one already present in the text is ambiguous with a placeholder, and a raw NUL written
  // into innerHTML is not something any answer needs.
  let out = String(s).replace(/\u0000/g, "")
    .replace(/`([^`]+)`/g, (_, c) => `\u0000${spans.push(c) - 1}\u0000`);
  out = esc(out);
  // Bold first, and its body may contain anything that is not the closing `**` — including
  // a nested italic. `[^*]+` refused to span one, so `**when *N* changes**` fell through
  // both patterns and rendered its asterisks literally.
  out = out.replace(/\*\*(.+?)\*\*/gs, "<strong>$1</strong>")
           .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
  return out.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(spans[i])}</code>`);
}

function tableCells(line) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(c => c.trim());
}

// `rows` is the header, the separator, then whatever body rows have arrived. Alignment
// colons are accepted so the table still parses, but are not applied — a comparison table
// in a side panel is read, not totted up.
function tableBlock(rows) {
  const headCells = tableCells(rows[0]);
  const head = headCells.map(c => `<th>${inlineMd(c)}</th>`).join("");
  // Every body row is squared to the header. A row with a stray pipe used to be emitted
  // with its own cell count, which adds a column to the whole table rather than to that
  // row — one mistyped separator and every column after it reads under the wrong heading.
  const body = rows.slice(2)
    .map(r => {
      const cells = tableCells(r).slice(0, headCells.length);
      while (cells.length < headCells.length) cells.push("");
      return `<tr>${cells.map(c => `<td>${inlineMd(c)}</td>`).join("")}</tr>`;
    })
    .join("");
  return `<div class="tablewrap"><table><thead><tr>${head}</tr></thead>`
    + `<tbody>${body}</tbody></table></div>`;
}

// --- syntax highlighting -------------------------------------------------
//
// Hand-rolled, because the page loads nothing from the internet — a CDN highlighter is not
// an option for a tool whose setup is meant to work on a machine with no network at all.
//
// One regex per language, alternating comment | string | number | keyword | call, matched
// in that order. The order is the whole design: a comment or a string is consumed as a
// single token, so keywords inside one are never seen as keywords. Naive word replacement
// gets that wrong and corrupts the code on screen, which is worse than no colour at all.
const KEYWORDS = {
  python: "def class lambda return yield if elif else for while break continue pass import from as with try except finally raise assert del global nonlocal and or not in is None True False async await self match case",
  javascript: "const let var function return class extends new this super if else for while do break continue switch case default try catch finally throw typeof instanceof in of delete void async await yield import from export as null undefined true false interface type enum implements public private protected readonly static get set",
  go: "func package import type struct interface map chan var const return if else for range switch case default break continue goto defer go select fallthrough nil true false make new len cap append error string int int64 float64 bool byte rune",
  rust: "fn let mut const struct enum impl trait pub use mod match if else for while loop break continue return where as dyn ref move Self self crate super async await unsafe true false Some None Ok Err String Vec Option Result",
  java: "public private protected class interface extends implements static final void return new if else for while do break continue switch case default try catch finally throw throws import package this super abstract synchronized volatile transient native enum instanceof null true false int long double float boolean char String",
  swift: "func var let class struct enum protocol extension import return if else guard for while repeat break continue switch case default do try catch throw throws rethrows defer where as is in init deinit self Self super static public private internal fileprivate open final lazy weak unowned mutating nil true false async await actor some any",
  sql: "select from where group by order having join inner left right outer full on as insert into values update set delete create table drop alter index view distinct limit offset union all and or not null is in between like exists case when then else end count sum avg min max primary key foreign references default",
  bash: "if then else elif fi for while do done case esac function return local export source echo cd exit set unset readonly declare trap shift in until break continue",
  lua: "function local return if then else elseif end for while do repeat until break in and or not nil true false require pairs ipairs",
  ruby: "def class module end return if elsif else unless while until for in do begin rescue ensure raise yield require attr_accessor attr_reader attr_writer self nil true false and or not then case when next break",
  yaml: "true false null yes no on off",
  json: "true false null",
};

// The aliases a model actually writes on a fence.
const LANG_ALIAS = {
  py: "python", python3: "python", js: "javascript", jsx: "javascript", mjs: "javascript",
  ts: "javascript", tsx: "javascript", typescript: "javascript", node: "javascript",
  golang: "go", rs: "rust", kt: "java", kotlin: "java", scala: "java", cs: "java",
  csharp: "java", c: "go", cpp: "go", h: "go", objc: "swift",
  sh: "bash", zsh: "bash", shell: "bash", console: "bash", psql: "sql", postgres: "sql",
  mysql: "sql", sqlite: "sql", rb: "ruby", yml: "yaml", jsonc: "json",
};

// Languages whose backtick is a string or a command substitution. Shared across all of
// them, a backtick that merely appears in a Python line gets painted as a literal.
const BACKTICK_STRINGS = { javascript: 1, go: 1, bash: 1, ruby: 1 };

const COMMENTS = {
  python: { line: "#" }, ruby: { line: "#" }, bash: { line: "#" },
  yaml: { line: "#" }, json: {},
  javascript: { line: "//", block: ["/*", "*/"] },
  go: { line: "//", block: ["/*", "*/"] },
  rust: { line: "//", block: ["/*", "*/"] },
  java: { line: "//", block: ["/*", "*/"] },
  swift: { line: "//", block: ["/*", "*/"] },
  sql: { line: "--", block: ["/*", "*/"] },
  lua: { line: "--", block: ["--[[", "]]"] },
};

function reEscape(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

const SYNTAX_CACHE = {};

function syntaxFor(lang) {
  const name = LANG_ALIAS[lang] || lang;
  if (!KEYWORDS[name]) return null;
  if (SYNTAX_CACHE[name]) return SYNTAX_CACHE[name];

  const comment = COMMENTS[name] || {};
  const commentAlts = [];
  // Block before line: `/*` must not be read as two characters of a `/` comment.
  if (comment.block) {
    commentAlts.push(reEscape(comment.block[0]) + "[\\s\\S]*?" + reEscape(comment.block[1]));
  }
  if (comment.line) commentAlts.push(reEscape(comment.line) + "[^\\n]*");

  const parts = [];
  // An alternative that can never match, so the group numbering stays fixed whether or not
  // the language has comments — the class is chosen by which group matched.
  parts.push(commentAlts.length ? "(" + commentAlts.join("|") + ")" : "(x^)");
  // Triple quotes before single, or a docstring opens as an empty string and the rest of
  // the file is misparsed from there.
  parts.push("('''[\\s\\S]*?'''|\"\"\"[\\s\\S]*?\"\"\"" +
             "|'(?:\\\\.|[^'\\\\\\n])*'" +
             "|\"(?:\\\\.|[^\"\\\\\\n])*\"" +
             (BACKTICK_STRINGS[name] ? "|`(?:\\\\.|[^`\\\\])*`" : "") + ")");
  parts.push("(\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b)");
  parts.push("(\\b(?:" + KEYWORDS[name].trim().split(/\s+/).map(reEscape).join("|") + ")\\b)");
  // An identifier sitting immediately before "(" — a call, not a reserved word.
  parts.push("([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()");

  SYNTAX_CACHE[name] = new RegExp(parts.join("|"), "g");
  return SYNTAX_CACHE[name];
}

// Escaped HTML for one code block, with token spans.
//
// Every slice goes through `esc` before any span is inserted. The code is model output on
// its way into innerHTML and highlighting means inserting tags into it, so the escaping has
// to survive that rather than be replaced by it.
function highlight(code, lang) {
  const re = syntaxFor(String(lang || "").toLowerCase());
  if (!re) return esc(code);

  const CLASSES = ["t-com", "t-str", "t-num", "t-kw", "t-fn"];
  let out = "", last = 0, m;
  re.lastIndex = 0;
  while ((m = re.exec(code)) !== null) {
    if (m[0] === "") { re.lastIndex++; continue; }   // a zero-length match would spin here
    let cls = null;
    for (let g = 1; g <= CLASSES.length; g++) {
      if (m[g] !== undefined) { cls = CLASSES[g - 1]; break; }
    }
    out += esc(code.slice(last, m.index));
    out += cls ? '<span class="' + cls + '">' + esc(m[0]) + "</span>" : esc(m[0]);
    last = m.index + m[0].length;
  }
  return out + esc(code.slice(last));
}

function codeBlock(lang, text) {
  return `<figure class="code"><figcaption><span class="lang">${esc(lang || "code")}</span>`
    + `<button class="copy" type="button">copy</button></figcaption>`
    + `<pre><code>${highlight(text, lang)}</code></pre></figure>`;
}

// A small block-level renderer: fenced code, headings, bullet and numbered lists,
// paragraphs. Deliberately not a CommonMark implementation — the page loads nothing from
// the internet, so every feature here is one we hand-carry and keep correct.
function md(src) {
  const lines = String(src || "").split("\n");
  let out = "", para = [], code = null, lang = "";

  // Open lists, outermost first, each with the indent that opened it. Nesting and the
  // source's own numbering both matter here for reading aloud rather than for looks: an
  // <ol> that reopens has the browser counting from 1 again, so a step the answer calls 3
  // is announced as 1, and a sub-step flattened into its parent is presented as a top-level
  // step and renumbers everything after it.
  let lists = [], itemOpen = false;

  const closeItem = () => { if (itemOpen) { out += "</li>"; itemOpen = false; } };
  const closeLists = () => {
    while (lists.length) {
      closeItem();
      out += `</${lists.pop().tag}>`;
      // Popping a nested list puts us back inside the parent's item, which is still open.
      itemOpen = lists.length > 0;
    }
    itemOpen = false;
  };
  // `start` only when it is not 1, so ordinary lists stay free of the attribute.
  const openList = (tag, line) => {
    if (tag !== "ol") return "<ul>";
    const n = parseInt(line, 10);
    return Number.isFinite(n) && n !== 1 ? `<ol start="${n}">` : "<ol>";
  };
  const flushPara = () => {
    if (para.length) { out += `<p>${inlineMd(para.join(" "))}</p>`; para = []; }
  };
  // Closed here rather than treated as malformed: renderAnswer runs on every streaming
  // delta, so a fence with no terminator is the normal mid-answer state. Rendering it
  // means code grows on screen as it arrives instead of appearing once the answer ends.
  const closeCode = () => { out += codeBlock(lang, code.join("\n")); code = null; lang = ""; };

  // Indexed rather than for-of: a table is recognised by looking one line ahead for its
  // separator, and then consumes the rows it owns.
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const fence = raw.match(FENCE);
    if (code !== null) {
      if (fence) closeCode(); else code.push(raw);
      continue;
    }
    if (fence) { flushPara(); closeLists(); code = []; lang = fence[1] || ""; continue; }

    const line = raw.trim();
    if (!line) { flushPara(); closeLists(); continue; }

    if (TABLE_ROW.test(raw) && TABLE_SEP.test(lines[i + 1] || "")) {
      flushPara(); closeLists();
      const rows = [lines[i], lines[i + 1]];
      let j = i + 2;
      // Mid-stream the body is still arriving; whatever rows exist are rendered now and the
      // rest appear on the next delta.
      while (j < lines.length && TABLE_ROW.test(lines[j]) && !TABLE_SEP.test(lines[j])) {
        rows.push(lines[j++]);
      }
      out += tableBlock(rows);
      i = j - 1;
      continue;
    }

    if (RULE.test(line)) { flushPara(); closeLists(); out += "<hr>"; continue; }

    const heading = line.match(HEADING);
    if (heading) {
      flushPara(); closeLists();
      // Answers arrive with `##` for what is a sub-heading in a side panel, not a document
      // title, so every level is shifted down and clamped.
      const level = Math.min(heading[1].length + 2, 6);
      out += `<h${level}>${inlineMd(heading[2])}</h${level}>`;
      continue;
    }
    const marker = BULLET.test(line) ? BULLET : ORDERED.test(line) ? ORDERED : null;
    if (marker) {
      flushPara();
      const indent = raw.length - raw.trimStart().length;
      const tag = marker === BULLET ? "ul" : "ol";

      // Shallower than what is open: close back to the level this item belongs to. The
      // outermost list is never closed here — an item at column 0 still belongs to it.
      while (lists.length > 1 && indent < lists[lists.length - 1].indent) {
        closeItem();
        out += `</${lists.pop().tag}>`;
        itemOpen = lists.length > 0;
      }

      const innermost = lists[lists.length - 1];
      if (!innermost) {
        out += openList(tag, line);
        lists.push({ tag, indent });
      } else if (indent > innermost.indent) {
        // Deeper. The nested list goes inside the item above it, which stays open, so the
        // markup nests rather than the sub-steps becoming siblings.
        out += openList(tag, line);
        lists.push({ tag, indent });
        itemOpen = false;
      } else if (tag !== innermost.tag) {
        closeItem();
        out += `</${lists.pop().tag}>`;
        out += openList(tag, line);
        lists.push({ tag, indent });
        itemOpen = false;
      } else {
        closeItem();
      }
      out += `<li>${inlineMd(line.replace(marker, ""))}`;
      itemOpen = true;
      continue;
    }

    closeLists();
    para.push(line);
  }
  if (code !== null) closeCode();
  flushPara();
  closeLists();
  return out;
}

// The question currently on the stage. One at a time: the stage is what is being read
// aloud, so an answer arriving for some other row must not replace what is under the
// reader's eyes mid-sentence.
let onStage = null;

function markRows() {
  for (const q of questions) {
    if (!q.el) continue;
    q.el.classList.toggle("answered", !!q.asked);
    q.el.classList.toggle("onstage", q === onStage);
  }
}

/// Makes `q` the question on the stage and paints it. No pane switch — see `activate`.
function putOnStage(q) {
  onStage = q;
  const head = $("stageHead");
  head.hidden = false;
  head.innerHTML =
    (q.speaker ? `<div class="who">${esc(speakerLabel(q))}</div>` : "")
    + `<div class="q-text">${esc(q.text)}</div>`;
  markRows();
  renderAnswer(q);
  renderPeek();
}

/// Puts a question on the stage. Does not ask — see `ask`.
///
/// Kept separate deliberately: the whole row is clickable so you can bring an earlier
/// answer back, and if that also asked, one stray click on the transcript would spend an
/// API call on a line you were only glancing at.
function activate(q) {
  putOnStage(q);
  $("stage").scrollTop = 0;
  // On a phone the answer is behind a tab, so putting something on the stage has to bring
  // the stage with it — otherwise the tap that asked leaves you watching the transcript
  // while the answer streams out of sight. On a wide screen both panes are already up and
  // switching would be a regression, not a convenience.
  if (isPhone()) setPane("answer");
}

/// Shows it and asks, which is what the Ask button and Enter do.
function ask(q) {
  activate(q);
  if (!q.asked) askFor(q);
  renderPeek();
}


function renderAnswer(q) {
  // Streaming deltas arrive for whichever questions have been asked, including ones that
  // are no longer on the stage; those update their stored text and nothing else.
  if (q !== onStage) { markRows(); return; }
  const el = $("stageBody");
  if (q.error) { el.innerHTML = `<div class="failed">${esc(q.error)}</div>`; return; }
  if (!q.asked) {
    el.innerHTML = '<div class="stage-empty"><p>Not asked yet.</p>'
      + '<p class="hint">Press <button class="ask" id="stageAsk">Ask</button>'
      + ' or hit <kbd>Enter</kbd> with this line selected.</p></div>';
    const b = $("stageAsk");
    if (b) b.addEventListener("click", () => ask(q));
    return;
  }
  const text = (q.answer || "").trim();
  if (!text) { el.innerHTML = '<div class="pending">Asking…</div>'; return; }
  el.innerHTML = md(text)
    + (q.truncated
        ? '<div class="cut">\u26a0 cut off at the length limit \u2014 this answer is incomplete</div>'
        : "");
}

// --- split pane ----------------------------------------------------------

const SPLIT_DEFAULT = 65, SPLIT_MIN = 30, SPLIT_MAX = 80;

// A drag reports a pointer position, which can be anywhere — outside the window, or NaN if
// the gutter is grabbed before layout settles. Unclamped, one overshoot collapses a pane to
// zero and there is no gutter left wide enough to drag back; NaN collapses the whole grid.
function clampSplit(pct) {
  if (!Number.isFinite(pct)) return SPLIT_DEFAULT;
  return Math.max(SPLIT_MIN, Math.min(SPLIT_MAX, Math.round(pct)));
}

function storedSplit() {
  try {
    const v = parseFloat(localStorage.getItem("wngmn.split"));
    return Number.isFinite(v) ? clampSplit(v) : SPLIT_DEFAULT;
  } catch { return SPLIT_DEFAULT; }
}

function applySplit(pct, remember) {
  const value = clampSplit(pct);
  document.querySelector("main").style.setProperty("--split", value + "%");
  if (remember) {
    try { localStorage.setItem("wngmn.split", String(value)); } catch { /* private window */ }
  }
  // The chart measures its own width, so it has to be redrawn after the column resizes.
  drawChart();
}

(function initSplit() {
  const gutter = $("gutter");
  applySplit(storedSplit(), false);

  // A plain flag rather than `hasPointerCapture`. Capture is best-effort — it is not
  // reliably still held by the time `pointerup` arrives — and gating teardown on it left
  // `body.resizing` stuck on, which is `user-select:none` and a col-resize cursor over the
  // entire page with no way to clear it but a reload.
  let dragging = false;

  function positionFrom(ev) {
    const box = document.querySelector("main").getBoundingClientRect();
    return box.width ? ((ev.clientX - box.left) / box.width) * 100 : null;
  }

  function stopDragging(ev, remember) {
    if (!dragging) return;
    dragging = false;
    gutter.classList.remove("dragging");
    document.body.classList.remove("resizing");
    try { gutter.releasePointerCapture(ev.pointerId); } catch { /* already released */ }
    const pct = positionFrom(ev);
    // Written once at the end: a drag fires moves continuously and every one would be a
    // storage write.
    if (remember && pct !== null) applySplit(pct, true);
  }

  gutter.addEventListener("pointerdown", ev => {
    ev.preventDefault();
    dragging = true;
    // Capture so a fast drag that outruns the 7px handle keeps sending its moves here
    // rather than to whatever is underneath the pointer.
    try { gutter.setPointerCapture(ev.pointerId); } catch { /* not fatal, window handles it */ }
    gutter.classList.add("dragging");
    document.body.classList.add("resizing");
  });

  gutter.addEventListener("pointermove", ev => {
    if (!dragging) return;
    const pct = positionFrom(ev);
    if (pct !== null) applySplit(pct, false);
  });

  // On the window, not the gutter: if capture is lost the release lands somewhere else
  // entirely, and a drag that never ends is worse than one that ends early.
  window.addEventListener("pointerup", ev => stopDragging(ev, true));
  window.addEventListener("pointercancel", ev => stopDragging(ev, false));
  window.addEventListener("blur", () => {
    if (!dragging) return;
    dragging = false;
    gutter.classList.remove("dragging");
    document.body.classList.remove("resizing");
  });

  // Keyboard-reachable, because a divider that answers only to a precise drag is unusable
  // for anyone who cannot make one.
  gutter.addEventListener("keydown", ev => {
    const step = ev.key === "ArrowLeft" ? -2 : ev.key === "ArrowRight" ? 2 : 0;
    if (!step) return;
    applySplit(storedSplit() + step, true);
    ev.preventDefault();
  });

  gutter.addEventListener("dblclick", () => applySplit(SPLIT_DEFAULT, true));
})();

// --- side panel ----------------------------------------------------------

// Remembered per browser: a laptop used at full width and a phone that never wants the
// panel should not have to be set on every reload. Wrapped because storage throws outright
// in a private window rather than returning null.
function asideHidden() {
  try { return localStorage.getItem("wngmn.aside") === "hidden"; } catch { return false; }
}

function renderAside(redraw) {
  const hidden = asideHidden();
  $("chat").classList.toggle("no-panel", hidden);
  $("panel").textContent = hidden ? "\u25b8 panel" : "\u25be panel";
  $("panel").classList.toggle("off", hidden);
  // The chart measures its own width, so it has to be redrawn once the column it lives in
  // has actually resized. Only on a toggle: at load there is nothing to plot yet, and the
  // first questions will draw it.
  if (redraw && !hidden) drawChart();
}

function toggleAside() {
  try {
    localStorage.setItem("wngmn.aside", asideHidden() ? "shown" : "hidden");
  } catch { /* private window: the toggle still works, it just will not be remembered */ }
  renderAside(true);
}

$("panel").addEventListener("click", toggleAside);
renderAside(false);

// --- scroll sync ---------------------------------------------------------

// Position is shared as an anchor — which row is under the top of the viewport, and how far
// into it — never as `scrollTop`. A phone and a laptop lay the same transcript out at
// different heights, so a pixel offset from one is meaningless on the other.
function scrollAnchor(rows, top) {
  if (!rows.length) return { index: 0, into: 0 };
  let index = 0;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].top <= top) index = i; else break;
  }
  const row = rows[index];
  const into = row.height > 0 ? (top - row.top) / row.height : 0;
  return { index, into: Math.max(0, Math.min(1, into)) };
}

// Recomputed against the receiver's own layout, which is the point of sending an anchor.
function scrollOffsetFor(rows, anchor) {
  if (!rows.length) return 0;
  const row = rows[Math.max(0, Math.min(rows.length - 1, anchor.index))];
  return Math.round(row.top + row.height * (anchor.into || 0));
}

function rowGeometry() {
  return questions.map(q => ({ top: q.el.offsetTop, height: q.el.offsetHeight }));
}

// Applying a remote position fires a local scroll event, which would broadcast straight
// back and set the two ends oscillating. Suppressed for slightly longer than the throttle
// so the echo has passed before local scrolling is listened to again.
let applyingRemoteScroll = 0;
let lastScrollSent = 0;

lines.addEventListener("scroll", () => {
  if (!$("syncscroll").checked) return;
  if (Date.now() < applyingRemoteScroll) return;
  const now = Date.now();
  if (now - lastScrollSent < 120) return;   // `scroll` fires far faster than SSE should
  lastScrollSent = now;
  const anchor = scrollAnchor(rowGeometry(), lines.scrollTop);
  fetch("/control" + window.location.search, {
    method: "POST",
    // Declared JSON so the server can tell this apart from a cross-origin POST, which
    // cannot set this header without a preflight the server refuses.
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ scroll: anchor }),
  }).catch(() => {});
});

function applyRemoteScroll(anchor) {
  if (!$("syncscroll").checked || !anchor) return;
  applyingRemoteScroll = Date.now() + 250;
  lines.scrollTop = scrollOffsetFor(rowGeometry(), anchor);
}

// --- capture controls ----------------------------------------------------

const controlState = { mic: "live", tap: "listening", auto: "off" };

// The capture layer reports its state as "mic=live tap=listening" on a `control` status
// line. Pure, so the parsing is testable without a page.
function parseControlDetail(detail) {
  const out = {};
  const mic = /mic=([a-z]+)/.exec(detail || "");
  const tap = /tap=([a-z]+)/.exec(detail || "");
  const auto = /auto=([a-z]+)/.exec(detail || "");
  if (mic) out.mic = mic[1];
  if (tap) out.tap = tap[1];
  if (auto) out.auto = auto[1];
  return out;
}

function renderControls() {
  const tap = $("tapctl"), mic = $("micctl");
  const paused = controlState.tap === "paused";
  tap.textContent = paused ? "▶ paused" : "⏸ listening";
  tap.classList.toggle("off", paused);
  const muted = controlState.mic === "muted";
  mic.textContent = muted ? "mic muted" : "mic on";
  mic.classList.toggle("off", muted);
  const auto = $("autoanswer");
  if (auto) auto.checked = controlState.auto === "on";
}

async function setControl(patch) {
  try {
    const res = await fetch("/control" + window.location.search, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(patch),
    });
    if (!res.ok) throw new Error(await res.text());
    Object.assign(controlState, await res.json());
  } catch (e) {
    // Leave the buttons showing the last state we actually confirmed. A button reading
    // "muted" when the microphone is in fact live is the one outcome worth avoiding.
  }
  renderControls();
}

$("tapctl").addEventListener("click", () =>
  setControl({ tap: controlState.tap === "paused" ? "listening" : "paused" }));
$("micctl").addEventListener("click", () =>
  setControl({ mic: controlState.mic === "muted" ? "live" : "muted" }));
$("autoanswer").addEventListener("change", (e) =>
  setControl({ auto: e.target.checked ? "on" : "off" }));
// An empty patch changes nothing and returns the current state, which is how the page
// learns it was started with --start-paused.
setControl({});

// --- keyboard ------------------------------------------------------------

// Pure so the clamping rules are testable without a DOM. Clamps rather than wraps: the
// transcript is read top to bottom under time pressure, and silently jumping from the
// newest question to the oldest would lose the reader's place mid-call.
function nextSelection(current, count, delta) {
  if (count <= 0) return -1;
  // Nothing selected yet starts at the newest, which is what the reader is looking at.
  if (current < 0) return count - 1;
  return Math.max(0, Math.min(count - 1, current + delta));
}

let selected = -1;

function showSelection() {
  questions.forEach((q, i) => { if (q.el) q.el.classList.toggle("selected", i === selected); });
  const current = questions[selected];
  if (current && current.el) current.el.scrollIntoView({ block: "nearest" });
}

document.addEventListener("keydown", ev => {
  // Leave browser and OS combinations alone, and never hijack a key aimed at a control.
  // `button` matters specifically: Enter on a focused Ask button is already native
  // activation, and handling it here as well would fire the request twice.
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  const tag = (ev.target.tagName || "").toLowerCase();
  if (tag === "input" || tag === "textarea" || tag === "button") return;
  if (ev.target.isContentEditable) return;

  if (ev.key === "\\") {
    toggleAside();
    ev.preventDefault();
  } else if (ev.key === "p") {
    setControl({ tap: controlState.tap === "paused" ? "listening" : "paused" });
    ev.preventDefault();
  } else if (ev.key === "m" && !$("micctl").hidden) {
    setControl({ mic: controlState.mic === "muted" ? "live" : "muted" });
    ev.preventDefault();
  } else if (ev.key === "j" || ev.key === "k") {
    selected = nextSelection(selected, questions.length, ev.key === "j" ? 1 : -1);
    showSelection();
    ev.preventDefault();
  } else if (ev.key === "Enter" && questions[selected]) {
    ask(questions[selected]);
    ev.preventDefault();
  }
});

// One delegated listener, not one per render: renderAnswer replaces innerHTML on every
// streaming delta, so per-block listeners would be attached and discarded per token. It
// listens on the stage, where answers render — it used to sit on the transcript column,
// where no code block ever appears, so the button did nothing. textContent is read off
// the <code>, so what lands on the clipboard is the source rather than the escaped markup.
$("stage").addEventListener("click", ev => {
  const button = ev.target.closest && ev.target.closest(".copy");
  if (!button) return;
  const block = button.closest(".code").querySelector("code");
  copyToClipboard(button, block.textContent);
});

// Shared by the code blocks and the notes card. The button's own label is the only feedback
// the page gives — there is no toast — so the two must not drift apart. writeText rejects
// rather than throws when the document is not focused or the permission is refused, and a
// button that silently did nothing would read as a broken page, so the failure is shown.
function copyToClipboard(button, text) {
  navigator.clipboard.writeText(text).then(
    () => {
      button.textContent = "copied";
      setTimeout(() => { button.textContent = "copy"; }, 1200);
    },
    () => { button.textContent = "failed"; }
  );
}

// What a manual Ask sends as context: the six lines before it. Only what came before — a
// later one is not context for it — and only what was said: a manual Ask does not see a
// screenshot, so it must not be handed the screenshot's label as though someone had spoken it.
function recentBefore(list, q) {
  const index = list.indexOf(q);
  return list.slice(0, index < 0 ? list.length : index)
    .filter(x => !isShot(x)).slice(-6).map(x => x.text);
}

// Fires the request and returns. The answer is rendered from `/events` like everything
// else, so a laptop and a phone show the same thing because they are running the same code
// path, not because two paths were kept in step.
async function askFor(q) {
  if (q.asked) return;
  q.asked = true;
  q.answer = "";
  q.error = null;
  if (q.el) { const b = q.el.querySelector(".ask"); if (b) b.disabled = true; }
  markRows();
  renderAnswer(q);

  // Only what came before this question — a later one is not context for it.
  const recent = recentBefore(questions, q);

  try {
    const res = await fetch("/ask" + window.location.search, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: q.text, recent, key: questionKey(q), t1: q.t1 }),
    });
    if (!res.ok) throw new Error("server returned " + res.status);
  } catch (e) {
    q.error = String(e);
    renderAnswer(q);
  }
}

// Applies an answer frame to whichever question it belongs to, on every page that has it.
function applyAnswer(e) {
  const q = questions.find(x => questionKey(x) === e.key);
  if (!q) return;
  // Every frame names the question it answers. One for text this row has since been
  // revised away from is stale: the server had already written the half's tokens to the
  // socket before it heard about the revision, and applied, they landed under the revised
  // question ahead of its own answer. A frame for a revision always follows the revision's
  // own `question` event on the same ordered stream, so nothing current is ever dropped.
  if (e.for !== undefined && e.for !== q.text) return;
  // Revealed and locked wherever it arrives, so a second device shows "already asked"
  // rather than offering a button that would spend another API call on the same question.
  q.asked = true;
  if (q.el) { const b = q.el.querySelector(".ask"); if (b) b.disabled = true; }

  // Applied before the stage is consulted. Claiming the stage first and returning left
  // this frame unapplied: a page whose stage was empty lost the first token of a live
  // answer, showed "Asking…" for good after being replayed a finished one, and never
  // showed a failure at all.
  if (e.type === "answer") q.answer = (q.answer || "") + e.text;
  // `answer_done` carries the whole text, so a replayed answer lands complete and a live
  // one is simply confirmed rather than doubled.
  else if (e.type === "answer_done") {
    q.answer = e.text;
    // Marked on the answer, not logged somewhere else: a half-written sentence is about to
    // be read aloud, and the reader has to be able to see that it does not end.
    q.truncated = !!e.truncated;
  }
  else if (e.type === "answer_failed") q.error = e.detail;

  // Claimed only when nothing is on the stage — on a second device that is the answer you
  // just asked for elsewhere, and while you are reading one it must not be yanked away.
  if (!onStage) { activate(q); return; }
  markRows();
  renderAnswer(q);
}

function addQuestion(e) {
  const atBottom = lines.scrollHeight - lines.scrollTop - lines.clientHeight < 60;
  // `t1` rides along so an ask can say when its question ended: two asks under one key
  // can cross on the wire, and the server orders a revision against a late ask of the
  // half it replaced by that.
  const q = { text: e.text, t0: e.t0, t1: e.t1, ms: e.ms, volatile: !!e.volatile, speaker: e.speaker };

  // Applying the same question twice has to leave one row. A reconnecting page is caught
  // up from a replay buffer, and a replay overlapping what it already has is normal rather
  // than exceptional — the server cannot know how much reached a socket before it dropped.
  // Without this, one Safari tab suspension doubles every question in the transcript.
  const key = questionKey(q);
  const seen = e.revises ? -1 : questions.findIndex(x => questionKey(x) === key);
  if (seen >= 0) {
    const prev = questions[seen];
    // Identical text is a pure duplicate: return before touching `asked`, `answer` or the
    // unseen count, none of which a re-delivery of something already applied should move.
    if (prev.text !== q.text) {
      prev.text = q.text;
      prev.ms = q.ms;
      prev.volatile = q.volatile;
      const el = questionNode(prev);
      prev.el.replaceWith(el);
      prev.el = el;
      markRows();
      renderCaption();
    }
    return;
  }

  // `revises` supersedes the most recent question rather than following it. Warnings and
  // partials can arrive in between, so this tracks the last question shown, not the last
  // line received.
  const target = e.revises ? lastIndexForSpeaker(questions, e.speaker) : -1;
  if (target >= 0) {
    const prev = questions[target];
    const el = questionNode(q);
    prev.el.replaceWith(el);
    q.el = el;
    questions[target] = q;
    // The stage follows the row. It pointed at the object just replaced, so without this
    // the revised question's answer streamed into a row nobody was looking at while the
    // stage kept showing the half the journalist did not finish.
    if (onStage === prev) putOnStage(q);
    // A question that was asked is asked again, with the whole of it. That ask — same key,
    // new text — is what makes the server drop the half's answer; without it the half's
    // tokens kept arriving under the revised row, marked it asked, and the reader could
    // not ask the real question at all. On a second device `asked` is set by the frames
    // themselves, so its identical re-ask is the duplicate the server already ignores.
    if (prev.asked) askFor(q);
  } else {
    const empty = lines.querySelector(".empty");
    if (empty) empty.remove();
    q.el = questionNode(q);
    lines.appendChild(q.el);
    questions.push(q);
  }
  // Not while a remote position is being applied: otherwise a new question yanks every
  // screen back to the bottom the instant someone scrolls up on another device.
  if (atBottom && Date.now() >= applyingRemoteScroll) lines.scrollTop = lines.scrollHeight;
  $("count").textContent = spokenCount();
  unseen = bumpUnseen(unseen, transcriptVisible());
  renderTabs();
  renderPeek();
  renderCaption();
  drawChart();
  // Warm the answer now so pressing Ask is instant. Off by default: it is one API call per
  // question, and most questions in an interview never need one.
  if ($("prefetch").checked && !isYou(q)) askFor(q);
}

function drawChart() {
  const svg = $("chart");
  // The caller's questions only: the chart is the budget, and the budget is theirs.
  // And only what was spoken. A row with no `ms` does not add an odd bar: `worst` comes out
  // undefined, `max` NaN, and every bar in the chart is drawn at NaN.
  const data = questions.filter(q => !isYou(q) && !isShot(q)).slice(-40);
  const W = svg.clientWidth || 300, H = 132, padB = 16, padT = 8;
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  if (!data.length) { svg.innerHTML = ""; return; }

  const vals = data.map(d => d.ms);
  const sorted = [...vals].sort((a,b) => a-b);
  const median = sorted[Math.floor(sorted.length/2)];
  const worst = sorted[sorted.length-1];
  const over = data.filter(overBudget).length;
  $("med").textContent = median;
  $("worst").textContent = worst;
  $("over").textContent = over;
  $("over").className = "v" + (over ? " over" : "");

  // The bars are `ms`, so the budget rule is drawn where `ms` would put the local total
  // at the criterion: 700 ms less the hangover and delivery lag that `ms` leaves out. The
  // caller's hangover — the budget is about the journalist's question.
  const msBudget = BUDGET - hangoverMs() - DELIVERY_LAG_MS;
  // Scale to the data, not to the budget. Latency runs an order of magnitude under it,
  // so a budget-scaled axis renders every bar as a 5px stub and hides the drift that is the
  // whole reason to watch this during a 45-minute call. The budget rule is drawn only once
  // anything approaches it; until then the caption carries the headroom in words, which is
  // the more honest way to say "nowhere near the limit".
  const nearBudget = worst > msBudget * 0.5;
  const max = nearBudget ? Math.max(msBudget * 1.15, worst * 1.15) : worst * 1.35;
  const y = v => padT + (H - padT - padB) * (1 - v / max);
  const gap = 2;
  const bw = Math.max(3, (W - gap * (data.length - 1)) / data.length);

  let out = "";
  // Recessive baseline and scale, drawn under the data.
  out += `<line x1="0" y1="${H-padB}" x2="${W}" y2="${H-padB}" stroke="var(--axis)" stroke-width="1"/>`;
  out += `<text x="0" y="${H-4}" fill="var(--muted)" font-size="10">0</text>`;
  out += `<text x="${W}" y="${H-4}" text-anchor="end" fill="var(--muted)" font-size="10">${data.length} most recent</text>`;
  if (nearBudget) {
    out += `<line x1="0" y1="${y(msBudget)}" x2="${W}" y2="${y(msBudget)}" stroke="var(--crit)"
             stroke-width="1" stroke-dasharray="3 3" opacity="0.75"/>`;
    out += `<text x="2" y="${y(msBudget)-4}" fill="var(--muted)" font-size="10">${msBudget} ms — 700 less the hangover and delivery lag</text>`;
  } else {
    out += `<line x1="0" y1="${padT}" x2="${W}" y2="${padT}" stroke="var(--grid)" stroke-width="1"/>`;
    out += `<text x="2" y="${padT-1}" fill="var(--muted)" font-size="10">${Math.round(max)} ms</text>`;
  }

  data.forEach((d, i) => {
    const x = i * (bw + gap);
    const top = y(d.ms), h = Math.max(2, (H - padB) - top);
    const fill = overBudget(d) ? "var(--crit)" : "var(--series)";
    // 4px rounded data-end, anchored square to the baseline.
    const r = Math.min(4, bw/2, h);
    out += `<path d="M${x},${H-padB} L${x},${top+r} Q${x},${top} ${x+r},${top}
             L${x+bw-r},${top} Q${x+bw},${top} ${x+bw},${top+r} L${x+bw},${H-padB} Z"
             fill="${fill}"><title>${d.ms} ms — ${esc(d.text.slice(0, 80))}</title></path>`;
  });
  svg.innerHTML = out;

  // `ms` alone flatters every question, since it starts after the hangover was waited out.
  // The caption says what was added back, so the percentage is of the real budget.
  const worstRow = data.reduce((a, b) => (b.ms > a.ms ? b : a));
  const total = localLatency(worstRow);
  const pct = Math.round(total / BUDGET * 100);
  $("chartCap").innerHTML = over
    ? `Endpoint&nbsp;→&nbsp;final per question. <strong>${over} over the 700&nbsp;ms budget</strong>
       once each line's hangover and delivery lag are added back. Excludes Zoom/Meet
       transport.`
    : `Endpoint&nbsp;→&nbsp;final per question. Worst is ${worst}&nbsp;ms; with the
       ${hangoverMs()}&nbsp;ms hangover and delivery lag that is ${total}&nbsp;ms before Zoom/Meet
       transport — <strong>${pct}% of the 700&nbsp;ms budget</strong>.`;
}
window.addEventListener("resize", drawChart);

function addWarning(e) {
  const ul = $("warnings");
  const empty = ul.querySelector(".empty");
  if (empty) empty.remove();
  const li = document.createElement("li");
  li.innerHTML = `<code>${esc(e.code)}</code> · ${esc(e.detail || "")}
                  <span style="color:var(--muted)"> ${mmss(streamT)}</span>`;
  ul.prepend(li);
  while (ul.children.length > 40) ul.lastChild.remove();
}

const rawBuf = [];
function addRaw(line) {
  rawBuf.push(line);
  if (rawBuf.length > 200) rawBuf.shift();
  $("raw").textContent = rawBuf.slice(-200).reverse().join("\n");
}

function setState(text, cls) {
  $("state").textContent = text;
  $("dot").className = "dot" + (cls ? " " + cls : "");
}

function spokenCount() { return questions.filter(q => !isShot(q)).length; }

// A screenshot was taken. Its own function rather than a branch of `addQuestion`, which
// builds its row from a fixed list of fields, prefetches, and resolves revisions — none of
// which a shot wants.
//
// The row is born asked, with no answer. That is the only way this page shows "Asking…" —
// it has no pending state of its own — and it is what keeps every path that can ask a row
// (Enter, the caption's button, the stage's Ask) from posting the label to /ask as speech.
function addShot(e) {
  // Replay lands on rows the page already has, and must leave them, and the stage, alone.
  if (questions.some(x => questionKey(x) === e.key)) return;
  const atBottom = lines.scrollHeight - lines.scrollTop - lines.clientHeight < 60;
  const size = e.w && e.h ? ` · ${e.w}×${e.h}` : "";
  // A later part of a set: its answer reads every screenshot of the set together.
  const part = e.part > 1 ? ` · part ${e.part} of a set` : "";
  const q = {
    kind: "shot", key: e.key, speaker: "screen", t0: e.t, t1: e.t,
    text: `Screenshot · ${e.mode}${size}${part}`, asked: true, answer: "",
  };
  const empty = lines.querySelector(".empty");
  if (empty) empty.remove();
  q.el = questionNode(q);
  lines.appendChild(q.el);
  questions.push(q);
  if (atBottom && Date.now() >= applyingRemoteScroll) lines.scrollTop = lines.scrollHeight;
  unseen = bumpUnseen(unseen, transcriptVisible());
  renderTabs();
  // Whatever was there. The shutter is silenced, so this is the only sign the key worked.
  activate(q);
}

/// Applies one event from the stream. Apart from the socket so a test can drive it.
function handleEvent(e) {
    if (typeof e.t  === "number") streamT = e.t;
    if (typeof e.t1 === "number") streamT = e.t1;
    $("clock").textContent = mmss(streamT);

    switch (e.type) {
      case "status":
        if (e.state === "control") {
          Object.assign(controlState, parseControlDetail(e.detail));
          if (captionStale(partialSpeaker, controlState)) {
            partialText = "";
            renderCaption();
          }
          renderControls();
          break;
        }
        // A `mic` status means the microphone half exists; until then its button would be
        // a control over nothing.
        if (e.state === "mic") { $("micctl").hidden = false; break; }
        setState(e.state, e.state === "capturing" ? "live" : "");
        if (e.format) $("fmt").textContent = `${e.format.rate/1000} kHz · ${e.format.ch} ch`;
        break;
      case "partial":
        partialText = e.text;
        partialSpeaker = e.speaker || "caller";
        renderCaption();
        break;
      case "question":
        // The words are no longer in progress; `addQuestion` makes them the last line, and
        // `renderCaption` then shows them there rather than leaving the caption blank.
        partialText = "";
        addQuestion(e);
        noteActivity();
        break;
      case "shot":
        // `partialText` is left alone: somebody may be mid-sentence.
        addShot(e);
        noteActivity();
        break;
      case "scroll":
        applyRemoteScroll(e.anchor);
        break;
      case "auto": {
        autoUsed = true;
        const el = $("autoStat");
        if (el) {
          el.hidden = false;
          const calls = e.calls || 0, answers = e.answers || 0;
          el.textContent = `auto: ${answers} answered · ${calls} call${calls === 1 ? "" : "s"}`;
        }
        break;
      }
      case "summary_pending": autoUsed = true; showNotes('<div class="pending">Writing notes…</div>'); break;
      case "summary_done": showNotes(md(e.text || ""), e.text || ""); break;
      case "summary_failed": showNotes(`<div class="failed">${esc(e.detail || "notes could not be written")}</div>`); break;
      case "answer":
      case "answer_done":
      case "answer_failed":
        applyAnswer(e);
        break;
      case "warning":
        addWarning(e);
        // Two warnings are also a change of state. A failed rebuild is a warning because
        // the process keeps going and retries, but until the retry lands there is no
        // capture graph, and a pill still reading "capturing" over that is the failure the
        // watchdog exists to make visible. The next `capturing` status restores it.
        if (e.code === "rebuild_failed") setState("capture down", "down");
        else if (e.code === "rebuilding") setState("rebuilding…", "");
        break;
      case "error":   addWarning({ code: e.code, detail: e.detail }); setState("error", "down"); break;
    }
}

function connect() {
  const es = new EventSource("/events" + window.location.search);
  es.onopen = () => setState("connected", "live");
  es.onerror = () => setState("reconnecting…", "down");
  es.onmessage = ev => {
    let e;
    try { e = JSON.parse(ev.data); } catch { return; }
    addRaw(ev.data);
    handleEvent(e);
  };
}
// --- end-of-call notes ---------------------------------------------------
// A page asks whether the call is over after a stretch of silence, but only once something
// has been sent — an auto answer, or a screenshot, either of which arrives with an `auto`
// stats frame. A page that sent nothing has no ledger to summarise and should not be nagged.
// `No` snoozes until the next question resets the idle clock.
const CALL_IDLE_MS = 20000;
let lastActivity = Date.now();
let autoUsed = false;
let endPromptSnoozed = false;
let notesSource = "";

function noteActivity() { lastActivity = Date.now(); endPromptSnoozed = false; }
function hideEndPrompt() { $("endprompt").classList.remove("show"); }
function notesOpen() { return $("notes").classList.contains("show"); }
// `source` is the markdown the notes were rendered from, and what the copy button puts on
// the clipboard — the same choice the code blocks make, where the clipboard gets the source
// rather than the escaped markup. Notes are pasted into a doc or a message, so the markdown
// is the useful form. Without it (writing…, or a failure) there is nothing worth copying
// and the button stays hidden rather than offering an empty clipboard.
function showNotes(html, source) {
  $("notesBody").innerHTML = html;
  notesSource = source || "";
  const copy = $("notesCopy");
  copy.hidden = !notesSource;
  copy.textContent = "copy";
  $("notes").classList.add("show");
  hideEndPrompt();
}

function requestSummary() {
  showNotes('<div class="pending">Writing notes…</div>');
  fetch("/summarise" + window.location.search, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  }).then(res => { if (!res.ok) return res.text().then(t => { throw new Error(t); }); })
    .catch(e => showNotes(`<div class="failed">${esc(String(e))}</div>`));
}

$("endbtn").addEventListener("click", requestSummary);
$("endYes").addEventListener("click", requestSummary);
$("endNo").addEventListener("click", () => { hideEndPrompt(); endPromptSnoozed = true; });
$("notesCopy").addEventListener("click", () => copyToClipboard($("notesCopy"), notesSource));
$("notesClose").addEventListener("click", () => $("notes").classList.remove("show"));
$("notes").addEventListener("click", (e) => { if (e.target.id === "notes") $("notes").classList.remove("show"); });

setInterval(() => {
  if (!autoUsed || endPromptSnoozed || notesOpen()) return;
  if (Date.now() - lastActivity > CALL_IDLE_MS) $("endprompt").classList.add("show");
}, 3000);

connect();
</script>
</body>
</html>
"""#
}
