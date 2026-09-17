import Foundation
import Testing
@testable import WngmnServe

/// The page is a Swift string literal, so its JavaScript is never compiled by anything on
/// the way in. A stray escape produces a page that returns 200, renders its markup, and
/// runs none of its script — the transcript simply never fills in. That failure is
/// invisible to every other test here, and was shipped once already.
@Suite("Page")
struct PageTests {
    @Test("The page's JavaScript parses", .enabled(if: PageTests.nodeIsAvailable))
    func scriptParses() throws {
        let script = try #require(PageTests.scriptBody(of: Page.html))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-page-\(UUID().uuidString).js")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "node --check rejected the page script:\n\(detail)")
    }

    @Test("The page carries the pieces the transcript view is made of")
    func hasItsElements() {
        for id in ["lines", "live", "chart", "warnings", "prefetch", "panel", "syncscroll"] {
            #expect(Page.html.contains("id=\"\(id)\""), "page is missing #\(id)")
        }
    }

    /// Elements the script wires up must be parsed before it runs.
    ///
    /// The end-of-call dialogs were once appended after `</script>`, so the `$("endYes")` at
    /// the top of the wiring returned null, the script threw there, and everything below it —
    /// including `connect()` on the last line — never ran. The page served 200 and rendered,
    /// and the transcript never filled in: the same silent failure `scriptParses` exists for,
    /// reached a different way. Nothing else here could see it. `hasItsElements` asks only
    /// whether an id is somewhere in the page, and the DOM stub the markdown tests run under
    /// hands back an element for every id, so a null lookup is exactly what it cannot model.
    @Test("No element markup trails the script that wires it up")
    func markupPrecedesTheScript() throws {
        let html = Page.html
        let close = try #require(
            html.range(of: "</script>", options: .backwards),
            "the page should have a script to begin with"
        )
        let strays = html[close.upperBound...].ranges(of: #/id="([^"]+)"/#)
            .map { String(html[$0]) }
        #expect(
            strays.isEmpty,
            """
            \(strays.count) element(s) are declared after the page's script: \
            \(strays.joined(separator: ", ")). The script looks them up as it runs, so a \
            lookup returns null and throws before connect() opens the event stream. Move \
            the markup above <script>.
            """
        )
    }

    static var nodeIsAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The contents of the page's last `<script>` element.
    static func scriptBody(of html: String) -> String? {
        guard let open = html.range(of: "<script>", options: .backwards),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
        else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }
}

/// Rendering tests for the answer panel's markdown.
///
/// `node --check` above only proves the script parses; it would happily accept a renderer
/// that emits wrong HTML. These run the page's own script under Node — with the handful of
/// browser globals it touches at load stubbed out — and assert on what `md()` actually
/// produces, so the assertions stay in Swift where the rest of the suite is.
@Suite("Answer markdown")
struct AnswerMarkdownTests {
    /// What a reader (and the copy button) sees: markup stripped, entities resolved.
    static func text(_ html: String) -> String {
        var out = ""
        var inTag = false
        for c in html {
            if c == "<" { inTag = true } else if c == ">" { inTag = false } else if !inTag { out.append(c) }
        }
        return out.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    @Test("A fenced block renders as a code block rather than list items", .enabled(if: PageTests.nodeIsAvailable))
    func rendersFencedCode() throws {
        let html = try AnswerMarkdownTests.render("""
        Here you go:

        ```python
        def canFinish(n):
            return True
        ```
        """)
        #expect(html.contains("<pre"))
        #expect(html.contains("<code"))
        #expect(AnswerMarkdownTests.text(html).contains("def canFinish(n):"))
        // The bug this whole change exists to fix: every line wrapped in <li>.
        #expect(!html.contains("<li>def canFinish"))
    }

    /// `renderAnswer` runs on every streaming delta, so a fence with no closing ``` is the
    /// normal mid-stream state. Refusing to render it would make code pop in at the end
    /// instead of growing as it arrives.
    @Test("An unclosed fence still renders while the answer is streaming", .enabled(if: PageTests.nodeIsAvailable))
    func rendersUnclosedFence() throws {
        let html = try AnswerMarkdownTests.render("""
        ```python
        from collections import deque
        """)
        #expect(html.contains("<pre"))
        #expect(AnswerMarkdownTests.text(html).contains("from collections import deque"))
    }

    @Test("Inline code and bold render as their own elements", .enabled(if: PageTests.nodeIsAvailable))
    func rendersInlineMarkup() throws {
        let html = try AnswerMarkdownTests.render("Return `true` if it is a **DAG**.")
        #expect(html.contains("<code>true</code>"))
        #expect(html.contains("<strong>DAG</strong>"))
    }

    /// Inside a fence the only pass that runs is escaping. A `**` in Python is exponentiation,
    /// not emphasis, and rewriting it would corrupt code the user is about to read out.
    @Test("Markup inside a code fence is left literal", .enabled(if: PageTests.nodeIsAvailable))
    func codeFenceIsLiteral() throws {
        let html = try AnswerMarkdownTests.render("""
        ```python
        x = 2 ** 8
        y = `not inline code`
        ```
        """)
        #expect(AnswerMarkdownTests.text(html).contains("2 ** 8"))
        #expect(!html.contains("<strong>"))
        #expect(!html.contains("<code>not inline code</code>"))
    }

    /// The answer is model output arriving over the network and written straight into
    /// innerHTML. Escaping has to happen before any tag is inserted, not after.
    @Test("HTML in an answer is escaped rather than executed", .enabled(if: PageTests.nodeIsAvailable))
    func escapesHTML() throws {
        let html = try AnswerMarkdownTests.render("Careful: <script>alert(1)</script> and <img src=x onerror=y>")
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;script&gt;"))
    }

    /// The old renderer's one real job. Bullets are still what most answers are made of.
    @Test("Bullet lists still render as list items", .enabled(if: PageTests.nodeIsAvailable))
    func rendersBullets() throws {
        let html = try AnswerMarkdownTests.render("- first point\n- second point")
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>first point</li>"))
        #expect(html.contains("<li>second point</li>"))
    }

    /// Observed in a live answer: `**when *N* changes**` rendered with literal asterisks,
    /// because the bold pattern refused to span the italic inside it.
    @Test("Bold containing italic renders as both, not as literal asterisks", .enabled(if: PageTests.nodeIsAvailable))
    func nestedEmphasis() throws {
        let html = try AnswerMarkdownTests.render("a fatal flaw: **when *N* changes, keys move.**")
        #expect(!html.contains("**"))
        #expect(html.contains("<strong>"))
        #expect(html.contains("<em>N</em>"))
    }

    /// Observed in a real answer: a document with `#`, `##` and `###` rendered as three
    /// identical 11px grey labels, so a structured answer read as one flat wall of text.
    @Test("Heading levels stay distinct from each other", .enabled(if: PageTests.nodeIsAvailable))
    func headingLevelsAreDistinct() throws {
        let html = try AnswerMarkdownTests.render("# Title\n\n## Step one\n\n### Detail")
        #expect(html.contains("<h3>Title</h3>"))
        #expect(html.contains("<h4>Step one</h4>"))
        #expect(html.contains("<h5>Detail</h5>"))
    }

    @Test("A fence carries its language and a copy button", .enabled(if: PageTests.nodeIsAvailable))
    func fenceCarriesLanguageAndCopy() throws {
        let html = try AnswerMarkdownTests.render("```python\nx = 1\n```")
        #expect(html.contains("python"))
        #expect(html.contains("copy"))
    }

    /// Observed in a real answer: a `---` separator between sections rendered as literal
    /// text in the middle of the panel.
    @Test("A thematic break renders as a rule rather than literal dashes", .enabled(if: PageTests.nodeIsAvailable))
    func rendersThematicBreak() throws {
        let html = try AnswerMarkdownTests.render("before\n\n---\n\nafter")
        #expect(html.contains("<hr>"))
        #expect(!html.contains("<p>---</p>"))
    }

    /// Observed in a real answer: a design-comparison table collapsed into one run-on
    /// paragraph of pipes, which was the least readable thing on the page.
    @Test("A pipe table renders as a table", .enabled(if: PageTests.nodeIsAvailable))
    func rendersTable() throws {
        let html = try AnswerMarkdownTests.render("""
        | Algorithm | Memory | Burst |
        |---|---|---|
        | Token bucket | O(1) | configurable |
        | Leaky bucket | O(queue) | smooths |
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>Algorithm</th>"))
        #expect(html.contains("<td>Token bucket</td>"))
        #expect(html.contains("<td>O(queue)</td>"))
        #expect(!html.contains("<p>| Algorithm"))
    }

    /// Prose legitimately contains pipes ("a | b in the shell"). Only a header followed by a
    /// separator row makes a table, so ordinary text is never restructured.
    @Test("Pipes without a separator row stay prose", .enabled(if: PageTests.nodeIsAvailable))
    func pipesWithoutSeparatorStayProse() throws {
        let html = try AnswerMarkdownTests.render("Run | grep to filter | the output.")
        #expect(!html.contains("<table>"))
        #expect(html.contains("<p>"))
    }

    @Test("Cells carry inline markup", .enabled(if: PageTests.nodeIsAvailable))
    func tableCellsCarryInlineMarkup() throws {
        let html = try AnswerMarkdownTests.render("""
        | Option | Cost |
        |---|---|
        | **Token bucket** | `O(1)` |
        """)
        #expect(html.contains("<td><strong>Token bucket</strong></td>"))
        #expect(html.contains("<td><code>O(1)</code></td>"))
    }

    /// Alignment colons are valid separator syntax; the table must not fall apart on them.
    @Test("An aligned separator row is still a table", .enabled(if: PageTests.nodeIsAvailable))
    func alignedSeparatorIsATable() throws {
        let html = try AnswerMarkdownTests.render("| A | B |\n|:---|---:|\n| 1 | 2 |")
        #expect(html.contains("<table>"))
        #expect(html.contains("<td>1</td>"))
    }

    /// Mid-stream the body rows have not arrived yet. The header must render rather than
    /// sitting as raw pipes until the last row lands.
    @Test("A header and separator alone already render as a table", .enabled(if: PageTests.nodeIsAvailable))
    func headerOnlyTableRenders() throws {
        let html = try AnswerMarkdownTests.render("| A | B |\n|---|---|")
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>A</th>"))
    }

    /// Runs the page script under Node and returns what `md()` made of `source`.
    static func render(_ source: String) throws -> String {
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        return try PageTests.evaluate("md(\(encoded))")
    }
}

extension PageTests {
    /// Runs the page's own script under Node with the browser globals it touches at load
    /// stubbed, evaluates `expression`, and returns what it printed. Lets the page's pure
    /// helpers be asserted on from Swift without a browser.
    static func evaluate(_ expression: String) throws -> String {
        let script = try #require(PageTests.scriptBody(of: Page.html))
        // Node exits when its event loop empties, and the page arms a 3 s `setInterval` on its
        // last line but one, so the loop never empties: `waitUntilExit()` below blocked for as
        // long as anyone let it, leaking one `node` per call — 34 were found alive from earlier
        // runs, and one `swift test --filter Page` sat for 30 minutes before it was killed. The
        // stubs cannot prevent it by returning null from `getElementById`, because they
        // deliberately hand back an element for every id.
        //
        // So the answer is flushed and the process is then ended explicitly, rather than waiting
        // for a load-time handle to be released. The deadline is the second half of that: a
        // future handle that outlives the write — a socket, an unresolved promise — fails this
        // loudly in 15 s instead of hanging the suite with no output at all.
        let harness = Self.stubs + "\n" + script + """

        setTimeout(() => {
          process.stderr.write("harness: the page script was still running after 15 s\\n");
          process.exit(3);
        }, 15000);
        process.stdout.write(String(\(expression)), () => process.exit(0));

        """

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-page-\(UUID().uuidString).js")
        try harness.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", file.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let detail = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "node failed to run the page script:\n\(detail)")
        return printed
    }
}

/// Keyboard navigation of the transcript.
///
/// The index arithmetic is kept in a pure `nextSelection` so the clamping rules can be
/// asserted here; only the DOM wiring around it needs a browser.
@Suite("Keyboard selection")
struct KeyboardSelectionTests {
    @Test("With nothing selected, j selects the newest question", .enabled(if: PageTests.nodeIsAvailable))
    func startsAtNewest() throws {
        #expect(try PageTests.evaluate("nextSelection(-1, 5, 1)") == "4")
        #expect(try PageTests.evaluate("nextSelection(-1, 5, -1)") == "4")
    }

    @Test("k moves to the older question, j back to the newer", .enabled(if: PageTests.nodeIsAvailable))
    func movesThroughTheList() throws {
        #expect(try PageTests.evaluate("nextSelection(4, 5, -1)") == "3")
        #expect(try PageTests.evaluate("nextSelection(3, 5, 1)") == "4")
    }

    /// Clamping rather than wrapping: a transcript is read top to bottom, and silently
    /// jumping from the newest question to the oldest would lose the reader's place.
    @Test("Selection clamps at both ends rather than wrapping", .enabled(if: PageTests.nodeIsAvailable))
    func clampsAtTheEnds() throws {
        #expect(try PageTests.evaluate("nextSelection(4, 5, 1)") == "4")
        #expect(try PageTests.evaluate("nextSelection(0, 5, -1)") == "0")
    }

    @Test("An empty transcript has nothing to select", .enabled(if: PageTests.nodeIsAvailable))
    func emptyListSelectsNothing() throws {
        #expect(try PageTests.evaluate("nextSelection(-1, 0, 1)") == "-1")
    }
}

extension PageTests {
    /// The browser surface the script touches at load: `$("lines")`/`$("live")` at the top,
    /// `window.addEventListener` for the chart, and `connect()`'s EventSource at the bottom.
    static let stubs = """
    function stubEl(id) {
      const el = {
        id: id || "",
        textContent: "", innerHTML: "", hidden: false, disabled: false, className: "",
        classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
        style: { setProperty() {}, removeProperty() {}, getPropertyValue() { return ""; } },
        dataset: {},
        // Recorded rather than dropped, so a test can find the listener the page attached
        // to an element and press it.
        listeners: [],
        setPointerCapture() {}, releasePointerCapture() {}, hasPointerCapture() { return false; },
        addEventListener(type, fn) { el.listeners.push({ type, fn }); }, removeEventListener() {},
        setAttribute() {}, getAttribute() { return null; },
        getBoundingClientRect() { return { width: 0, height: 0, top: 0, left: 0 }; },
        scrollIntoView() {},
        appendChild() {}, removeChild() {}, remove() {}, insertAdjacentHTML() {},
        replaceWith() {}, prepend() {}, children: [],
        querySelector() { return stubEl(); }, querySelectorAll() { return []; },
        closest() { return null; },
      };
      return el;
    }
    // One element per id, as in a document: what the page wired up at load is what a test
    // gets back when it asks for the same id.
    const elementsByID = {};
    globalThis.document = {
      getElementById(id) { return elementsByID[id] || (elementsByID[id] = stubEl(id)); },
      createElement() { return stubEl(); },
      querySelector() { return stubEl(); }, querySelectorAll() { return []; },
      addEventListener() {}, body: stubEl("body"),
    };
    globalThis.window = {
      addEventListener() {}, location: { search: "" },
      matchMedia() { return { matches: globalThis.__mobile === true, addEventListener() {} }; },
    };
    // Defined rather than assigned: Node ships a read-only `navigator` of its own, and a
    // plain assignment to it fails silently, leaving the page's clipboard call nothing.
    Object.defineProperty(globalThis, "navigator", {
      value: { clipboard: { writeText: async () => {} } }, configurable: true, writable: true,
    });
    globalThis.EventSource = class { close() {} addEventListener() {} };
    """
}

/// Which row a `revises` line replaces.
///
/// With one source that is simply the last question. With two it must not be: the caller
/// pausing mid-question while you say "mm-hm" in the gap would otherwise have the caller's
/// revision overwrite your line.
@Suite("Speaker revisions")
struct SpeakerRevisionTests {
    static let mixed = """
    [{speaker:"caller"},{speaker:"you"},{speaker:"caller"},{speaker:"you"}]
    """

    @Test("A revision replaces the last row from the same speaker", .enabled(if: PageTests.nodeIsAvailable))
    func perSpeaker() throws {
        #expect(try PageTests.evaluate("lastIndexForSpeaker(\(Self.mixed), 'caller')") == "2")
        #expect(try PageTests.evaluate("lastIndexForSpeaker(\(Self.mixed), 'you')") == "3")
    }

    /// Single-source output carries no speaker at all, and must behave exactly as before.
    @Test("With no speaker the last row is the target", .enabled(if: PageTests.nodeIsAvailable))
    func singleSourceUnchanged() throws {
        #expect(try PageTests.evaluate("lastIndexForSpeaker([{},{},{}], undefined)") == "2")
    }

    @Test("A speaker with no rows yet revises nothing", .enabled(if: PageTests.nodeIsAvailable))
    func noMatch() throws {
        #expect(try PageTests.evaluate("lastIndexForSpeaker([{speaker:'caller'}], 'you')") == "-1")
        #expect(try PageTests.evaluate("lastIndexForSpeaker([], 'caller')") == "-1")
    }
}

/// The page learns the capture state from a `control` status line, so a second viewer
/// (a phone propped beside the laptop) reflects a mute made on the first.
/// Copying the meeting notes.
///
/// The clipboard call itself needs a browser and goes untested, as the DOM wiring does. What
/// is asserted here is the part that decides *what* would be copied and *when* the button is
/// offered, which is ordinary logic and belongs in Swift with the rest.
@Suite("Notes copy")
struct NotesCopyTests {
    @Test("The clipboard gets the markdown, not the rendered markup")
    func copiesTheSource() throws {
        // The same choice the code blocks make: the source is what is useful to paste.
        let source = "## Decisions\\n\\n- Ship it"
        let got = try PageTests.evaluate(
            "(() => { showNotes(md(\"\(source)\"), \"\(source)\"); return notesSource; })()"
        )
        #expect(got == "## Decisions\n\n- Ship it")
        #expect(!got.contains("<h2>"), "the rendered markup must not reach the clipboard")
    }

    @Test("Notes that arrived offer the button")
    func shownWhenThereAreNotes() throws {
        let hidden = try PageTests.evaluate(
            "(() => { showNotes(md(\"# Notes\"), \"# Notes\"); return document.getElementById(\"notesCopy\").hidden; })()"
        )
        #expect(hidden == "false")
    }

    /// "Writing notes…" and a failure are both rendered through `showNotes`, and neither has
    /// anything worth putting on the clipboard.
    @Test("A pending or failed summary offers nothing to copy")
    func hiddenWhileThereIsNothingToCopy() throws {
        let pending = try PageTests.evaluate(
            "(() => { showNotes('<div class=\"pending\">Writing notes…</div>'); "
            + "return document.getElementById(\"notesCopy\").hidden + \"/\" + notesSource.length; })()"
        )
        #expect(pending == "true/0")
    }

    /// The label is the only feedback there is, so a second copy has to start from "copy"
    /// rather than from the "copied" the last one left behind.
    @Test("Reopening the notes resets the button's label")
    func labelResets() throws {
        let label = try PageTests.evaluate(
            "(() => { const b = document.getElementById(\"notesCopy\"); b.textContent = \"copied\"; "
            + "showNotes(md(\"# Notes\"), \"# Notes\"); return b.textContent; })()"
        )
        #expect(label == "copy")
    }

    @Test("The page carries the button")
    func pageCarriesTheButton() {
        #expect(Page.html.contains("id=\"notesCopy\""))
    }
}

@Suite("Control state")
struct ControlStateTests {
    @Test("Both flags are read from the status detail", .enabled(if: PageTests.nodeIsAvailable))
    func parsesBoth() throws {
        #expect(
            try PageTests.evaluate("JSON.stringify(parseControlDetail('mic=muted tap=paused'))")
                == #"{"mic":"muted","tap":"paused"}"#
        )
        #expect(
            try PageTests.evaluate("JSON.stringify(parseControlDetail('mic=live tap=listening'))")
                == #"{"mic":"live","tap":"listening"}"#
        )
    }

    @Test("The auto flag is read alongside mic and tap", .enabled(if: PageTests.nodeIsAvailable))
    func parsesAuto() throws {
        #expect(
            try PageTests.evaluate("JSON.stringify(parseControlDetail('mic=live tap=listening auto=on'))")
                == #"{"mic":"live","tap":"listening","auto":"on"}"#
        )
        #expect(
            try PageTests.evaluate("parseControlDetail('mic=live tap=listening auto=off').auto") == "off"
        )
    }

    /// A detail that carries neither flag must leave the buttons alone rather than reset
    /// them to a default the machine never reported.
    @Test("An unrelated detail changes nothing", .enabled(if: PageTests.nodeIsAvailable))
    func ignoresUnrelated() throws {
        #expect(try PageTests.evaluate("JSON.stringify(parseControlDetail('something else'))") == "{}")
        #expect(try PageTests.evaluate("JSON.stringify(parseControlDetail(undefined))") == "{}")
    }
}


/// Scroll position shared between devices.
///
/// Synced as an anchor — which question is at the top of the viewport and how far into it —
/// rather than as `scrollTop`. A phone and a laptop render the same transcript at different
/// heights, so a pixel offset from one means nothing on the other.
@Suite("Scroll sync")
struct ScrollSyncTests {
    /// Rows are (top, height) in the scroller's coordinate space.
    static let rows = "[{top:0,height:100},{top:100,height:200},{top:300,height:150}]"

    @Test("The anchor is the row under the top of the viewport", .enabled(if: PageTests.nodeIsAvailable))
    func picksTheTopRow() throws {
        #expect(try PageTests.evaluate("scrollAnchor(\(Self.rows), 0).index") == "0")
        #expect(try PageTests.evaluate("scrollAnchor(\(Self.rows), 150).index") == "1")
        #expect(try PageTests.evaluate("scrollAnchor(\(Self.rows), 320).index") == "2")
    }

    /// How far into that row, so the two devices land on the same line of text rather than
    /// merely the same question.
    @Test("The fraction into the row is carried too", .enabled(if: PageTests.nodeIsAvailable))
    func carriesFraction() throws {
        #expect(try PageTests.evaluate("scrollAnchor(\(Self.rows), 200).into") == "0.5")
        #expect(try PageTests.evaluate("scrollAnchor(\(Self.rows), 100).into") == "0")
    }

    /// The receiving device recomputes from its own layout, which is the whole point: the
    /// same anchor lands at a different pixel offset on a narrower screen.
    @Test("Applying an anchor uses the receiver's own geometry", .enabled(if: PageTests.nodeIsAvailable))
    func appliesInReceiverGeometry() throws {
        // Same anchor, a layout where every row is twice as tall.
        let tall = "[{top:0,height:200},{top:200,height:400},{top:600,height:300}]"
        #expect(try PageTests.evaluate("scrollOffsetFor(\(tall), {index:1, into:0.5})") == "400")
        #expect(try PageTests.evaluate("scrollOffsetFor(\(Self.rows), {index:1, into:0.5})") == "200")
    }

    @Test("An anchor past the end clamps instead of throwing", .enabled(if: PageTests.nodeIsAvailable))
    func clampsOutOfRange() throws {
        // Clamped to the last row, with the fraction kept: halfway into a row of 150 at
        // top 300 is 375. Landing on the row's top instead would jump the reader.
        #expect(try PageTests.evaluate("scrollOffsetFor(\(Self.rows), {index:99, into:0.5})") == "375")
        #expect(try PageTests.evaluate("scrollOffsetFor([], {index:0, into:0})") == "0")
    }
}


/// The draggable split between the answer stage and the transcript.
@Suite("Split pane")
struct SplitPaneTests {
    /// A drag is a pointer position, which can land anywhere including outside the window.
    /// Unclamped, one overshoot collapses a pane to nothing and there is no longer a gutter
    /// left on screen wide enough to drag back.
    @Test("A drag is clamped so neither pane can be lost", .enabled(if: PageTests.nodeIsAvailable))
    func clampsToUsableRange() throws {
        #expect(try PageTests.evaluate("clampSplit(-40)") == "30")
        #expect(try PageTests.evaluate("clampSplit(0)") == "30")
        #expect(try PageTests.evaluate("clampSplit(140)") == "80")
        #expect(try PageTests.evaluate("clampSplit(100)") == "80")
    }

    @Test("Ordinary positions pass through", .enabled(if: PageTests.nodeIsAvailable))
    func passesThroughUsableValues() throws {
        #expect(try PageTests.evaluate("clampSplit(65)") == "65")
        #expect(try PageTests.evaluate("clampSplit(30)") == "30")
        #expect(try PageTests.evaluate("clampSplit(80)") == "80")
    }

    /// A pointer x of NaN reaches this if the gutter is dragged before layout settles;
    /// writing NaN into the grid template silently collapses the whole layout.
    @Test("A non-finite position falls back to the default", .enabled(if: PageTests.nodeIsAvailable))
    func rejectsNonFinite() throws {
        #expect(try PageTests.evaluate("clampSplit(NaN)") == "65")
        #expect(try PageTests.evaluate("clampSplit(undefined)") == "65")
    }
}


/// Syntax highlighting inside fenced code blocks.
///
/// Hand-rolled because the page loads nothing from the internet — a CDN highlighter would
/// simply fail on a machine with no network, which is a stated property of this tool.
@Suite("Syntax highlighting")
struct HighlightTests {
    func hl(_ code: String, _ lang: String) throws -> String {
        let c = String(decoding: try JSONEncoder().encode(code), as: UTF8.self)
        let l = String(decoding: try JSONEncoder().encode(lang), as: UTF8.self)
        return try PageTests.evaluate("highlight(\(c), \(l))")
    }

    @Test("Keywords, strings, numbers and comments are marked up", .enabled(if: PageTests.nodeIsAvailable))
    func marksTokens() throws {
        let html = try hl("def allow(n):\n    # limit\n    return n < 10", "python")
        #expect(html.contains("<span class=\"t-kw\">def</span>"))
        #expect(html.contains("<span class=\"t-com\"># limit</span>"))
        #expect(html.contains("<span class=\"t-num\">10</span>"))
    }

    /// A keyword inside a string is text, not a keyword. Getting this wrong is the usual
    /// failure of a naive word-replacement highlighter and it corrupts the code on screen.
    @Test("Keywords inside strings and comments are left alone", .enabled(if: PageTests.nodeIsAvailable))
    func doesNotHighlightInsideLiterals() throws {
        let inString = try hl("x = \"def return if\"", "python")
        #expect(!inString.contains("t-kw"), "keyword markup leaked into a string: \(inString)")
        let inComment = try hl("# def return if", "python")
        #expect(!inComment.contains("t-kw"), "keyword markup leaked into a comment: \(inComment)")
    }

    /// The whole reason this is dangerous: the code is model output being written into
    /// innerHTML, and highlighting inserts tags into it. Escaping has to survive that.
    @Test("HTML in code is still escaped after highlighting", .enabled(if: PageTests.nodeIsAvailable))
    func escapesHtmlInCode() throws {
        let html = try hl("const x = \"<script>alert(1)</script>\";", "javascript")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test("An unknown language is escaped and left plain", .enabled(if: PageTests.nodeIsAvailable))
    func unknownLanguageIsPlain() throws {
        let html = try hl("def <b>x</b> return", "brainfuck")
        #expect(!html.contains("t-kw"))
        #expect(html.contains("&lt;b&gt;"))
    }

    /// The copy button reads textContent off the <code>, so the markup must not change what
    /// a reader would paste.
    @Test("Markup adds no characters to the source", .enabled(if: PageTests.nodeIsAvailable))
    func preservesSourceText() throws {
        let source = "def allow(n):\n    return n < 10  # ok"
        let stripped = try PageTests.evaluate(
            "highlight(\(String(decoding: try JSONEncoder().encode(source), as: UTF8.self)), 'python')"
            + ".replace(/<[^>]*>/g, '').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&')")
        #expect(stripped == source)
    }

    @Test("Common aliases resolve to the same language", .enabled(if: PageTests.nodeIsAvailable))
    func resolvesAliases() throws {
        for alias in ["py", "python3"] {
            #expect(try hl("def f():", alias).contains("t-kw"), "\(alias) was not recognised")
        }
        for alias in ["js", "ts", "typescript"] {
            #expect(try hl("const x = 1", alias).contains("t-kw"), "\(alias) was not recognised")
        }
    }
}

/// The phone layout: two panes taking turns, with the live caption outside both.
///
/// A phone has room for one pane, not two. What the tabs would otherwise cost is the live
/// caption — the only thing on the page with a deadline — so the rules about what stays
/// visible, and what the caption's Ask button points at, are the part worth pinning down.
@Suite("Mobile panes")
struct MobilePaneTests {
    @Test("The page carries the tab bar and the caption's Ask button")
    func hasItsElements() {
        for id in ["tabs", "tabAnswer", "tabTranscript", "unseen", "peekAsk"] {
            #expect(Page.html.contains("id=\"\(id)\""), "page is missing #\(id)")
        }
    }

    /// The caption shows the newest line's text, so its button has to point at that same
    /// line whether or not it has been answered — a button that vanished once the line was
    /// answered would leave the text stranded with no way back to the answer it has.
    @Test("The caption targets the newest question", .enabled(if: PageTests.nodeIsAvailable))
    func peekTargetsNewest() throws {
        #expect(try PageTests.evaluate("peekTarget([{t0:1},{t0:2}]).t0") == "2")
        #expect(try PageTests.evaluate("peekTarget([{t0:1},{t0:2,asked:true}]).t0") == "2")
        #expect(try PageTests.evaluate("String(peekTarget([]))") == "null")
    }

    /// The button says what pressing it does. `ask` will not spend a second call on a
    /// question that already has an answer, so on an answered line it only brings it back.
    @Test("The button reads Ask before an answer and View after", .enabled(if: PageTests.nodeIsAvailable))
    func buttonLabelFollowsTheAnswer() throws {
        let phone = "globalThis.__mobile = true, questions.length = 0, "
        #expect(try PageTests.evaluate(
            "(\(phone) questions.push({text:'x'}), renderPeek(), peekAsk.textContent)") == "Ask")
        #expect(try PageTests.evaluate(
            "(\(phone) questions.push({text:'x', asked:true}), renderPeek(), peekAsk.textContent)") == "View")
        #expect(try PageTests.evaluate(
            "(globalThis.__mobile = false, questions.length = 0, questions.push({text:'x'}),"
            + " renderPeek(), String(peekAsk.hidden))") == "true")
    }

    /// Going blank between sentences was the reported bug. On a phone the transcript sits
    /// behind a tab, so an empty caption beside an Ask button gave no clue what Ask would
    /// ask — the line it referred to had just scrolled into the other pane.
    @Test("The caption falls back to the last thing said", .enabled(if: PageTests.nodeIsAvailable))
    func captionKeepsTheLastLine() throws {
        #expect(try PageTests.evaluate(
            "(partialText = 'how would you', renderCaption(), live.innerHTML)")
            .contains("how would you"))
        #expect(try PageTests.evaluate(
            "(partialText = '', questions.length = 0,"
            + " questions.push({text:'Design a rate limiter.'}), renderCaption(), live.innerHTML)")
            .contains("Design a rate limiter."))
    }

    /// Speech in progress outranks it: the partial is the newer information.
    @Test("A partial in progress wins over the last question", .enabled(if: PageTests.nodeIsAvailable))
    func partialWins() throws {
        let html = try PageTests.evaluate(
            "(questions.length = 0, questions.push({text:'Design a rate limiter.'}),"
            + " partialText = 'and what happens if', renderCaption(), live.innerHTML)")
        #expect(html.contains("and what happens if"))
        #expect(!html.contains("Design a rate limiter."))
    }

    @Test("With nothing said yet the caption is just the cursor", .enabled(if: PageTests.nodeIsAvailable))
    func captionStartsEmpty() throws {
        #expect(try PageTests.evaluate(
            "(partialText = '', questions.length = 0, renderCaption(), live.innerHTML)")
            == "<span class=\"cursor\"></span>")
    }

    /// "Seen" means looked at, not asked and not elapsed: the badge is there to say
    /// something arrived while you were reading, so only opening the transcript clears it.
    @Test("Arrivals count only while the transcript is hidden", .enabled(if: PageTests.nodeIsAvailable))
    func unseenCounting() throws {
        #expect(try PageTests.evaluate("bumpUnseen(0, false)") == "1")
        #expect(try PageTests.evaluate("bumpUnseen(3, false)") == "4")
        #expect(try PageTests.evaluate("bumpUnseen(3, true)") == "0")
    }

    @Test("Opening the transcript clears the badge", .enabled(if: PageTests.nodeIsAvailable))
    func openingClearsTheBadge() throws {
        #expect(try PageTests.evaluate(
            "(unseen = 4, setPane('transcript'), unseen)") == "0")
        #expect(try PageTests.evaluate(
            "(setPane('transcript'), document.body.dataset.pane)") == "transcript")
    }

    /// Asking from the transcript and then having to find the Answer tab yourself would put
    /// a manual step between the tap and the thing the tap was for.
    @Test("Putting a question on the stage follows it to the answer", .enabled(if: PageTests.nodeIsAvailable))
    func activateFollowsToTheAnswer() throws {
        #expect(try PageTests.evaluate(
            "(globalThis.__mobile = true, setPane('transcript'),"
            + " activate({text:'x', t0:1}), document.body.dataset.pane)") == "answer")
    }

    /// On a desktop both panes are already on screen, so switching one out from under the
    /// reader would be a regression rather than a convenience.
    @Test("On a wide screen nothing switches panes", .enabled(if: PageTests.nodeIsAvailable))
    func wideScreenDoesNotSwitch() throws {
        #expect(try PageTests.evaluate(
            "(setPane('transcript'), activate({text:'x', t0:1}), document.body.dataset.pane)")
            == "transcript")
    }
}

/// Applying the same event twice must leave the page in the same state as applying it once.
///
/// A reconnecting page is caught up from a replay buffer, and a replay that overlaps what
/// it already has is normal rather than exceptional — the server cannot know exactly what
/// reached a socket before it dropped. Without this, one Safari tab suspension turns every
/// question in the transcript into two.
@Suite("Replay is idempotent")
struct ReplayIdempotenceTests {
    /// `t0` is the start of the speech and survives revision, so it identifies a question
    /// across a reconnect where an array index would not.
    @Test("The same question arriving twice makes one row", .enabled(if: PageTests.nodeIsAvailable))
    func duplicateQuestionIsCollapsed() throws {
        let feed = "(questions.length = 0,"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller'}),"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller'}),"
            + " questions.length)"
        #expect(try PageTests.evaluate(feed) == "1")
    }

    /// Same instant, different speaker, is two people talking over each other — not a
    /// duplicate. The key has to carry the speaker or the mic's line eats the caller's.
    @Test("Two speakers at the same instant stay separate", .enabled(if: PageTests.nodeIsAvailable))
    func sameInstantDifferentSpeaker() throws {
        let feed = "(questions.length = 0,"
            + " addQuestion({text:'Go ahead.', t0:152, ms:40, speaker:'caller'}),"
            + " addQuestion({text:'Sure.', t0:152, ms:40, speaker:'you'}),"
            + " questions.length)"
        #expect(try PageTests.evaluate(feed) == "2")
    }

    /// A replayed duplicate must not discard an answer already streamed into the page.
    @Test("A duplicate does not wipe an answer already held", .enabled(if: PageTests.nodeIsAvailable))
    func duplicateKeepsTheAnswer() throws {
        let feed = "(questions.length = 0,"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller'}),"
            + " questions[0].asked = true, questions[0].answer = 'Token bucket.',"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller'}),"
            + " questions[0].answer)"
        #expect(try PageTests.evaluate(feed) == "Token bucket.")
    }

    /// The revision path is how a question legitimately changes text, and it is keyed on
    /// speaker rather than on `t0`, so it must keep working alongside the dedupe.
    @Test("A revision still replaces rather than duplicating", .enabled(if: PageTests.nodeIsAvailable))
    func revisionStillReplaces() throws {
        let feed = "(questions.length = 0,"
            + " addQuestion({text:'Design a rate', t0:152, ms:40, speaker:'caller'}),"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller', revises:true}),"
            + " questions.length + ':' + questions[0].text)"
        #expect(try PageTests.evaluate(feed) == "1:Design a rate limiter.")
    }
}

/// List and fence handling, at the fidelity someone reading an answer out loud needs.
///
/// These are not cosmetic. The answer is read aloud under time pressure, so a step numbered
/// 3 that renders as "1." makes the reader say the wrong number, and a fence that fails to
/// close swallows the prose after it.
@Suite("Answer structure")
struct AnswerStructureTests {
    static func render(_ src: String) throws -> String {
        try PageTests.evaluate("md(\(String(decoding: try JSONEncoder().encode(src), as: UTF8.self)))")
    }

    /// A numbered list interrupted by a paragraph resumes at its own number rather than
    /// restarting. The browser numbers an <ol> from 1 unless told otherwise, so the source's
    /// numbering has to be carried across.
    @Test("An interrupted numbered list keeps counting", .enabled(if: PageTests.nodeIsAvailable))
    func interruptedOrderedList() throws {
        let html = try Self.render("""
        1. Clarify requirements
        2. Estimate scale

        Then pick an algorithm.

        3. Design the API
        4. Handle failure
        """)
        #expect(html.contains("<ol start=\"3\">"),
                "the second half restarts at 1 for the reader:\n\(html)")
    }

    @Test("A list that starts at a number other than one says so", .enabled(if: PageTests.nodeIsAvailable))
    func listStartingLate() throws {
        #expect(try Self.render("5. Shard it\n6. Rebalance").contains("<ol start=\"5\">"))
        // The ordinary case must stay free of the attribute.
        #expect(try Self.render("1. First\n2. Second").contains("<ol>"))
    }

    /// Sub-steps flattened into the parent are not a formatting nit: they are presented to
    /// the reader as top-level steps, and they renumber the ones that follow.
    @Test("Indented items nest instead of flattening", .enabled(if: PageTests.nodeIsAvailable))
    func nestedList() throws {
        let html = try Self.render("""
        1. Clarify
           1. Throughput
           2. Key cardinality
        2. Estimate
        """)
        #expect(html.contains("<ol><li>Clarify<ol>") || html.contains("<li>Clarify</li><ol>")
                || html.range(of: "Clarify.*<ol>", options: .regularExpression) != nil,
                "sub-steps were flattened into the parent list:\n\(html)")
        // Four top-level items would mean the nesting was lost entirely.
        let topLevel = html.components(separatedBy: "<li>").count - 1
        #expect(topLevel == 4, "expected 4 items in total across both levels, got \(topLevel)")
    }

    /// Models write `” ```python title=x ” ` and `” ```js {1,3} ” `. CommonMark takes the first
    /// word as the language and ignores the rest; refusing the line entirely means the code
    /// renders as literal backticks AND the closing fence opens a new block that eats the
    /// prose after it.
    @Test("A fence with extra words after the language still opens", .enabled(if: PageTests.nodeIsAvailable))
    func fenceWithInfoString() throws {
        let html = try Self.render("""
        ```python title=limiter.py
        x = 1
        ```
        And then we shard it.
        """)
        #expect(html.contains("<span class=\"lang\">python</span>"), "language not picked up:\n\(html)")
        #expect(html.contains("<p>And then we shard it.</p>"),
                "prose after the fence was swallowed into the code block:\n\(html)")
        #expect(!html.contains("```"), "backticks rendered literally:\n\(html)")
    }
}

/// Rendering edges that survive to the screen intact rather than mangled.
@Suite("Answer rendering edges")
struct AnswerRenderingEdgeTests {
    static func render(_ src: String) throws -> String {
        try PageTests.evaluate("md(\(String(decoding: try JSONEncoder().encode(src), as: UTF8.self)))")
    }

    /// `####` maps to h6, which had no style of its own and so arrived as the browser
    /// default: smaller than the body text it introduces, which reads as an accident.
    @Test("Every heading level an answer can reach is styled")
    func everyHeadingLevelIsStyled() {
        for level in 3...6 {
            #expect(Page.html.contains(".answer h\(level)"), "h\(level) has no style of its own")
        }
    }

    /// A row with a stray pipe added a column to the whole table rather than to itself,
    /// because each row was emitted with however many cells it happened to contain.
    @Test("A ragged table row does not add a column", .enabled(if: PageTests.nodeIsAvailable))
    func raggedTableRow() throws {
        let html = try Self.render("""
        | Approach | Burst |
        | --- | --- |
        | Token bucket | yes | oops |
        | Fixed window | no |
        """)
        let header = html.components(separatedBy: "<th>").count - 1
        #expect(header == 2)
        for row in html.components(separatedBy: "<tr>").dropFirst(2) {
            let cells = row.components(separatedBy: "<td>").count - 1
            if cells > 0 { #expect(cells == header, "a body row has \(cells) cells, header has \(header)") }
        }
    }

    /// `inlineMd` lifts code spans out behind a U+0000 sentinel. A NUL already in the text
    /// collided with it and threw, and a throw in `renderAnswer` means the panel never
    /// paints at all — the whole answer lost to one stray byte.
    @Test("A NUL in the answer does not stop it rendering", .enabled(if: PageTests.nodeIsAvailable))
    func nulInAnswer() throws {
        // Every shape the sentinel could collide with: beside a span, inside one, and
        // imitating the numbered placeholder the lifter writes.
        for source in ["A limiter\u{0000} with `tokens` in it",
                       "`a\u{0000}b` and `c`",
                       "\u{0000}0\u{0000} literal and `real`",
                       "`one` \u{0000}1\u{0000} `two`"] {
            let html = try Self.render(source)
            #expect(!html.isEmpty, "rendering produced nothing for \(source.debugDescription)")
            #expect(!html.contains("\u{0000}"), "a sentinel leaked into the output: \(html)")
        }
    }

    /// The tooltip escaped the text and then cut it to 80 characters, so the cut could land
    /// inside `&quot;` and leave `&quo` — invalid markup built from valid escaping.
    @Test("The chart tooltip truncates before escaping, not after")
    func tooltipTruncatesFirst() {
        #expect(Page.html.contains("esc(d.text.slice(0, 80))"),
                "the chart tooltip still escapes before it truncates")
    }
}

/// Answer frames arriving on a page whose stage is empty, and the stage's own controls.
///
/// `applyAnswer` used to claim the stage for the first frame and return before applying
/// that frame's payload. A page that reconnected and was replayed a finished answer showed
/// "Asking…" for good, a live answer lost its first token, and a failure was never shown.
@Suite("Answer frames")
struct AnswerFrameTests {
    static let question =
        "addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller'})"

    @Test("A replayed finished answer lands on an empty stage", .enabled(if: PageTests.nodeIsAvailable))
    func replayedAnswerLands() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer_done', key:'caller@152', text:'Token bucket.'}),"
            + " questions[0].answer)"
        #expect(try PageTests.evaluate(feed) == "Token bucket.")
    }

    @Test("The first streamed token is kept when nothing is on the stage", .enabled(if: PageTests.nodeIsAvailable))
    func firstTokenKept() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer', key:'caller@152', text:'Token'}),"
            + " applyAnswer({type:'answer', key:'caller@152', text:' bucket.'}),"
            + " questions[0].answer)"
        #expect(try PageTests.evaluate(feed) == "Token bucket.")
    }

    @Test("A failure arriving on an empty stage is recorded", .enabled(if: PageTests.nodeIsAvailable))
    func failureRecorded() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer_failed', key:'caller@152', detail:'no credentials'}),"
            + " questions[0].error)"
        #expect(try PageTests.evaluate(feed) == "no credentials")
    }

    /// The server tags every answer frame with the question it answers. A frame for text a
    /// row has since been revised away from is stale: the server had already written the
    /// half's tokens to the socket before it heard about the revision, and applied, they
    /// landed under the revised question ahead of its own answer.
    @Test("A frame for a question the row has moved past is dropped", .enabled(if: PageTests.nodeIsAvailable))
    func staleFrameIsDropped() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer', key:'caller@152', for:'Design a rate', text:'stale '}),"
            + " applyAnswer({type:'answer', key:'caller@152', for:'Design a rate limiter.', text:'fresh'}),"
            + " String(questions[0].answer))"
        #expect(try PageTests.evaluate(feed) == "fresh")
    }

    @Test("A finished answer for a question the row has moved past is dropped", .enabled(if: PageTests.nodeIsAvailable))
    func staleDoneIsDropped() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer_done', key:'caller@152', for:'Design a rate', text:'Half answer.'}),"
            + " String(questions[0].answer) + ':' + String(questions[0].asked))"
        #expect(try PageTests.evaluate(feed) == "undefined:undefined")
    }

    @Test("An untagged frame is applied as before", .enabled(if: PageTests.nodeIsAvailable))
    func untaggedFrameApplies() throws {
        let feed = "(questions.length = 0, onStage = null, \(Self.question),"
            + " applyAnswer({type:'answer', key:'caller@152', text:'plain'}),"
            + " String(questions[0].answer))"
        #expect(try PageTests.evaluate(feed) == "plain")
    }

    /// Code blocks render in the stage, but the copy button's delegated listener sat on the
    /// transcript column, so pressing the button did nothing at all.
    @Test("The copy button in an answer reaches the clipboard", .enabled(if: PageTests.nodeIsAvailable))
    func copyButtonCopies() throws {
        let press = """
        (function () {
          const stage = document.getElementById("stage");
          const click = stage.listeners.find(l => l.type === "click");
          if (!click) return "no click listener on the stage";
          let copied = null;
          navigator.clipboard.writeText = text => { copied = text; return Promise.resolve(); };
          const code = { textContent: "x = 1" };
          const block = { querySelector: () => code };
          const button = { textContent: "copy", closest: sel => sel === ".code" ? block : null };
          click.fn({ target: { closest: sel => sel === ".copy" ? button : null } });
          return copied;
        })()
        """
        #expect(try PageTests.evaluate(press) == "x = 1")
    }
}

/// A question revised mid-answer.
///
/// The revision replaces the row's object, so whatever pointed at the old one has to be
/// moved across — the stage in particular, or the revised question's answer streams into
/// a row nobody is looking at while the stage keeps showing the half the journalist did
/// not finish.
@Suite("Revised question")
struct RevisedQuestionTests {
    @Test("A revision keeps the revised question on the stage", .enabled(if: PageTests.nodeIsAvailable))
    func revisionKeepsTheStage() throws {
        let feed = "(questions.length = 0, onStage = null,"
            + " addQuestion({text:'Design a rate', t0:152, ms:40, speaker:'caller'}),"
            + " activate(questions[0]),"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller', revises:true}),"
            + " String(onStage === questions[0]))"
        #expect(try PageTests.evaluate(feed) == "true")
    }

    /// With prefetch off, the reader asked the half by hand and the answer is streaming.
    /// The revision is the same question completed, so it is asked again with the full
    /// text — which is also what makes the server drop the half's answer. Left alone, the
    /// half's tokens landed under the revised row, locked its Ask button, and the reader
    /// could not ask the real question at all.
    @Test("A revision of a question that was asked is asked again with the full text", .enabled(if: PageTests.nodeIsAvailable))
    func revisionReasks() throws {
        let feed = """
        (function () {
          const sent = [];
          globalThis.fetch = (url, opts) => { sent.push(JSON.parse(opts.body).question); return Promise.resolve({ ok: true }); };
          questions.length = 0; onStage = null;
          addQuestion({text:'Design a rate', t0:152, ms:40, speaker:'caller'});
          ask(questions[0]);
          addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller', revises:true});
          return sent.join("|") + ":" + String(questions[0].asked);
        })()
        """
        #expect(try PageTests.evaluate(feed) == "Design a rate|Design a rate limiter.:true")
    }

    /// Two asks under one key can cross on the wire. The question's end time goes with
    /// each so the server can tell the revision from a late ask of the half it replaced.
    @Test("An ask carries the question's end time", .enabled(if: PageTests.nodeIsAvailable))
    func askCarriesEndTime() throws {
        let feed = """
        (function () {
          const sent = [];
          globalThis.fetch = (url, opts) => { sent.push(JSON.parse(opts.body).t1); return Promise.resolve({ ok: true }); };
          questions.length = 0; onStage = null;
          addQuestion({text:'Design a rate', t0:152, t1:153.83, ms:40, speaker:'caller'});
          ask(questions[0]);
          addQuestion({text:'Design a rate limiter.', t0:152, t1:156.07, ms:78, speaker:'caller', revises:true});
          return sent.join("|");
        })()
        """
        #expect(try PageTests.evaluate(feed) == "153.83|156.07")
    }

    @Test("A revision of a question nobody asked asks nothing", .enabled(if: PageTests.nodeIsAvailable))
    func revisionOfUnaskedAsksNothing() throws {
        let feed = """
        (function () {
          const sent = [];
          globalThis.fetch = (url, opts) => { sent.push(opts.body); return Promise.resolve({ ok: true }); };
          questions.length = 0; onStage = null;
          addQuestion({text:'Design a rate', t0:152, ms:40, speaker:'caller'});
          addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller', revises:true});
          return sent.length + ":" + String(questions[0].asked);
        })()
        """
        #expect(try PageTests.evaluate(feed) == "0:undefined")
    }

    @Test("A revision of a question that was not on the stage leaves the stage alone", .enabled(if: PageTests.nodeIsAvailable))
    func revisionElsewhereLeavesTheStage() throws {
        let feed = "(questions.length = 0, onStage = null,"
            + " addQuestion({text:'First', t0:10, ms:40, speaker:'caller'}),"
            + " addQuestion({text:'Design a rate', t0:152, ms:40, speaker:'caller'}),"
            + " activate(questions[0]),"
            + " addQuestion({text:'Design a rate limiter.', t0:152, ms:78, speaker:'caller', revises:true}),"
            + " String(onStage === questions[0]))"
        #expect(try PageTests.evaluate(feed) == "true")
    }
}

/// What the latency panel compares against.
///
/// `ms` is endpoint-to-final: it starts after the endpointer has already waited out the
/// hangover, and after the buffer that ended the question was delivered. The 700 ms
/// criterion is end-to-end, so judging `ms` against it directly flattered every question
/// by the hangover plus the delivery lag — a question at 450 ms read as comfortably
/// inside a budget it had in fact blown.
@Suite("Latency budget")
struct LatencyBudgetTests {
    @Test("Over budget is judged on the local total, not on ms alone", .enabled(if: PageTests.nodeIsAvailable))
    func overBudgetAddsTheHangover() throws {
        #expect(try PageTests.evaluate(
            "(document.body.dataset.hangoverMs = '250', String(overBudget({ms:450})))") == "true")
        #expect(try PageTests.evaluate(
            "(document.body.dataset.hangoverMs = '250', String(overBudget({ms:90})))") == "false")
    }

    /// The hangover is a command-line knob, so the page has to be told what it was.
    @Test("The hangover comes from the page, with the default as the fallback", .enabled(if: PageTests.nodeIsAvailable))
    func hangoverFromThePage() throws {
        #expect(try PageTests.evaluate(
            "(document.body.dataset.hangoverMs = '600', localLatency({ms:100}))") == "730")
        #expect(try PageTests.evaluate(
            "(delete document.body.dataset.hangoverMs, localLatency({ms:100}))") == "380")
    }

    /// The budget is the journalist's question to the screen. Your own lines are not
    /// judged against it: their hangover is over three times longer by choice, because
    /// nobody reads them back, and judging them would paint every one of them red.
    @Test("A line of your own is never over the caller's budget", .enabled(if: PageTests.nodeIsAvailable))
    func micRowsAreNotJudged() throws {
        #expect(try PageTests.evaluate(
            "(document.body.dataset.hangoverMs = '250', String(overBudget({ms:900, speaker:'you'})))") == "false")
        #expect(try PageTests.evaluate(
            "(document.body.dataset.hangoverMs = '250', String(overBudget({ms:900, speaker:'caller'})))") == "true")
    }

    @Test("The served page carries the configured hangover")
    func renderCarriesHangover() {
        #expect(Page.render(hangoverMilliseconds: 600).contains("data-hangover-ms=\"600\""))
        #expect(Page.render(hangoverMilliseconds: 250).contains("data-hangover-ms=\"250\""))
    }
}

/// What the status pill says when capture is not happening.
///
/// A failed rebuild is a warning — the process keeps going and retries — but until the
/// retry succeeds there is no capture graph, and a pill still reading "capturing" over
/// that is the exact symptom the capture-health suite exists to prevent.
@Suite("Status pill")
struct StatusPillTests {
    @Test("A failed rebuild turns the pill from capturing to down", .enabled(if: PageTests.nodeIsAvailable))
    func failedRebuildIsShown() throws {
        let feed = "(handleEvent({type:'status', state:'capturing'}),"
            + " handleEvent({type:'warning', code:'rebuild_failed', detail:'boom'}),"
            + " document.getElementById('state').textContent)"
        #expect(try PageTests.evaluate(feed) == "capture down")
    }

    @Test("A rebuild under way says so", .enabled(if: PageTests.nodeIsAvailable))
    func rebuildingIsShown() throws {
        let feed = "(handleEvent({type:'warning', code:'rebuilding', detail:'x'}),"
            + " document.getElementById('state').textContent)"
        #expect(try PageTests.evaluate(feed) == "rebuilding…")
    }

    @Test("The next capturing status restores the pill", .enabled(if: PageTests.nodeIsAvailable))
    func capturingRestores() throws {
        let feed = "(handleEvent({type:'warning', code:'rebuild_failed', detail:'boom'}),"
            + " handleEvent({type:'status', state:'capturing', detail:'rebuilt after no_buffers'}),"
            + " document.getElementById('state').textContent)"
        #expect(try PageTests.evaluate(feed) == "capturing")
    }

    /// Any other warning is information, not a change of state.
    @Test("An ordinary warning leaves the pill alone", .enabled(if: PageTests.nodeIsAvailable))
    func ordinaryWarningIsNotAStateChange() throws {
        let feed = "(handleEvent({type:'status', state:'capturing'}),"
            + " handleEvent({type:'warning', code:'volatile_fallback', detail:'x'}),"
            + " document.getElementById('state').textContent)"
        #expect(try PageTests.evaluate(feed) == "capturing")
    }
}
