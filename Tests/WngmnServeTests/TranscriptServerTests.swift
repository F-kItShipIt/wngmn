import Synchronization
import Foundation
import Testing
@testable import WngmnServe

/// These start a real listener on loopback. They are the only tier that proves the socket
/// is actually bound: `NWListener` reports a configuration error at `start()` rather than at
/// construction, so nothing short of connecting to it distinguishes a working server from
/// one that failed to bind.
@Suite("TranscriptServer", .serialized)
struct TranscriptServerTests {
    private func get(_ url: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("A loopback server binds and serves the page")
    func servesPage() async throws {
        let server = TranscriptServer(configuration: .init(port: 17373))
        try server.start()
        defer { server.stop() }

        let (status, body) = try await get("http://127.0.0.1:17373/")
        #expect(status == 200)
        #expect(body.contains("<title>wngmn"))
    }

    /// Binding is asynchronous, so `start()` used to return happily on a taken port. The
    /// second wngmn then printed a live-transcript URL that served the FIRST one's page
    /// and transcribed into a log nobody could open — indistinguishable from a build that
    /// had not taken effect, which is a mistake this project has already made once.
    @Test("Starting on a port already in use fails instead of pretending")
    func portAlreadyInUse() throws {
        let first = TranscriptServer(configuration: .init(port: 17382))
        try first.start()
        defer { first.stop() }

        let second = TranscriptServer(configuration: .init(port: 17382))
        #expect(throws: (any Error).self) { try second.start() }
    }

    @Test("An unknown path is a 404 rather than the page")
    func unknownPathIs404() async throws {
        let server = TranscriptServer(configuration: .init(port: 17374))
        try server.start()
        defer { server.stop() }

        #expect(try await get("http://127.0.0.1:17374/nope").0 == 404)
    }

    @Test("With a token set, a request without it is refused")
    func tokenGates() async throws {
        let token = AccessToken.generate()
        let server = TranscriptServer(configuration: .init(port: 17375, listenOnLAN: true, token: token))
        try server.start()
        defer { server.stop() }

        #expect(try await get("http://127.0.0.1:17375/").0 == 403)
        #expect(try await get("http://127.0.0.1:17375/?t=wrong").0 == 403)
        #expect(try await get("http://127.0.0.1:17375/?t=\(token)").0 == 200)
    }

    @Test("A page opened mid-interview is replayed the questions it missed")
    func replaysBacklog() async throws {
        let server = TranscriptServer(configuration: .init(port: 17376))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"Why now?"}"#)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:17376/events")!)
        request.timeoutInterval = 5
        // The stream never closes, so read only the first frames rather than to EOF.
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var seen = ""
        for try await line in bytes.lines {
            seen += line + "\n"
            if line.contains("Why now?") { break }
        }
        #expect(seen.contains(#"data: {"type":"question","text":"Why now?"}"#))
    }

    /// The token has to be the first thing checked. Answering 405 before 403 tells an
    /// unauthenticated prober which paths exist and which methods they take — the same leak
    /// the identical 403 for missing-vs-wrong token was written to avoid.
    @Test("An unauthenticated request cannot map the routes by method")
    func tokenIsCheckedBeforeMethod() async throws {
        let server = TranscriptServer(configuration: .init(port: 17383, token: "secret"))
        try server.start()
        defer { server.stop() }

        // GET on a POST-only path, with no token: must look exactly like GET on any path.
        let (postOnly, _) = try await get("http://127.0.0.1:17383/ask")
        let (unknown, _) = try await get("http://127.0.0.1:17383/nope")
        let (real, _) = try await get("http://127.0.0.1:17383/")
        #expect(postOnly == 403, "leaked that /ask exists and is POST-only: \(postOnly)")
        #expect(unknown == 403)
        #expect(real == 403)
    }

    /// A browser page on any origin can POST to a loopback port, and a name that resolves to
    /// 127.0.0.1 turns "only processes on this machine" into "anyone who can make you visit
    /// a page". Requiring the Host to be an address or a .local name costs a real client
    /// nothing and takes the rebinding route away.
    @Test("A request claiming an unrelated Host is refused")
    func rejectsRebindingHosts() async throws {
        let server = TranscriptServer(configuration: .init(port: 17384))
        try server.start()
        defer { server.stop() }

        #expect(TranscriptServer.isAcceptableHost("127.0.0.1:17384"))
        #expect(TranscriptServer.isAcceptableHost("localhost:17384"))
        #expect(TranscriptServer.isAcceptableHost("10.0.0.9:7373"))
        #expect(TranscriptServer.isAcceptableHost("samis-macbook-pro.local:7373"))
        #expect(TranscriptServer.isAcceptableHost("[::1]:7373"))
        #expect(TranscriptServer.isAcceptableHost("attacker.example.com:17384") == false)
        #expect(TranscriptServer.isAcceptableHost("evil.co") == false)
        // An unbracketed name with two colons is not an IPv6 literal, and treating any
        // surviving colon as proof of one let a registered domain through.
        #expect(TranscriptServer.isAcceptableHost("evil.example.com:8080:7373") == false)
        #expect(TranscriptServer.isAcceptableHost("a:b:c") == false)
        #expect(TranscriptServer.isAcceptableHost("[fe80::1%en0]:7373"))
        #expect(TranscriptServer.isAcceptableHost("256.1.1.1") == false)
    }

    /// Returning early on `scroll` dropped `mic` and `tap` from the same body while still
    /// answering 200, so the page would repaint a button whose state had not been applied.
    @Test("A control body carrying scroll and capture state applies both")
    func controlAppliesEveryField() async throws {
        let seen = Mutex<[String]>([])
        var configuration = TranscriptServer.Configuration(port: 17385)
        configuration.onControl = { payload in
            seen.withLock { $0.append(payload) }
            return #"{"mic":"muted","tap":"listening"}"#
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:17385/control")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"scroll":{"index":2,"into":0.5},"mic":"muted"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(seen.withLock { $0.count } == 1, "the capture half of the body was discarded")
        #expect(String(decoding: data, as: UTF8.self).contains("muted"),
                "answered before applying the change")
    }

    /// 202 Accepted for a request that was not accepted. The page treats any 2xx as success,
    /// so the failure only surfaced later, on a different channel.
    @Test("Asking with no answerer configured is not a success code")
    func askWithoutAnswererIsNotAccepted() async throws {
        let server = TranscriptServer(configuration: .init(port: 17386))
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:17386/ask")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"question":"x","key":"caller@1"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 503, "reported success for a request that could not be served: \(status)")
        #expect(String(decoding: data, as: UTF8.self).contains("not configured"))
    }

    /// Reads an event stream until `stop` matches a line, or the stream is exhausted.
    private func stream(_ url: String, lastEventID: String? = nil,
                        until stop: @escaping (String) -> Bool) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var seen = ""
        for try await line in bytes.lines {
            seen += line + "\n"
            if stop(line) { break }
        }
        return seen
    }

    /// Without an id on each frame the browser has nothing to send back on reconnect, so
    /// the server can only ever re-send everything it has.
    @Test("Remembered frames carry an id")
    func framesCarryIDs() async throws {
        let server = TranscriptServer(configuration: .init(port: 17377))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"First"}"#)

        let seen = try await stream("http://127.0.0.1:17377/events") { $0.contains("First") }
        #expect(seen.contains("id: 1"), "no event id in:\n\(seen)")
    }

    /// The reported bug: a phone that sleeps, or a tab Safari suspends, reconnects and is
    /// handed the entire backlog again — every question it already had, a second time.
    @Test("A reconnecting page is sent only what it missed")
    func resumesFromLastEventID() async throws {
        let server = TranscriptServer(configuration: .init(port: 17378))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"Already seen"}"#)
        server.broadcast(#"{"type":"question","text":"Missed while asleep"}"#)

        let seen = try await stream("http://127.0.0.1:17378/events", lastEventID: "1") {
            $0.contains("Missed while asleep")
        }
        #expect(seen.contains("Missed while asleep"))
        #expect(!seen.contains("Already seen"), "re-sent a question the page already had:\n\(seen)")
    }

    /// The common reconnect: a phone that slept for ten seconds and missed nothing. Sending
    /// it the whole transcript again is the bug the resume cursor exists to prevent, and it
    /// is the one case a naive "nothing newer, so send everything" fallback gets wrong.
    ///
    /// A later event is broadcast so the stream has something to deliver: asserting on
    /// silence alone would only ever time out, whether the behaviour was right or wrong.
    @Test("A page that missed nothing is sent nothing")
    func caughtUpReconnectGetsNothing() async throws {
        let server = TranscriptServer(configuration: .init(port: 17381))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"Already seen"}"#)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:17381/events")!)
        request.timeoutInterval = 5
        request.setValue("1", forHTTPHeaderField: "Last-Event-ID")
        let pump = Task {
            try? await Task.sleep(for: .milliseconds(250))
            server.broadcast(#"{"type":"question","text":"Brand new"}"#)
        }
        defer { pump.cancel() }
        let (bytes, _) = try await URLSession.shared.bytes(for: request)

        var seen = ""
        for try await line in bytes.lines {
            seen += line + "\n"
            if line.contains("Brand new") { break }
        }
        #expect(seen.contains("Brand new"))
        #expect(!seen.contains("Already seen"),
                "a caught-up page was re-sent what it already had:\n\(seen)")
    }

    /// A cursor from a previous run of wngmn, or one older than anything still retained.
    /// Replaying what is left beats replaying nothing: a page showing some history is more
    /// useful than one showing none.
    @Test("An unusable cursor falls back to the whole backlog")
    func unknownCursorReplaysEverything() async throws {
        let server = TranscriptServer(configuration: .init(port: 17379))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"Only one"}"#)

        let seen = try await stream("http://127.0.0.1:17379/events", lastEventID: "99999") {
            $0.contains("Only one")
        }
        #expect(seen.contains("Only one"))
    }

    /// Live-only frames must not consume ids, or a page that resumes from the last id it
    /// saw would skip the durable frames that were interleaved with them.
    @Test("Live-only frames do not advance the cursor")
    func liveFramesDoNotConsumeIDs() async throws {
        let server = TranscriptServer(configuration: .init(port: 17380))
        try server.start()
        defer { server.stop() }
        server.broadcast(#"{"type":"question","text":"One"}"#)
        server.broadcastLive(#"{"type":"partial","text":"two-ish"}"#)
        server.broadcast(#"{"type":"question","text":"Three"}"#)

        let seen = try await stream("http://127.0.0.1:17380/events") { $0.contains("Three") }
        #expect(seen.contains("id: 1"))
        #expect(seen.contains("id: 2"))
        #expect(!seen.contains("two-ish"), "a live-only frame was replayed:\n\(seen)")
    }
}

/// A flag a task can raise and a test can poll. A class, because a `Mutex` captured by a
/// `Task` and read again afterwards trips the compiler's region check.
private final class Counter: Sendable {
    private let n = Mutex(0)
    var value: Int { n.withLock { $0 } }
    func bump() { n.withLock { $0 += 1 } }
}

private final class Flag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// The answer path: one answer per question, however many devices ask for it.
extension TranscriptServerTests {
    private func post(
        _ url: String, _ body: String, headers: [String: String] = [:]
    ) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(body.utf8)
        // What the page sends. A cross-origin POST cannot set this without a preflight the
        // server never answers, so it is half of the same-origin defence.
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Polls until `condition` holds, or gives up.
    private func wait(until condition: () -> Bool, seconds: Double = 2) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Two devices with prefetch on both ask every question the instant it lands, and the
    /// page's own "already asked" latch cannot close until the first token comes back over
    /// the stream. The server is the only place that can refuse to start the same answer
    /// twice.
    @Test("Asking the same question twice under one key starts one answer")
    func duplicateAskStartsOnce() async throws {
        let started = Mutex(0)
        // Held open until both asks have been answered, so the test makes no assumption
        // about how quickly the second request follows the first.
        let release = Flag()
        var configuration = TranscriptServer.Configuration(port: 17387)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task {
                while !release.isSet { try? await Task.sleep(for: .milliseconds(10)) }
                emit(.done)
            }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        let body = #"{"question":"Why now?","key":"caller@1","recent":[]}"#
        async let first = post("http://127.0.0.1:17387/ask", body)
        async let second = post("http://127.0.0.1:17387/ask", body)
        let (a, b) = try await (first, second)
        release.set()
        #expect(a.0 == 202)
        #expect(b.0 == 202)
        #expect(started.withLock { $0 } == 1, "the same question was answered twice")
    }

    /// A question revised mid-answer is a different question: the answer under way is for
    /// the half the journalist did not finish. It is cancelled, and whatever it still emits
    /// never reaches a page — otherwise two answers interleave token by token under one key.
    @Test("A revised question under the same key supersedes the answer in flight")
    func revisionSupersedes() async throws {
        let firstStarted = Flag()
        let firstCancelled = Flag()
        let secondDone = Flag()
        let calls = Mutex(0)
        var configuration = TranscriptServer.Configuration(port: 17388)
        configuration.onAsk = { _, emit in
            let n = calls.withLock { $0 += 1; return $0 }
            return Task {
                if n == 1 {
                    emit(.text("half "))
                    firstStarted.set()
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        emit(.text("stale"))
                        emit(.done)
                        firstCancelled.set()
                    }
                } else {
                    emit(.text("whole "))
                    emit(.done)
                    secondDone.set()
                }
            }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        // Connected before anything is asked: answer tokens are live-only, never replayed.
        // Something is retained first so the stream has bytes to hand back on connect —
        // `URLSession` does not return until the body has started.
        server.broadcast(#"{"type":"status","state":"ready"}"#)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:17388/events")!)
        request.timeoutInterval = 5
        let (bytes, _) = try await URLSession.shared.bytes(for: request)

        _ = try await post("http://127.0.0.1:17388/ask", #"{"question":"Design a rate","key":"caller@152"}"#)
        await wait(until: { firstStarted.isSet })
        _ = try await post("http://127.0.0.1:17388/ask", #"{"question":"Design a rate limiter.","key":"caller@152"}"#)
        await wait(until: { firstCancelled.isSet && secondDone.isSet })
        #expect(firstCancelled.isSet, "the superseded answer was never cancelled")
        server.broadcast(#"{"type":"marker"}"#)

        var seen = ""
        for try await line in bytes.lines {
            seen += line + "\n"
            if line.contains("marker") { break }
        }
        #expect(calls.withLock { $0 } == 2)
        #expect(seen.contains("half "), "the first answer's token never arrived:\n\(seen)")
        #expect(seen.contains("whole "), "the revised answer never arrived:\n\(seen)")
        #expect(!seen.contains("stale"), "a cancelled answer still reached the page:\n\(seen)")
        #expect(seen.contains(#""for":"Design a rate limiter.""#), "frames do not name the question they answer:\n\(seen)")
    }

    /// The hangover is the endpointer's, so the page has to be told what it was to judge
    /// `ms` against the end-to-end budget honestly.
    @Test("The served page carries the configured hangover")
    func servesHangover() async throws {
        var configuration = TranscriptServer.Configuration(port: 17389)
        configuration.hangoverMilliseconds = 600
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        let (status, body) = try await get("http://127.0.0.1:17389/")
        #expect(status == 200)
        #expect(body.contains("data-hangover-ms=\"600\""), "the page does not carry the hangover")
    }

    /// Two asks under one key can cross on the wire, and a page replayed a half and its
    /// revision in one burst sends both. Text alone cannot order them, so the question's
    /// end time does: a differing text is a revision only when it ends later.
    @Test("A late ask of the half a question was revised from does not supersede the revision")
    func lateHalfDoesNotSupersede() async throws {
        let started = Mutex(0)
        let cancelled = Flag()
        var configuration = TranscriptServer.Configuration(port: 17392)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task {
                emit(.text("whole "))
                do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.set() }
            }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        _ = try await post("http://127.0.0.1:17392/ask",
                           #"{"question":"Design a rate limiter.","key":"caller@152","t1":156.07}"#)
        await wait(until: { started.withLock { $0 } == 1 })
        _ = try await post("http://127.0.0.1:17392/ask",
                           #"{"question":"Design a rate","key":"caller@152","t1":153.83}"#)
        await wait(until: { started.withLock { $0 } == 2 || cancelled.isSet }, seconds: 0.5)
        #expect(started.withLock { $0 } == 1, "the half superseded the revision")
        #expect(!cancelled.isSet, "the revision's answer was cancelled by a late ask of the half")
    }

    /// A resumed run remembers what it answered: the finished answers in the restored log
    /// seed the memory, so a page with prefetch on that is replayed the transcript does not
    /// have every answered question answered again.
    @Test("Answers restored from the log are remembered")
    func resumedAnswersAreRemembered() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = try EventLog(directory: dir)
        earlier.append(id: 1, line: #"{"type":"question","text":"Why now?","t0":1,"t1":2,"ms":50}"#)
        earlier.append(id: 2, line: #"{"type":"answer_done","key":"caller@1","for":"Why now?","text":"Because."}"#)
        earlier.flush()
        earlier.close()

        let started = Mutex(0)
        var configuration = TranscriptServer.Configuration(port: 17393)
        configuration.log = try EventLog(directory: dir, resuming: true)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task { emit(.done) }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        _ = try await post("http://127.0.0.1:17393/ask", #"{"question":"Why now?","key":"caller@1"}"#)
        await wait(until: { started.withLock { $0 } == 1 }, seconds: 0.3)
        #expect(started.withLock { $0 } == 0, "a question answered before the restart was answered again")
    }

    /// A revised question in a resumed log. The restored record has to carry the revision's
    /// end time, or a replayed ask of the half — which text alone cannot order against the
    /// revision — supersedes the finished answer, and both halves are answered again.
    @Test("A revised question restored from the log is not answered again by either half")
    func resumedRevisionIsNotAskedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = try EventLog(directory: dir)
        earlier.append(id: 1, line: #"{"type":"question","text":"Design a rate","t0":152,"t1":153.83,"ms":40}"#)
        earlier.append(id: 2, line: #"{"type":"question","text":"Design a rate limiter.","t0":152,"t1":156.07,"ms":78,"revises":true}"#)
        earlier.append(id: 3, line: #"{"type":"answer_done","key":"caller@152","for":"Design a rate limiter.","ended":156.07,"text":"Token bucket."}"#)
        earlier.flush()
        earlier.close()

        let started = Mutex(0)
        var configuration = TranscriptServer.Configuration(port: 17394)
        configuration.log = try EventLog(directory: dir, resuming: true)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task { emit(.done) }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        // What a page with prefetch on sends when the pair is replayed to it.
        _ = try await post("http://127.0.0.1:17394/ask", #"{"question":"Design a rate","key":"caller@152","t1":153.83}"#)
        _ = try await post("http://127.0.0.1:17394/ask", #"{"question":"Design a rate limiter.","key":"caller@152","t1":156.07}"#)
        await wait(until: { started.withLock { $0 } >= 1 }, seconds: 0.3)
        #expect(started.withLock { $0 } == 0, "a revised question answered before the restart was answered again")
    }

    /// The finished frame is what a resumed run seeds its memory from, so it has to say
    /// when its question ended — under its own name, since the page reads any event's `t1`
    /// as the clock.
    @Test("A finished answer says when its question ended")
    func answerDoneCarriesEndTime() async throws {
        let done = Flag()
        var configuration = TranscriptServer.Configuration(port: 17395)
        configuration.onAsk = { _, emit in
            return Task { emit(.text("x")); emit(.done); done.set() }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        _ = try await post("http://127.0.0.1:17395/ask", #"{"question":"Why now?","key":"caller@1","t1":12.5}"#)
        await wait(until: { done.isSet })
        let seen = try await stream("http://127.0.0.1:17395/events") { $0.contains("answer_done") }
        #expect(seen.contains(#""ended":12.5"#), "the finished frame does not say when its question ended:\n\(seen)")
    }

    /// A device that joins late is replayed every question before it is replayed their
    /// answers, and with prefetch on it asks each one as it lands. Forgetting an answer the
    /// moment it finished let that re-run every answered question in the backlog and stream
    /// each of them, doubled, onto every screen.
    @Test("Asking an already answered question again starts nothing")
    func answeredQuestionIsNotAskedAgain() async throws {
        let started = Mutex(0)
        let done = Flag()
        var configuration = TranscriptServer.Configuration(port: 17390)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task { emit(.text("answer")); emit(.done); done.set() }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        let body = #"{"question":"Why now?","key":"caller@1"}"#
        _ = try await post("http://127.0.0.1:17390/ask", body)
        await wait(until: { done.isSet })
        _ = try await post("http://127.0.0.1:17390/ask", body)
        #expect(started.withLock { $0 } == 1, "an answered question was answered again")
    }

    /// Different text under the same key is the question revised; that one is answered.
    @Test("A revised question under an answered key is answered afresh")
    func revisedQuestionAfterAnswerIsAnswered() async throws {
        let started = Mutex(0)
        let done = Flag()
        var configuration = TranscriptServer.Configuration(port: 17391)
        configuration.onAsk = { _, emit in
            started.withLock { $0 += 1 }
            return Task { emit(.done); done.set() }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        _ = try await post("http://127.0.0.1:17391/ask", #"{"question":"Design a rate","key":"caller@152"}"#)
        await wait(until: { done.isSet })
        _ = try await post("http://127.0.0.1:17391/ask", #"{"question":"Design a rate limiter.","key":"caller@152"}"#)
        await wait(until: { started.withLock { $0 } == 2 }, seconds: 1)
        #expect(started.withLock { $0 } == 2, "the revised question was not answered")
    }
}


/// Who is allowed to act on the capture and spend the API key.
///
/// On loopback there is no token — the OS is the boundary for reading — but a browser will
/// send a cross-origin POST without asking anyone: a JSON body labelled `text/plain` is a
/// CORS "simple request" and needs no preflight. So any page in any tab could pause the
/// tap, mute the microphone, and spend the owner's Anthropic credit on questions of its
/// own, each carrying the owner's prepared notes as the system prompt. Reproduced against
/// a real browser before this was closed.
@Suite("Same-origin", .serialized)
struct SameOriginTests {
    private func post(
        _ url: String, _ body: String, headers: [String: String]
    ) async throws -> Int {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(body.utf8)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Runs `body` against a server whose control handler records what reached it.
    private func withServer(
        port: UInt16, _ body: (String, Counter) async throws -> Void
    ) async throws {
        let applied = Counter()
        var configuration = TranscriptServer.Configuration(port: port)
        configuration.onControl = { _ in
            applied.bump()
            return #"{"mic":"live","tap":"listening"}"#
        }
        configuration.onAsk = { _, emit in
            applied.bump()
            return Task { emit(.done) }
        }
        let server = TranscriptServer(configuration: configuration)
        try server.start()
        defer { server.stop() }
        try await body("http://127.0.0.1:\(port)", applied)
    }

    @Test("A cross-site POST reaches neither the capture controls nor the API key")
    func crossSiteIsRefused() async throws {
        try await withServer(port: 17396) { base, applied in
            let hostile = ["sec-fetch-site": "cross-site", "content-type": "text/plain"]
            let status38 = try await post(base + "/control", #"{"tap":"paused"}"#, headers: hostile)
            #expect(status38 == 403)
            let status40 = try await post(base + "/ask", #"{"question":"x","key":"k"}"#, headers: hostile)
            #expect(status40 == 403)
            #expect(applied.value == 0, "a cross-site page acted on the tool")
        }
    }

    /// `same-site` is not `same-origin`: a sibling host is still not this page.
    @Test("A same-site POST is refused too")
    func sameSiteIsRefused() async throws {
        try await withServer(port: 17397) { base, applied in
            let headers = ["sec-fetch-site": "same-site", "content-type": "application/json"]
            let status51 = try await post(base + "/control", #"{"tap":"paused"}"#, headers: headers)
            #expect(status51 == 403)
            #expect(applied.value == 0)
        }
    }

    /// Older clients send `Origin` without the metadata headers; it has to name this server.
    @Test("A POST from another origin is refused")
    func foreignOriginIsRefused() async throws {
        try await withServer(port: 17398) { base, applied in
            let headers = ["origin": "https://evil.example", "content-type": "application/json"]
            let status62 = try await post(base + "/control", #"{"tap":"paused"}"#, headers: headers)
            #expect(status62 == 403)
            let status64 = try await post(base + "/ask", #"{"question":"x","key":"k"}"#, headers: headers)
            #expect(status64 == 403)
            #expect(applied.value == 0)
        }
    }

    /// A body a browser can send cross-origin without a preflight is refused on its own,
    /// so a browser too old to send the metadata headers still cannot reach these routes.
    @Test("A POST that is not JSON is refused whatever it claims to be")
    func nonJSONBodyIsRefused() async throws {
        try await withServer(port: 17399) { base, applied in
            for kind in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
                let status = try await post(base + "/control", #"{"tap":"paused"}"#,
                                            headers: ["content-type": kind])
                #expect(status == 415, "a \(kind) body was accepted")
            }
            #expect(applied.value == 0)
        }
    }

    @Test("The page's own POST is allowed")
    func sameOriginIsAllowed() async throws {
        try await withServer(port: 17400) { base, applied in
            let own = [
                "sec-fetch-site": "same-origin", "content-type": "application/json",
                "origin": "http://127.0.0.1:17400",
            ]
            let status90 = try await post(base + "/control", #"{"tap":"paused"}"#, headers: own)
            #expect(status90 == 200)
            let status92 = try await post(base + "/ask", #"{"question":"x","key":"k"}"#, headers: own)
            #expect(status92 == 202)
            // Waited for, not read at once. `/control` replies with what its handler returned,
            // so the handler has run by the time the status is back; `/ask` sends its 202 first
            // and calls the handler after, so the 202 can reach this test before the bump does.
            // Read at once, this failed on CI with `applied.value → 1` after eleven green runs.
            let deadline = ContinuousClock.now + .seconds(10)
            while applied.value < 2, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(applied.value == 2, "the page's own requests were refused")
        }
    }

    /// curl, a script, the tests. Not a browser being used as the owner, and on loopback it
    /// could read the log file instead; on the LAN it still needs the token.
    @Test("A client that is not a browser is allowed")
    func nonBrowserIsAllowed() async throws {
        try await withServer(port: 17401) { base, applied in
            let plain = ["content-type": "application/json"]
            let status104 = try await post(base + "/control", #"{"tap":"paused"}"#, headers: plain)
            #expect(status104 == 200)
            #expect(applied.value == 1)
        }
    }

    /// A user following a link to the page is `cross-site`, and reading is not acting.
    @Test("Opening the page from a link still works")
    func navigationIsAllowed() async throws {
        try await withServer(port: 17402) { base, _ in
            var request = URLRequest(url: URL(string: base + "/")!)
            request.timeoutInterval = 5
            request.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }
}
