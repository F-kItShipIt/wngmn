import CoreGraphics
import Foundation
import Synchronization
import WngmnAsk
import WngmnAudio
import WngmnCore
import WngmnServe

/// `wngmn shot`: ask the wngmn that is already running to take a picture of the screen.
///
/// A client and nothing else. It is dispatched before `main` builds anything — before the
/// profile, the server, the signal handlers — because everywhere else `--port` means "serve on
/// this port", and a `shot` that got that far would try to bind the port it is posting to.
///
/// What it decides — the URL, and what each reply means — lives in `ShotCapture`, in
/// `WngmnCore`, because this target has no tests. What is left here is the one network call.
enum ShotClient {
    static func run(options: Options) async -> Int32 {
        // The server's token is wherever it found it: given on the command line, which is
        // never stored, or in the store. With neither, a loopback-only server has none.
        let token = options.serveToken ?? TokenStore().load()
        var request = URLRequest(url: ShotCapture.triggerURL(port: options.servePort, token: token))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(ShotCapture.triggerBody(mode: options.shotMode).utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch ShotCapture.outcome(status: status, port: options.servePort) {
            case .accepted:
                return 0
            case let .failed(why):
                EventWriter.note("wngmn: \(why)")
                return 1
            }
        } catch {
            EventWriter.note("wngmn: \(ShotCapture.unreachable(port: options.servePort))")
            return 1
        }
    }
}

/// Takes the picture, in the wngmn that is running, and hands it to the answerer.
///
/// An actor so that one capture is in hand at a time: a second keypress while a crosshair is
/// up is dropped rather than stacking a second crosshair on the first.
actor ShotTaker {
    private let answerer: AutoAnswerer
    private let writer: EventWriter
    /// Stream seconds, on the clock the question lines use.
    private let streamNow: @Sendable () -> Double

    private var isTaking = false
    private var grantSeen = false
    private var grantRequested = false
    private var lastT = -Double.infinity

    init(answerer: AutoAnswerer, writer: EventWriter, streamNow: @escaping @Sendable () -> Double) {
        self.answerer = answerer
        self.writer = writer
        self.streamNow = streamNow
    }

    func take(_ mode: ShotMode) async {
        guard !isTaking else { return }
        isTaking = true
        defer { isTaking = false }

        guard hasScreenRecordingGrant() else {
            return await fail(
                mode,
                "Screen Recording is not granted to the app that launched wngmn. Grant it in System"
                + " Settings → Privacy & Security → Screen & System Audio Recording, then restart that"
                + " app. Nothing was sent.")
        }

        // Private to this user, and gone again before anything is sent.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wngmn-shot-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return await fail(mode, "could not make a temporary directory for the screenshot: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")

        _ = await BoundedProcess.run(
            ShotCapture.screencapture,
            ShotCapture.captureArguments(mode: mode, path: file.path),
            timeout: mode == .region ? ShotCapture.regionTimeoutSeconds : 15)

        guard var data = try? Data(contentsOf: file) else {
            // No file. Under the crosshair that is Esc, or a minute of nobody dragging, and
            // neither is worth a word. For the whole screen there is no such innocent reading.
            if mode == .screen { await fail(mode, "screencapture produced no image") }
            return
        }
        guard var size = ShotCapture.pngDimensions(data) else {
            return await fail(mode, "screencapture wrote something that is not a PNG")
        }

        if ShotCapture.needsDownscale(width: size.width, height: size.height) {
            _ = await BoundedProcess.run(
                ShotCapture.sips, ShotCapture.downscaleArguments(path: file.path), timeout: 15)
            // If sips failed the file is untouched, and the picture goes at full size: the API
            // downscales it on arrival, so that costs upload time and nothing else.
            if let smaller = try? Data(contentsOf: file), let shrunk = ShotCapture.pngDimensions(smaller) {
                data = smaller
                size = shrunk
            }
        }

        guard ShotCapture.fitsTheAPI(byteCount: data.count) else {
            return await fail(
                mode,
                "the screenshot is \(data.count / 1_000_000) MB, more than the API takes in one image."
                + " Drag a smaller region. Nothing was sent.")
        }

        await answerer.shot(Shot(
            base64: data.base64EncodedString(), t: uniqueT(), mode: mode,
            width: size.width, height: size.height, byteCount: data.count))
    }

    /// Checked until it has once been true, and not only on the first shot: a check made once
    /// would warn once and send the wallpaper the second time. Without the grant
    /// `screencapture` does not fail — it returns the desktop with no windows on it — which is
    /// the same silent denial the audio tap has, and is handled the same way: tested, not
    /// assumed.
    ///
    /// The first refusal also asks. `CGPreflightScreenCaptureAccess` never prompts and never
    /// registers anything, so without the request the app would not even appear in the
    /// Settings list for the user to tick.
    private func hasScreenRecordingGrant() -> Bool {
        if grantSeen { return true }
        grantSeen = CGPreflightScreenCaptureAccess()
        if !grantSeen, !grantRequested {
            grantRequested = true
            _ = CGRequestScreenCaptureAccess()
        }
        return grantSeen
    }

    /// The row's key is built from `t`, so two shots must never share one. They can when no
    /// capture clock is running — `offline` has none — and `t` falls back to the last line seen.
    private func uniqueT() -> Double {
        let t = max(streamNow(), lastT + 0.001)
        lastT = t
        return t
    }

    /// A warning, for the log and the side panel, and a row with the reason on it, because the
    /// side panel is the one part of the page a phone does not show.
    private func fail(_ mode: ShotMode, _ detail: String) async {
        writer.emit(.warning(code: "shot_failed", detail: detail))
        await answerer.shotFailed(t: uniqueT(), mode: mode, detail: detail)
    }
}

/// Runs a child process and does not wait for it for ever.
///
/// Nothing else in wngmn bounds a child: `ant` and `scutil` are both waited on with no limit.
/// That is tolerable for tools that return in milliseconds and not for a crosshair, which
/// waits for a person. The `Process` never leaves the one closure that made it, so nothing
/// here needs an escape hatch from Swift 6; only the semaphore and the pid cross a boundary.
enum BoundedProcess {
    /// The child that is running, so that teardown can take a crosshair down with it. SIGINT
    /// from a terminal reaches the child anyway — it shares the process group — but `wngmn
    /// stop` sends SIGTERM to wngmn alone.
    private static let live = Mutex<pid_t?>(nil)

    static func run(_ path: String, _ arguments: [String], timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: false)
                }
                live.withLock { $0 = process.processIdentifier }
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    finished.wait()
                }
                live.withLock { $0 = nil }
                continuation.resume(
                    returning: process.terminationReason == .exit && process.terminationStatus == 0)
            }
        }
    }

    static func terminateLive() {
        if let pid = live.withLock({ $0 }) { kill(pid, SIGTERM) }
    }
}
