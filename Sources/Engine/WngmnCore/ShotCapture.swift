import Foundation

/// How much of the screen a shot takes.
public enum ShotMode: String, Sendable, Equatable {
    /// The main display, at once.
    case screen
    /// The native crosshair: drag a rectangle, or press Space for a window. Esc cancels.
    case region
}

/// A picture of the screen, on its way into the conversation.
///
/// Plain data, so it can cross from the executable, which takes the picture, to the answerer,
/// which sends it, without either target importing the other's frameworks.
public struct Shot: Sendable, Equatable {
    /// The PNG, base64-encoded, as the API takes it. The temporary file it came from is
    /// already gone; a copy is kept with the session, unless nothing of the session is.
    public let base64: String
    /// Stream seconds, on the clock the question lines use, so the row sorts and reads with them.
    public let t: Double
    public let mode: ShotMode
    public let width: Int
    public let height: Int
    /// The PNG's size before encoding. Logged, so that a slow turn can be explained afterwards.
    public let byteCount: Int

    public init(base64: String, t: Double, mode: ShotMode, width: Int, height: Int, byteCount: Int) {
        self.base64 = base64
        self.t = t
        self.mode = mode
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }

    /// The key its row and its answer share. Through `EventEncoder.number`, like every other
    /// key: two spellings of one Double is how an answer once failed to find its row.
    public var key: String { "screen@\(EventEncoder.number(t))" }
}

/// The decisions about a screenshot that need no screen.
///
/// Taking the picture needs a display, a Screen Recording grant and, for a region, a person to
/// drag. What to run, whether to shrink the result and whether it can be sent at all are
/// arithmetic, so they are here, where they are tested in any terminal.
public enum ShotCapture {
    /// macOS's own tool. It draws the crosshair, honours the Screen Recording grant of whoever
    /// launched wngmn, and — given a path and no `-u` — writes the file at once, with none of
    /// the ~6 s the floating thumbnail puts between the shutter and a ⇧⌘4 file.
    public static let screencapture = "/usr/sbin/screencapture"
    /// A system tool rather than ImageIO, to keep image frameworks out of wngmn entirely.
    public static let sips = "/usr/bin/sips"

    /// Where the model's high-resolution tier stops. A longer image is downscaled on arrival,
    /// so shrinking it first loses nothing the model would have seen.
    public static let maximumLongEdge = 2576

    /// The API's per-image limit, which is on the base64 form: "10 MB (base64-encoded) when
    /// using the Claude API directly". Taken as ten million bytes, the smaller reading.
    public static let maximumBase64Bytes = 10_000_000

    /// How long a crosshair may sit unanswered before it is taken down.
    public static let regionTimeoutSeconds = 60.0

    public static func captureArguments(mode: ShotMode, path: String) -> [String] {
        // -x: no shutter sound, on a call. -t png: macOS 26 can write an HDR capture, and the
        // API takes JPEG, PNG, GIF and WebP only.
        switch mode {
        case .screen: ["-x", "-t", "png", path]
        case .region: ["-i", "-x", "-t", "png", path]
        }
    }

    public static func downscaleArguments(path: String) -> [String] {
        ["-Z", String(maximumLongEdge), path]
    }

    public static func needsDownscale(width: Int, height: Int) -> Bool {
        max(width, height) > maximumLongEdge
    }

    public static func base64Length(ofByteCount count: Int) -> Int {
        (count + 2) / 3 * 4
    }

    public static func fitsTheAPI(byteCount: Int) -> Bool {
        base64Length(ofByteCount: byteCount) <= maximumBase64Bytes
    }

    /// The size of a PNG, from its header: eight bytes of signature, then an IHDR chunk whose
    /// first two fields are the width and the height, big-endian. Nil for anything else,
    /// rather than two plausible numbers read out of the wrong bytes.
    public static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8)
        else { return nil }
        func bigEndian(_ slice: ArraySlice<UInt8>) -> Int {
            slice.reduce(0) { $0 << 8 | Int($1) }
        }
        return (bigEndian(bytes[16..<20]), bigEndian(bytes[20..<24]))
    }

    /// The time to stamp a shot with: the stream clock, rounded to the millisecond the key is
    /// spelled to, and never at or before the last shot's. Two shots must not share a key, and
    /// the clock can stand still — `offline` has no capture clock, so "now" there is the newest
    /// line seen — or jump backwards. Stepping the unrounded value by a millisecond is not
    /// enough, because two values a millisecond apart can still round to the same key.
    public static func nextT(now: Double, last: Double) -> Double {
        let rounded = (max(now, 0) * 1000).rounded() / 1000
        guard last.isFinite, rounded <= last else { return rounded }
        return ((last * 1000).rounded() + 1) / 1000
    }

    // MARK: - The client, `wngmn shot`

    /// Where `wngmn shot` posts. 127.0.0.1 and nothing else: the route is answered only to
    /// this machine, so there is nowhere else worth asking.
    public static func triggerURL(port: UInt16, token: String?) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/shot"
        if let token { components.queryItems = [URLQueryItem(name: "t", value: token)] }
        // Every part above is a literal or a number; this cannot fail.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    public enum ClientOutcome: Sendable, Equatable {
        case accepted
        case failed(String)
    }

    /// What a reply means. Bound to a key, this command has no terminal and nobody watching
    /// one; the exit status is all a launcher sees, so every refusal is a failure with a reason.
    public static func outcome(status: Int, port: UInt16) -> ClientOutcome {
        switch status {
        case 202:
            .accepted
        case 403:
            .failed("the wngmn on port \(port) refused the token; pass the --token it was started with")
        case 404, 405:
            .failed("the wngmn on port \(port) does not know `shot`; it is an older build, so restart it")
        default:
            .failed("the wngmn on port \(port) answered \(status)")
        }
    }

    public static func unreachable(port: UInt16) -> String {
        "no wngmn is serving on port \(port); start one with --serve, or pass its --port"
    }

    // MARK: - Keeping them

    /// Where a session keeps its screenshots: beside its transcript, in a folder named after
    /// it. A screenshot is as much the history of a call as its lines and its answers, and
    /// without a copy the pictures behind those answers were gone the moment they were read.
    public static func shotsDirectory(forSession log: URL) -> URL {
        log.deletingPathExtension().appendingPathExtension("shots")
    }

    /// Named by the key the transcript already gives the row, so a picture, its row and its
    /// answer go by one name.
    public static func keptFile(for shot: Shot, in directory: URL) -> URL {
        directory.appendingPathComponent("\(shot.key).png")
    }

    // MARK: - After a restart

    /// Frames that close screenshots a restored log left asking. A shot row is born asking and
    /// only a frame under its key ends that; if wngmn died with the request in flight,
    /// `--resume` brings the row back and nothing will ever answer it, because the
    /// conversation that held the picture did not survive the restart.
    public static func framesClosingUnansweredShots(in restored: [String]) -> [String] {
        var asking: [String] = []
        for line in restored {
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = frame["type"] as? String, let key = frame["key"] as? String
            else { continue }
            switch type {
            case "shot": if !asking.contains(key) { asking.append(key) }
            case "answer_done", "answer_failed": asking.removeAll { $0 == key }
            default: break
            }
        }
        return asking.map { key in
            #"{"type":"answer_failed","key":\#(EventEncoder.quote(key)),"#
                + #""detail":"wngmn stopped before this screenshot was answered"}"#
        }
    }

    /// What `wngmn shot` posts to the running wngmn. A few bytes on purpose: the server drops
    /// any request over 64 KiB and reads bodies as text, so the picture itself never crosses it.
    public static func triggerBody(mode: ShotMode) -> String {
        #"{"mode":"\#(mode.rawValue)"}"#
    }
}
