import Foundation

/// How much of the screen a shot takes.
public enum ShotMode: String, Sendable, Equatable, CaseIterable {
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
    /// The PNG, base64-encoded, as the API takes it. The file it came from is already deleted.
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

    /// What `wngmn shot` posts to the running wngmn. A few bytes on purpose: the server drops
    /// any request over 64 KiB and reads bodies as text, so the picture itself never crosses it.
    public static func triggerBody(mode: ShotMode) -> String {
        #"{"mode":"\#(mode.rawValue)"}"#
    }
}
