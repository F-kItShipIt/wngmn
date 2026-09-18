import Foundation
import Network
import WngmnCore
import Synchronization

/// One fragment of a streamed answer.
public enum AskChunk: Sendable, Equatable {
    case text(String)
    case done
    case failed(String)
    /// The answer stopped at the token cap rather than finishing. Carried separately from
    /// `failed` because the text so far is real and worth showing — it just does not end.
    case truncated
}

/// Applies a control change and returns the resulting state as a JSON object.
public typealias ControlHandler = @Sendable (String) throws -> String

/// Answers a question, calling `emit` as fragments arrive, and returns the task doing so.
///
/// Injected rather than imported, so this module keeps knowing nothing about where an
/// answer comes from — the transcript view and the Claude client stay on opposite sides of
/// the line, and the server stays testable without credentials.
///
/// The task is handed back so the server can cancel an answer that has been overtaken: a
/// question revised mid-answer is a different question, and the stream for the half the
/// journalist did not finish must stop rather than interleave with the new one.
public typealias AskHandler = @Sendable (
    _ payload: String, _ emit: @escaping @Sendable (AskChunk) -> Void
) -> Task<Void, Never>

/// Serves the live transcript over HTTP on this machine.
///
/// Six routes: `/` returns the page, `/events` holds a Server-Sent Events connection open
/// and receives every JSON Lines event the pipeline emits, `/ask` starts an answer that then
/// streams over `/events` to every page, `/control` applies a capture change, `/summarise`
/// asks for the end-of-call notes, and `/shot` asks for a picture of the screen — the one
/// route answered only to this machine. The browser does the reconnecting, so a page left
/// open through a laptop sleep recovers on its own.
///
/// Binding is loopback by default. `listenOnLAN` puts the transcript of a press interview on
/// the wifi, so it is gated behind a token that must appear on every request.
public final class TranscriptServer: Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16 = 7373
        /// Bind `0.0.0.0` instead of `127.0.0.1`, so a phone or iPad can read the transcript.
        public var listenOnLAN = false
        /// Required when `listenOnLAN`; ignored on loopback, where the OS is the boundary.
        public var token: String?
        /// When nil, `/ask` reports that answering is not configured rather than 404ing —
        /// the button exists on the page either way, and "not wired up" is a more useful
        /// thing to be told than "no such path".
        public var onAsk: AskHandler?
        /// Applies a `POST /control` body and returns the resulting state as JSON.
        /// Throwing rejects the request rather than applying half of it.
        public var onControl: ControlHandler?
        /// Triggers end-of-call notes over the whole conversation. Fire-and-forget: the
        /// summary streams back as `summary_*` frames, so the POST just accepts and returns.
        public var onSummarise: (@Sendable () -> Void)?
        /// Takes a picture of the screen and answers it. Fire-and-forget, and it must return
        /// at once: it is called on the server's one serial queue, which carries the listener
        /// and every connection, and a region shot can sit under a crosshair for a minute.
        public var onShot: (@Sendable (ShotMode) -> Void)?
        /// Mirrors the replay buffer to disk, so a wngmn that dies mid-interview can be
        /// resumed instead of coming back with nothing to tell the pages that reconnect.
        /// Nil disables it entirely — see `--no-log`.
        public var log: EventLog?
        /// The endpointer's hangover, written into the page so it can judge `ms` — which
        /// starts only after that wait — against the end-to-end budget honestly. The
        /// caller's: the budget is about the journalist's question, not your own lines.
        public var hangoverMilliseconds: Double = EndpointerConfig().hangoverMs

        public init(
            port: UInt16 = 7373, listenOnLAN: Bool = false, token: String? = nil,
            onAsk: AskHandler? = nil,
            onControl: ControlHandler? = nil,
            onSummarise: (@Sendable () -> Void)? = nil,
            onShot: (@Sendable (ShotMode) -> Void)? = nil,
            log: EventLog? = nil,
            hangoverMilliseconds: Double = EndpointerConfig().hangoverMs
        ) {
            self.port = port
            self.listenOnLAN = listenOnLAN
            self.token = token
            self.onAsk = onAsk
            self.onControl = onControl
            self.onSummarise = onSummarise
            self.onShot = onShot
            self.log = log
            self.hangoverMilliseconds = hangoverMilliseconds
        }
    }

    /// Replayed to a browser that connects mid-interview, so opening the page late shows the
    /// questions so far rather than an empty screen. Bounded: a 45-minute call must not grow
    /// this without limit.
    public static let backlogLimit = 400

    /// An answer under way, or finished, for one question.
    private struct AskRecord {
        /// The text it is answering, so a second ask can be told apart from a revision.
        let question: String
        /// Which ask this is; frames from any other generation under the same key are
        /// dropped, so a superseded answer cannot interleave with its replacement.
        let generation: Int
        /// When the question ended, if the ask said. Two asks under one key can cross on
        /// the wire, and a page replayed a half and its revision in one burst sends both;
        /// text alone cannot order them, so a differing text is a revision only when it
        /// ends later.
        let t1: Double?
        /// Nil for the instant between recording the ask and the handler returning, and
        /// once the answer has finished.
        var task: Task<Void, Never>?
        /// Kept after `done` rather than forgotten: a device that joins late is replayed
        /// every question before their answers, and with prefetch on it asks each as it
        /// lands — which re-ran every answered question in the backlog onto every screen.
        var finished = false
    }

    private struct State {
        var clients: [ObjectIdentifier: NWConnection] = [:]
        /// Retained frames, each with the id a returning page cites to resume from.
        var backlog: [(id: Int, line: String)] = []
        var nextID = 1
        var stopped = false
        /// Answers under way or finished, by the question key the page supplied. Bounded
        /// like the backlog; the oldest are forgotten first.
        var asks: [String: AskRecord] = [:]
        var askGeneration = 0
    }

    private let configuration: Configuration
    private let state = Mutex(State())
    private let listener: Mutex<NWListener?> = Mutex(nil)
    private let heartbeat: Mutex<DispatchSourceTimer?> = Mutex(nil)
    private let queue = DispatchQueue(label: "wngmn.serve")

    public init(configuration: Configuration) {
        self.configuration = configuration
        // A resumed session is indistinguishable from one that never stopped, as far as a
        // reconnecting page is concerned: same ids, continuing where they left off.
        if let log = configuration.log {
            state.withLock { state in
                state.backlog = log.restored.map { (id: $0.id, line: $0.line) }
                // Adopted whether or not anything was restored. A file whose tail is all
                // blank lines restores nothing while still occupying those positions, and
                // numbering from 1 into it would hand two lines the same id.
                state.nextID = log.nextID
                // What the earlier run answered is remembered too: a page with prefetch on
                // is replayed the questions before their answers, and would otherwise have
                // every one of them answered again.
                for entry in log.restored {
                    guard let answered = Self.answeredQuestion(in: entry.line) else { continue }
                    state.asks[answered.key] = AskRecord(
                        question: answered.question, generation: 0, t1: answered.ended,
                        task: nil, finished: true)
                }
            }
        }
    }

    /// The key, question and end time of a finished answer's frame, or nil for any other
    /// line. The end time is what lets a restored record order a replayed ask of the half a
    /// question was revised from; without it the half would supersede the finished revision.
    static func answeredQuestion(in line: String) -> (key: String, question: String, ended: Double?)? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "answer_done",
              let key = root["key"] as? String, !key.isEmpty,
              let question = root["for"] as? String
        else { return nil }
        let ended = (root["ended"] as? Double).flatMap { $0.isFinite ? $0 : nil }
        return (key, question, ended)
    }

    /// The URL to open. Carries the token when there is one, so the printed line is the
    /// whole of what the user has to do.
    public var url: String {
        let host = configuration.listenOnLAN ? (Self.primaryIPv4() ?? "0.0.0.0") : "127.0.0.1"
        return url(host: host)
    }

    /// The same page reached by this Mac's Bonjour name instead of its address.
    ///
    /// Preferred over the IP for anything written down: the address is handed out by
    /// whichever router you are on and changes with the network and the lease, so a URL
    /// containing one is stale as soon as you move. The `.local` name does not change.
    public var localHostnameURL: String? {
        guard configuration.listenOnLAN, let name = Self.localHostname() else { return nil }
        return url(host: "\(name).local")
    }

    private func url(host: String) -> String {
        let suffix = configuration.token.map { "/?t=\($0)" } ?? "/"
        return "http://\(host):\(configuration.port)\(suffix)"
    }

    /// The Bonjour name, lowercased because that is how it is typed and how mDNS resolves it.
    static func localHostname() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : name
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw Failure.badPort(configuration.port)
        }
        let listener: NWListener
        if configuration.listenOnLAN {
            listener = try NWListener(using: parameters, on: port)
        } else {
            // Without this the listener answers on every interface, and "localhost only"
            // would be a comment rather than a property of the socket.
            //
            // The port travels in the endpoint, and passing it via `on:` as well is
            // rejected — `start()` fails with EINVAL, and only at start: construction
            // succeeds, so nothing but connecting to the socket reveals it.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // Binding is asynchronous: `start` returns before the socket exists, and a port
        // already in use is reported through this handler rather than thrown. Without the
        // wait, a second wngmn on a taken port printed a live-transcript URL that in fact
        // served the FIRST one's page, then transcribed into a log nobody could open — which
        // looks exactly like a build that did not take effect.
        let settled = DispatchSemaphore(value: 0)
        let failure = Mutex<String?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                settled.signal()
            // `.waiting` is how "address in use" arrives: the listener parks and retries
            // forever. For a tool started from a shell that is a failure, not patience.
            case let .failed(error), let .waiting(error):
                failure.withLock { $0 = "\(error)" }
                settled.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw Failure.notListening(configuration.port, "timed out waiting for the socket")
        }
        if let why = failure.withLock({ $0 }) {
            listener.cancel()
            throw Failure.notListening(configuration.port, why)
        }
        self.listener.withLock { $0 = listener }

        // `SSE.keepAlive` existed and was documented but nothing ever sent it, so an idle
        // stream had nothing crossing it between questions. A quiet stretch of interview is
        // exactly when a NAT table or a phone's radio drops an idle connection, and the page
        // then misses the next question until the browser notices and reconnects.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let clients = state.withLock { $0.stopped ? [] : Array($0.clients.values) }
            for connection in clients { send(SSE.keepAlive, on: connection, close: false) }
        }
        timer.resume()
        heartbeat.withLock { $0 = timer }
    }

    /// Comfortably inside the minute-ish idle window a home router will hold a NAT entry for.
    static let keepAliveInterval: DispatchTimeInterval = .seconds(20)
    /// How long a connection may take to produce a complete request before it is hung up on.
    /// A browser sends one inside a round trip; anything slower is stuck or probing.
    static let requestDeadline: DispatchTimeInterval = .seconds(15)

    public func stop() {
        heartbeat.withLock { timer in
            timer?.cancel()
            timer = nil
        }
        configuration.log?.flush()
        let clients: [NWConnection] = state.withLock { state in
            state.stopped = true
            for ask in state.asks.values { ask.task?.cancel() }
            state.asks.removeAll()
            let all = Array(state.clients.values)
            state.clients.removeAll()
            return all
        }
        for connection in clients { connection.cancel() }
        listener.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }

    /// Push one JSON Lines event to every open page, and remember it for replay.
    public func broadcast(_ line: String) {
        push(line, remember: true)
    }

    /// Push to open pages without adding to the replay backlog.
    ///
    /// For answer deltas specifically. An answer arrives as hundreds of small frames, and
    /// backlogging them would evict the entire question history from the replay buffer — a
    /// page opened mid-interview would show one answer and no transcript. The completed
    /// answer is broadcast once, backlogged, when it finishes.
    public func broadcastLive(_ line: String) {
        push(line, remember: false)
    }

    private func push(_ line: String, remember: Bool) {
        // Id assignment and the append have to be one atomic step, or two events racing
        // from the tap and the mic threads can be numbered out of the order they are
        // retained in — and a resuming page would then skip one of them.
        let (frame, clients): (String, [NWConnection]) = state.withLock { state in
            guard !state.stopped else { return ("", []) }
            var frame = SSE.frame(line)
            if remember {
                let id = state.nextID
                state.nextID += 1
                frame = SSE.frame(line, id: id)
                // Written under the same lock that issued the id, because the file's whole
                // format rests on a line's position being its id.
                configuration.log?.append(id: id, line: line)
                state.backlog.append((id, line))
                if state.backlog.count > Self.backlogLimit {
                    state.backlog.removeFirst(state.backlog.count - Self.backlogLimit)
                }
            }
            return (frame, Array(state.clients.values))
        }
        guard !frame.isEmpty else { return }
        for connection in clients { send(frame, on: connection, close: false) }
        // After the fan-out and outside the lock, on purpose. Making the file durable costs
        // 2.9 ms; the pages are charted against a 700 ms budget, and there is no reason for
        // the disk to be in front of the screen.
        if remember { configuration.log?.syncSoon() }
    }

    /// Shared between the read loop and the timer that gives up on it. A box, because
    /// `Mutex` is noncopyable and so cannot be passed to a function or captured by two
    /// closures on its own.
    private final class RoutedFlag: Sendable {
        private let flag = Mutex(false)
        var isSet: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A connection that never completes a request otherwise sits open for the length of
        // the interview: nothing answers it and nothing closes it, so a handful of them are
        // a handful of descriptors held for nothing. Only the read phase is bounded — once a
        // request has been routed the connection may be an event stream and live for hours.
        let routed = RoutedFlag()
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) {
            if !routed.isSet { connection.cancel() }
        }
        receive(connection, buffer: Data(), routed: routed)
    }

    private func receive(_ connection: NWConnection, buffer: Data, routed: RoutedFlag) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { connection.cancel(); return }

            // Accumulated as bytes and decoded once, rather than decoded per read: TCP
            // splits where it likes, and a multibyte character straddling two reads becomes
            // replacement characters if each read is decoded on its own.
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            // A request header this large is not a browser. Dropping it keeps a stuck or
            // hostile connection from growing the buffer for the length of the interview.
            guard buffer.count <= 64 * 1024 else { connection.cancel(); return }

            switch HTTPRequest.parse(buffer) {
            case let .ok(request):
                routed.set()
                self.route(request, on: connection)
            case .malformed:
                // It cannot become valid however much more arrives, so reading on would hold
                // the connection open for nothing. This arrives unauthenticated.
                connection.cancel()
            case .incomplete:
                if isComplete { connection.cancel(); return }
                self.receive(connection, buffer: buffer, routed: routed)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        // A name that resolves to this machine turns "only processes here can reach it" into
        // "anyone who can make you visit a page". A real client always addresses the server
        // by address or by its .local name, so requiring that costs nothing and closes the
        // rebinding route. Checked first: it is the cheapest and the least revealing.
        if let host = request.headers["host"], !Self.isAcceptableHost(host) {
            return send(Self.response(status: "403 Forbidden", body: "bad host"),
                        on: connection, close: true)
        }
        // Before the method check, not after. Answering 405 first told an unauthenticated
        // prober which paths exist and which methods they take — the same leak the identical
        // 403 for a missing versus a wrong token was written to avoid.
        if let token = configuration.token,
           !AccessToken.matches(token, request.query["t"] ?? "") {
            // Deliberately identical for a missing and a wrong token: distinguishing them
            // tells a prober which half they got right.
            return send(Self.response(status: "403 Forbidden", body: "bad or missing token"),
                        on: connection, close: true)
        }
        let allowed = ["/ask", "/control", "/summarise", "/shot"].contains(request.path) ? "POST" : "GET"
        guard request.method == allowed else {
            return send(Self.response(status: "405 Method Not Allowed", body: "\(allowed) only"),
                        on: connection, close: true)
        }
        // Only the page's own requests may act. Reading is not gated this way: a hostile
        // page cannot read a cross-origin response without a CORS header this server never
        // sends, and refusing a cross-site GET would break following a link to the page.
        if request.method == "POST" {
            guard Self.isSameOrigin(request) else {
                return send(Self.response(status: "403 Forbidden", body: "cross-origin"),
                            on: connection, close: true)
            }
            guard Self.isJSONBody(request) else {
                return send(Self.response(status: "415 Unsupported Media Type", body: "send JSON"),
                            on: connection, close: true)
            }
        }

        switch request.path {
        case "/":
            send(Self.response(
                    status: "200 OK",
                    body: Page.render(hangoverMilliseconds: configuration.hangoverMilliseconds),
                    contentType: "text/html; charset=utf-8"),
                 on: connection, close: true)
        case "/events":
            // The browser resends the last id it saw when it reconnects. `?after=` is the
            // same cursor by query, for a client that cannot set the header.
            let cursor = request.headers["last-event-id"] ?? request.query["after"]
            openEventStream(on: connection, resumingAfter: cursor.flatMap(Int.init))
        case "/ask":
            answer(payload: request.body, on: connection)
        case "/control":
            control(payload: request.body, on: connection)
        case "/summarise":
            summarise(on: connection)
        case "/shot":
            shot(payload: request.body, on: connection)
        default:
            send(Self.response(status: "404 Not Found", body: "no such path"), on: connection, close: true)
        }
    }

    /// Asks for a picture of the screen. Answered only to this machine, whatever the listener
    /// is bound to: under `--listen` anyone on the network holding the token can already read
    /// the transcript, and that must not extend to making this Mac photograph its own screen.
    ///
    /// The handler runs before the 202 is sent, as it does for `/summarise`, so a caller that
    /// has its status back knows the request was handed over.
    private func shot(payload: String, on connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            return send(Self.response(status: "403 Forbidden", body: "this machine only"),
                        on: connection, close: true)
        }
        guard let onShot = configuration.onShot else {
            return send(
                Self.response(status: "503 Service Unavailable",
                              body: #"{"error":"screenshots are not configured"}"#,
                              contentType: "application/json"),
                on: connection, close: true)
        }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = (root["mode"] as? String).flatMap(ShotMode.init(rawValue:))
        else {
            return send(
                Self.response(status: "400 Bad Request",
                              body: #"{"error":"mode must be screen or region"}"#,
                              contentType: "application/json"),
                on: connection, close: true)
        }
        onShot(mode)
        send(Self.response(status: "202 Accepted", body: #"{"ok":true}"#,
                           contentType: "application/json"),
             on: connection, close: true)
    }

    /// Whether a connection's remote end is this machine: 127.0.0.1, ::1, or the first of those
    /// as an IPv4-mapped IPv6 address, which a dual-stack listener can hand over and which
    /// Network.framework's own `isLoopback` does not recognise. Strict on purpose — 127.0.0.2
    /// is refused, a name is refused — because the only client there is uses 127.0.0.1.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return address.isLoopback
        case let .ipv6(address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    /// Kicks off end-of-call notes. The notes stream back over `/events` as `summary_*`
    /// frames to every page, so this only has to accept the request.
    private func summarise(on connection: NWConnection) {
        guard let onSummarise = configuration.onSummarise else {
            return send(
                Self.response(status: "503 Service Unavailable",
                              body: #"{"error":"summarising is not configured"}"#,
                              contentType: "application/json"),
                on: connection, close: true)
        }
        onSummarise()
        send(Self.response(status: "202 Accepted", body: #"{"ok":true}"#,
                           contentType: "application/json"),
             on: connection, close: true)
    }

    private func openEventStream(on connection: NWConnection, resumingAfter: Int?) {
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-store\r
        Connection: keep-alive\r
        \r

        """
        // What this page has not been told about. A first connection is caught up on
        // everything retained; a reconnecting one cites the last id it saw and is sent only
        // what came after, so a phone waking from sleep does not receive its whole
        // transcript a second time.
        let replay = state.withLock { state -> String in
            guard !state.stopped else { return "" }
            state.clients[ObjectIdentifier(connection)] = connection
            var entries = state.backlog
            // The cursor is usable when it names a position inside what is still retained —
            // including the newest, which is the ordinary "slept and missed nothing" case and
            // must send nothing. Testing instead for "is there anything newer" collapsed that
            // case into the fallback and re-sent the page its whole transcript.
            let oldest = entries.first?.id ?? 1
            let newest = entries.last?.id ?? 0
            if let after = resumingAfter, after >= oldest - 1, after <= newest {
                entries = entries.filter { $0.id > after }
            }
            // Anything else — a cursor from a previous run of wngmn, or one older than
            // what is still retained — falls through to the whole backlog: a page showing
            // some history is more useful than one showing none.
            return entries.map { SSE.frame($0.line, id: $0.id) }.joined()
        }
        send(headers + replay, on: connection, close: false)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.state.withLock { $0.clients[ObjectIdentifier(connection)] = nil }
            default:
                break
            }
        }
    }

    /// Applies a capture-control change and replies with the resulting state.
    ///
    /// A plain request/response rather than a stream: the page needs to know the change
    /// landed before it repaints the button, and showing "muted" on a request that failed
    /// would be worse than showing nothing.
    private func control(payload: String, on connection: NWConnection) {
        guard let onControl = configuration.onControl else {
            return send(
                Self.response(status: "503 Service Unavailable", body: #"{"error":"capture control is not configured"}"#,
                              contentType: "application/json"),
                on: connection, close: true
            )
        }
        // Scroll position is relayed here rather than through `onControl`: it is a purely
        // between-pages concern with no capture state behind it, and it is broadcast
        // live-only — a replayed scroll position from ten minutes ago would yank a page
        // opened later to somewhere nobody is looking.
        let anchor = Self.scrollAnchor(in: payload)
        if let anchor {
            broadcastLive("{\"type\":\"scroll\",\"anchor\":\(anchor)}")
        }
        // Only when the body is *nothing but* a scroll. Returning here on any body that
        // carried one discarded `mic` and `tap` alongside it while still answering 200, so a
        // page would repaint a button whose change had never been applied.
        if anchor != nil, !Self.carriesCaptureState(payload) {
            return send(
                Self.response(status: "200 OK", body: #"{"ok":true}"#,
                              contentType: "application/json"),
                on: connection, close: true
            )
        }
        do {
            let state = try onControl(payload)
            send(Self.response(status: "200 OK", body: state, contentType: "application/json"),
                 on: connection, close: true)
        } catch {
            send(Self.response(status: "400 Bad Request",
                               body: "{\"error\":\(Self.quote("\(error)"))}",
                               contentType: "application/json"),
                 on: connection, close: true)
        }
    }

    /// Starts an answer. The request is only a trigger.
    ///
    /// The answer itself goes out over `/events` to every open page, including the one that
    /// asked. One path rather than two is what makes a phone and a laptop show the same
    /// thing: they are not two implementations kept in step, they are the same one.
    ///
    /// Answers still never reach `EventWriter`, so they stay out of the JSON Lines on
    /// stdout — that remains a transcript rather than a notepad. What has changed is that an
    /// answer is no longer private to whoever asked: anyone holding the token sees it.
    ///
    /// One answer per question. Two devices with prefetch on both ask the instant a question
    /// lands, and the page's own "already asked" latch cannot close until the first token
    /// has come back over the stream, so the server is the only place that can refuse to
    /// start the same answer twice. A second ask under a key already answered, or being
    /// answered, is accepted and ignored if it carries the same text; if the text differs
    /// the question was revised, and any answer under way — for the half the journalist
    /// did not finish — is cancelled and everything it still emits dropped, so two answers
    /// can never interleave token by token under one key. A failed answer is forgotten, so
    /// a revision, or a device that asks it later, starts a fresh attempt rather than
    /// being told nothing.
    private func answer(payload: String, on connection: NWConnection) {
        let key = Self.askKey(in: payload)
        let question = Self.askQuestion(in: payload)
        let t1 = Self.askEndTime(in: payload)
        // Every frame names the question it answers, so a page can drop one that reached
        // the socket before the server heard the question had been revised.
        let forQuestion = "\"for\":\(Self.quote(question)),"
        // The finished frame also says when its question ended, so a resumed run can seed
        // its memory with something a late ask of the half can be ordered against. Under
        // its own name: the page reads any event's `t1` as the clock.
        let ended = t1.map { ",\"ended\":\(String($0))" } ?? ""
        guard let onAsk = configuration.onAsk else {
            broadcast(
                "{\"type\":\"answer_failed\",\"key\":\(Self.quote(key)),\(forQuestion)"
                + "\"detail\":\"answering is not configured\"}"
            )
            // Not 202. The page treats any 2xx as accepted, so reporting success here put
            // the real reason on a different channel and left the button looking like it had
            // worked.
            return send(
                Self.response(status: "503 Service Unavailable",
                              body: #"{"error":"answering is not configured"}"#,
                              contentType: "application/json"),
                on: connection, close: true
            )
        }
        // Accepted either way: a duplicate's answer is on its way too, just not twice.
        send(
            Self.response(status: "202 Accepted", body: #"{"ok":true}"#,
                          contentType: "application/json"),
            on: connection, close: true
        )

        // Recorded before the handler runs, so a frame it emits at once is already current.
        // Only a key the page supplied is tracked; a keyless ask matches no row on any page,
        // so there is nothing to keep it apart from.
        let generation: Int? = state.withLock { state in
            if !key.isEmpty, let existing = state.asks[key] {
                if existing.question == question { return nil }
                // A differing text is a revision only if its question ended later. A late
                // ask of the half a question was revised from would otherwise cancel the
                // revision's answer and answer the half again.
                if let was = existing.t1, let now = t1, now <= was { return nil }
                existing.task?.cancel()
            }
            state.askGeneration += 1
            if !key.isEmpty {
                state.asks[key] = AskRecord(
                    question: question, generation: state.askGeneration, t1: t1, task: nil)
                Self.forgetOldestAsks(in: &state)
            }
            return state.askGeneration
        }
        guard let generation else { return }

        let accumulated = Mutex<String>("")
        let wasTruncated = Mutex<Bool>(false)
        let task = onAsk(payload) { [weak self] chunk in
            guard let self, self.isCurrentAsk(key: key, generation: generation) else { return }
            switch chunk {
            case let .text(text):
                accumulated.withLock { $0 += text }
                // Live only, never backlogged: an answer is hundreds of small frames, and
                // remembering them would evict the whole question history from replay.
                self.broadcastLive(
                    "{\"type\":\"answer\",\"key\":\(Self.quote(key)),\(forQuestion)"
                    + "\"text\":\(Self.quote(text))}"
                )
            case .truncated:
                wasTruncated.withLock { $0 = true }
            case .done:
                self.rememberAnswered(key: key, generation: generation)
                // Backlogged complete, so a page opened later replays the whole answer
                // rather than reassembling it from deltas it never received.
                let full = accumulated.withLock { $0 }
                let cut = wasTruncated.withLock { $0 }
                self.broadcast(
                    "{\"type\":\"answer_done\",\"key\":\(Self.quote(key)),\(forQuestion)"
                    + "\"text\":\(Self.quote(full))" + ended
                    + (cut ? ",\"truncated\":true" : "") + "}"
                )
            case let .failed(detail):
                self.forgetAsk(key: key, generation: generation)
                self.broadcast(
                    "{\"type\":\"answer_failed\",\"key\":\(Self.quote(key)),\(forQuestion)"
                    + "\"detail\":\(Self.quote(detail))}"
                )
            }
        }
        state.withLock { state in
            // Unless it already finished, or was overtaken, while the handler was starting.
            if !key.isEmpty, let record = state.asks[key],
               record.generation == generation, !record.finished
            {
                state.asks[key]?.task = task
            }
        }
    }

    /// Whether frames from this ask should still reach the pages.
    private func isCurrentAsk(key: String, generation: Int) -> Bool {
        key.isEmpty || state.withLock { $0.asks[key]?.generation == generation }
    }

    /// Marks an answer finished. The record stays, so the same question is not answered
    /// again; only a revision or a failure starts afresh.
    private func rememberAnswered(key: String, generation: Int) {
        state.withLock { state in
            guard state.asks[key]?.generation == generation else { return }
            state.asks[key]?.task = nil
            state.asks[key]?.finished = true
        }
    }

    /// Forgets an ask that failed, so the next ask under its key is a fresh attempt.
    private func forgetAsk(key: String, generation: Int) {
        state.withLock { state in
            if state.asks[key]?.generation == generation { state.asks[key] = nil }
        }
    }

    /// Keeps the answered set the size of the backlog, dropping the oldest. A finished
    /// answer older than everything still replayed cannot be asked again by a page that
    /// was never shown its question.
    private static func forgetOldestAsks(in state: inout State) {
        while state.asks.count > backlogLimit,
              let oldest = state.asks.min(by: { $0.value.generation < $1.value.generation })
        {
            oldest.value.task?.cancel()
            state.asks[oldest.key] = nil
        }
    }

    /// Whether a control body asks for a capture change as well as, or instead of, a scroll.
    static func carriesCaptureState(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["mic"] != nil || root["tap"] != nil
    }

    /// Whether a request came from the page this server serves, rather than another site.
    ///
    /// A POST to `/ask` or `/control` spends the owner's Anthropic credit or stops the
    /// capture, and a browser will send one cross-origin without asking anyone: a JSON body
    /// labelled `text/plain` is a CORS "simple request", so it never preflights. On loopback
    /// there is no token to stop it, so until this check any page in any tab could pause the
    /// tap mid-interview or spend the key on questions of its own — each one carrying the
    /// owner's prepared notes as the system prompt. Reproduced against a real browser.
    ///
    /// `Sec-Fetch-Site` is the browser's own word for who asked, and it cannot be forged by
    /// script; every browser new enough to run this page sends it. `Origin` is checked as
    /// well for anything that sends one without the metadata headers, and must name the same
    /// authority the request was addressed to.
    ///
    /// A client sending neither — curl, a script, the tests — is let through: it is not a
    /// browser being used as the owner, on loopback it could read the session file instead,
    /// and on the LAN it still needs the token.
    static func isSameOrigin(_ request: HTTPRequest) -> Bool {
        if let site = request.headers["sec-fetch-site"] { return site == "same-origin" }
        guard let origin = request.headers["origin"] else { return true }
        guard let host = request.headers["host"] else { return false }
        return origin == "http://\(host)"
    }

    /// Whether the body is declared as JSON, which is what the page sends.
    ///
    /// The second half of the same-origin defence, and the half that does not depend on the
    /// browser volunteering anything: the three content types a cross-origin POST may carry
    /// without a preflight are all refused here, so a browser too old to send
    /// `Sec-Fetch-Site` must ask permission first — and this server answers no preflight,
    /// because `OPTIONS` is not an allowed method.
    static func isJSONBody(_ request: HTTPRequest) -> Bool {
        guard let type = request.headers["content-type"] else { return false }
        return type.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// Whether a `Host` header names this machine in a way a real client would.
    ///
    /// Addresses and `.local` names only. A browser reaches the page by IP or by the Bonjour
    /// name, never by a registered domain, so rejecting those loses nothing and removes DNS
    /// rebinding as a way to reach a loopback server from a hostile page.
    static func isAcceptableHost(_ header: String) -> Bool {
        var host = header
        // An IPv6 literal must be bracketed in a Host header, which is what makes the port
        // unambiguous. Anything unbracketed therefore has at most one colon, and treating a
        // surviving one as proof of IPv6 let `evil.example.com:8080:7373` through.
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            return inner.contains(":") && inner.allSatisfy {
                $0.isHexDigit || $0 == ":" || $0 == "%" || $0.isLetter || $0.isNumber
            }
        }
        if let colon = host.lastIndex(of: ":") {
            host = String(host[host.startIndex..<colon])
        }
        guard !host.contains(":") else { return false }
        host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    /// The `scroll` field of a control payload, re-serialised, or nil when there is none.
    ///
    /// Rebuilt from the parsed values rather than passed through as received: the body is
    /// echoed to every other page, and forwarding a caller's raw JSON would let anything
    /// they put in it reach every viewer.
    static func scrollAnchor(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scroll = root["scroll"] as? [String: Any],
              let index = scroll["index"] as? Int,
              let into = scroll["into"] as? Double,
              index >= 0, into.isFinite
        else { return nil }
        return "{\"index\":\(index),\"into\":\(String(format: "%.4f", into))}"
    }

    /// The question an ask is for. Compared, never interpreted: it is what tells a second
    /// device asking the same thing apart from a revision of the question.
    static func askQuestion(in payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let question = root["question"] as? String
        else { return "" }
        return question
    }

    /// When the asked question ended, if the page said.
    static func askEndTime(in payload: String) -> Double? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t1 = root["t1"] as? Double, t1.isFinite
        else { return nil }
        return t1
    }

    /// The page supplies the key so both sides agree on its exact spelling; the server only
    /// echoes it back on the frames it emits.
    static func askKey(in payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["key"] as? String
        else { return "" }
        return key
    }

    private static let streamHeaders = """
    HTTP/1.1 200 OK
    Content-Type: text/event-stream
    Cache-Control: no-store
    Connection: keep-alive
    

    """

    /// Reuses the event encoder's escaping so an answer containing a quote, a backslash or
    /// a newline cannot break the frame it travels in.
    private static func quote(_ s: String) -> String { EventEncoder.quote(s) }

    private func send(_ text: String, on connection: NWConnection, close: Bool) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    private static func response(
        status: String, body: String, contentType: String = "text/plain; charset=utf-8"
    ) -> String {
        let bytes = body.utf8.count
        return """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bytes)\r
        Connection: close\r
        \r
        \(body)
        """
    }

    /// Best-effort LAN address, so `--listen` prints a URL the iPad can actually open
    /// rather than `0.0.0.0`.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidate: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            // en0 is Wi-Fi on this hardware; prefer it, but take any non-loopback address
            // rather than printing nothing.
            if String(cString: ptr.pointee.ifa_name) == "en0" { return name }
            if candidate == nil { candidate = name }
        }
        return candidate
    }

    public enum Failure: Error, CustomStringConvertible {
        case badPort(UInt16)
        case notListening(UInt16, String)
        public var description: String {
            switch self {
            case let .badPort(p): "invalid port \(p)"
            case let .notListening(p, why): "could not listen on port \(p): \(why)"
            }
        }
    }
}
