# Security

wngmn binds a local port, can be told to bind the network, holds an Anthropic credential, and
transcribes someone else's speech. This file says what it protects, what it does not, and the
things a user should know before the first real call rather than after it.

## Supported versions

| Version | Supported |
|---|---|
| `main` | yes |

There is one supported version: whatever `main` currently builds. There are no releases and
no binaries to download, so there is nothing to back-port a fix to — fixes land on `main`, and
you get them by pulling and running `swift build -c release` again. The tool requires macOS 26;
older systems are not supported, because `SpeechAnalyzer` and the Core Audio process tap it is
built on do not exist there. Development and measurement were on Apple Silicon.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository: **Security → Report a
vulnerability**. That opens an advisory only the maintainer can see, and it is the only
private channel — there is no security email address, no PGP key, no bug bounty. Please do
not open a public issue for anything that would let someone else reach a transcript, a token,
or the Anthropic credential.

What helps, in rough order of usefulness:

* The exact command line. `--listen` and `--serve` are different exposures, and `--no-log`
  changes what is on disk.
* macOS version, and whether the binary was run from a shell or from the app bundle that
  `Scripts/install.sh` builds — the two have different permission subjects.
* What you observed, and a proof of concept if you have one.

This is one person's project. Expect an acknowledgement in days rather than hours.

## Threat model

What the code is written to stop:

* **A web page in another tab acting on the tool.** A JSON body labelled `text/plain` is a
  CORS simple request, so a browser will POST it cross-origin without preflighting. Until
  that was closed, any page could pause the tap or spend the API key with your notes as the
  system prompt. `/ask` and `/control` now require `Sec-Fetch-Site: same-origin` (or a
  matching `Origin`, for a client that sends one without the fetch metadata) and a
  `Content-Type: application/json` body, which a preflight-free cross-origin POST cannot
  produce — and this server answers no preflight, because `OPTIONS` is not an allowed method.
* **DNS rebinding onto the loopback port.** Requests are rejected unless the `Host` header
  names this machine the way a real client would: `localhost` or any name ending
  `.localhost`, a four-part dotted quad whose parts all fit in a `UInt8`, an IPv6 literal in
  brackets — an unbracketed one is refused, because without brackets the port is ambiguous
  and treating a leftover colon as proof of IPv6 let `evil.example.com:8080:7373` through —
  or a `.local` name. See the limitation below for how wide that last one is.
* **Someone on the same wifi reading the transcript when `--listen` is used.** Every request
  must carry the token, compared in constant time, with an identical 403 for a missing and a
  wrong token so a prober learns nothing about which half they got right.
* **Another account on the same Mac reading the token or the transcripts.** The token file
  and every session log are written mode 0600 inside a 0700 directory.

What it is **not** a defence against, stated plainly so nobody relies on it:

* **Code already running as you.** The session logs, the token file and your notes are
  readable by anything running under your account, and on the default loopback bind the
  transcript stream itself is too. File permissions here protect you from other accounts, not
  from your own processes.
* **A compromised or hostile conferencing app, browser, or operating system.** wngmn reads
  what the machine is playing; it cannot vouch for it.
* **The contents of an answer.** Answers are model output assembled from your own prepared
  material and the transcript. Nothing checks them, and the tool has no way to.
* **Consent.** Transcribing the other party in a call may need their agreement, and in some
  places their explicit agreement, depending on where each of you is sitting. The tool does
  not ask and cannot know; that is the operator's responsibility.
* **Multi-user or shared machines.** There is one user, one token, and a UI with no notion of
  accounts. Anyone who can reach the page can do everything the owner can.

## What does not happen

* **Audio never leaves the machine.** Transcription is Apple's on-device `SpeechAnalyzer` and
  `SpeechTranscriber`. The only outbound request the binary makes is the streaming POST to
  `https://api.anthropic.com/v1/messages` in `Sources/WngmnAsk/ClaudeClient.swift`, and it
  carries text: the question, the recent transcript lines the page sent with it, and your
  profile or notes. `wngmn install-model` asks macOS to fetch a speech model through
  `AssetInventory`; that is an OS asset download, not a transmission of anything of yours.
* **No audio is written to disk.** Buffers are processed in memory and discarded. The only
  audio file the code opens is the one you hand to `wngmn offline <file>`, for reading.
* **No telemetry, no analytics, no crash reporting, no update check.** There is no other URL
  in the source.
* **No third-party dependencies.** `Package.swift` declares none. The HTTP/1.1 server, the
  SSE framing, the JSON Lines encoder and the served page are all hand-rolled, so the code
  you have to trust is this repository and Apple's frameworks.
* **The served page loads nothing from the internet** — no CDN, no web font, no remote
  script. It is embedded in the binary.
* **The server never sends `Access-Control-Allow-Origin`**, so a hostile page cannot read a
  response from it even where it can cause the request.

## Known limitations

These are real, they are known, and none of them is fixed as of this writing. They are the
reason to read this file rather than assume.

### The network surface

**On the default loopback bind there is no authentication at all.** The token is only
configured when `--listen` was passed, so on `127.0.0.1:7373` the token check in the router is
skipped entirely. Any process running as you — another CLI, a script, a browser extension
with host permissions for localhost — can `GET /events` and receive the whole question
history plus every completed answer. A hostile *web page* cannot, because no CORS header is
ever sent; the exposure is to code already running under your account. Closing it means
issuing a loopback token too, which would break the bookmarked URL that makes the tool
pleasant to use, and that trade has not been made.

**Reading is not same-origin checked; only state-changing POSTs are.** Refusing a cross-site
`GET` would break following a link to the page, so `/` and `/events` are served to any GET
that passes the `Host` check. Combined with the point above: on loopback, reading the
transcript is open to anything on the machine that can make a plain HTTP request. The POST
check also passes a caller that sends neither `Sec-Fetch-Site` nor `Origin`, since there is
then nothing to compare; browsers always send one or the other, so what that leaves open is a
non-browser client, which is already covered by the loopback point above.

**`--listen` is a trade, not a mistake.** It is listed here as exposure, and it is one, but
there is a security argument for it as well as against it. Reading the transcript on a second
device is the only way to be *certain* it is not on screen if the call is ever screen-shared:
an overlay can be excluded from capture, a browser window on the shared screen cannot. So the
choice is between putting a confidential transcript on your wifi and risking it appearing in
somebody else's recording of the meeting. The points below are what to weigh on the first
side.

**`--listen` serves plain HTTP.** The listener is built from a bare `NWParameters.tcp`; there
is no TLS and no certificate. On conference or hotel wifi the transcript, every generated
answer and the token itself cross the network unencrypted, and anyone positioned to see that
traffic can read the interview and take the token. Use it on a network you control, or tether
the phone to the Mac.

**The token rides in the URL query.** The printed URL is
`http://<host>:7373/?t=<token>`, because that is what makes it one tap on a phone. Query
strings are kept by browser history, by bookmarks that sync to a cloud account, and by the
logs of any proxy in the path. `--new-token` rotates it, at the cost of every bookmark.

**The token is a little under 40 bits.** Eight characters from a 31-symbol alphabet, roughly
850 billion possibilities — chosen deliberately short enough to type on a phone at the start
of a call, and with `0`/`O` and `1`/`l`/`I` left out so it can be read off a screen. That is
far out of reach of online guessing against a single listener, but it is not a key, and it is
the same token every run once stored (`~/Library/Application Support/wngmn/token`, mode 0600).
`--token` takes one of your own; the binary warns at startup if you give it one shorter than
16 characters. An explicit `--token` also lands in your shell history.

**Anyone holding the token can do everything the owner can**: read the whole transcript and
every answer, pause the tap and mute the microphone through `/control`, and press Ask. Each
ask starts a streaming Claude call with a 64,000-token ceiling, charged to your credential.
There is no rate limit, no cap on simultaneous asks and no spend cap, so a loop of POSTs runs
up a real bill and can saturate the key in the middle of a call.

**`/ask` trusts the question and the recent lines the client sends.** The server does not
compare them against anything it actually emitted; both go into the prompt beside your
prepared notes, and the resulting answer is broadcast to every open page and latched onto the
matching row. So whoever can POST — a local process on the loopback bind, a token holder on
the LAN — can put wording of their choosing in front of you mid-call, paid for with your
credential.

**The `Host` allow-list is wider than this machine.** It accepts *any* name ending in
`.local`, not just this Mac's Bonjour name, which leaves an mDNS-rebinding path: in a
rebinding attack the browser's origin *is* the attacker-chosen name, so the same-origin check
holds and the `Host` check is the only thing left. A request that omits `Host` altogether
skips the check, since it fires only when the header is present — browsers always send one,
so that part matters to a non-browser caller, which could just as easily send an acceptable
value.

### What is on disk

**The session log holds questions and complete model answers, and is kept indefinitely.**
With `--serve`, logging is on by default: every replayable event is appended to
`~/Library/Application Support/wngmn/sessions/<timestamp>.jsonl`, and that includes the
`answer_done` frame carrying the full answer text. Files are created mode 0600 in a 0700
directory, so another account cannot read them — but nothing ever deletes them. There is no
purge command, no age-based sweep, and `wngmn stop` does not touch sessions. A year of
confidential interviews accumulates in plaintext under your home directory. `--no-log` turns
it off (and then `--resume` cannot work); `--log-dir` puts the files somewhere you choose,
such as an encrypted volume.

**A session log is trusted input when it is replayed.** The page writes a question's `ms`
field into `innerHTML` without escaping, in both the row tag and the latency chart, while
every neighbouring field goes through the escaper; the server replays log lines from disk
verbatim. A log line whose `ms` is a string of markup therefore executes script in the page on
the next `--resume`. Reaching that requires someone who already has your account.

### Credentials

**The credential is read, never stored.** Resolution order is `ANTHROPIC_API_KEY`, then
`ANTHROPIC_AUTH_TOKEN`, then the `ant` CLI's active OAuth profile. wngmn writes no credential
to disk and keeps it only for the duration of the request.

**The `ant` fallback runs whatever `ant` your `PATH` resolves to.** It is launched through
`/usr/bin/env`, once at serve startup and again on every ask when no environment credential is
set, and its standard output is sent to Anthropic as a bearer token. An unrelated or planted
`ant` earlier on `PATH` is executed with your privileges and its output transmitted. If your
`PATH` is not entirely yours, set one of the two environment variables instead.

### What gets transcribed and sent

**Prefetch sends without a button press.** The served page has a prefetch checkbox in its
header; ticked, it asks for every caller question the moment it lands, so that question, the
recent transcript and your whole profile go to the API with no press. It is off by default and
is not remembered across page loads.

**The default tap scope is the whole of Chrome, not just the call.** The default bundle list
is `us.zoom.xos`, `us.zoom.CptHost`, `us.zoom.caphost`, `com.google.Chrome` and
`com.google.Chrome.helper`, because Meet audio comes from a helper process and which one
carries it has to be resolved rather than assumed. Anything else Chrome plays during a
session — a second tab, a video, a notification — is transcribed as the caller, written to
the log, and with prefetch on sent to the API. `--bundle-id` narrows the scope; `--global`
widens it to everything the machine plays.

**The System Audio Recording grant belongs to the parent process.** Run from a shell and the
permission is your terminal application's, which means it covers every program that terminal
launches, not only wngmn. The app bundle built by `Scripts/install.sh` is its own subject and
appears under its own name in System Settings. A denial is silent in either case: every Core
Audio call still returns `noErr` and the stream is pure digital silence, which is why
`selftest` plays a real tone and asserts the tap hears it rather than looking for an error.

### Local processes

**`wngmn stop` signals by process name.** It matches `p_comm` against exactly `wngmn` and
sends SIGTERM, then SIGKILL to anything that ignores it. An unrelated executable of yours that
happens to be called `wngmn` is killed without warning. `kill(2)` confines this to your own
processes, so it cannot reach another account.

## Licence

MIT — see [LICENSE](LICENSE). The software is provided without warranty, which is worth
reading literally in the context of the limitations above.
