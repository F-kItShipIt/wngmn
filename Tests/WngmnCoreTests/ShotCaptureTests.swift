import Foundation
import Testing
@testable import WngmnCore

/// The decisions about a screenshot that need no screen.
///
/// Taking the picture needs a display, a Screen Recording grant and, for a region, a person to
/// drag — none of which a test has. What to run, whether to shrink the result and whether it
/// can be sent at all are arithmetic, so they live here and are asserted in any terminal.
@Suite("ShotCapture")
struct ShotCaptureTests {
    /// A PNG header for an image of the given size: the signature, then an IHDR chunk. Nothing
    /// after the dimensions is read, so nothing after them is built.
    func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])   // signature
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])                     // IHDR length, 13
        data.append(contentsOf: Array("IHDR".utf8))
        for value in [width, height] {
            data.append(contentsOf: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) })
        }
        return data
    }

    /// `-t png` is not decoration. macOS 26 can write an HDR capture, and the API takes JPEG,
    /// PNG, GIF and WebP only.
    @Test("The whole screen is captured silently, as a PNG")
    func wholeScreenArguments() {
        #expect(ShotCapture.captureArguments(mode: .screen, path: "/tmp/s.png")
                == ["-x", "-t", "png", "/tmp/s.png"])
    }

    @Test("A region adds the interactive crosshair and nothing else")
    func regionArguments() {
        #expect(ShotCapture.captureArguments(mode: .region, path: "/tmp/s.png")
                == ["-i", "-x", "-t", "png", "/tmp/s.png"])
    }

    /// 2576 px is where the model's high-resolution tier stops: anything longer is downscaled
    /// on arrival anyway, so shrinking it first loses nothing the model would have seen and
    /// saves the upload — which is paid again on every later turn, since the picture stays in
    /// the conversation.
    @Test("Only a picture longer than the model's long edge is shrunk")
    func downscaleDecision() {
        #expect(!ShotCapture.needsDownscale(width: 2576, height: 1449))
        #expect(!ShotCapture.needsDownscale(width: 1500, height: 900))
        #expect(ShotCapture.needsDownscale(width: 3600, height: 2338))
        #expect(ShotCapture.needsDownscale(width: 900, height: 2577), "the long edge can be the height")
        #expect(ShotCapture.downscaleArguments(path: "/tmp/s.png") == ["-Z", "2576", "/tmp/s.png"])
    }

    /// The API's limit is on the base64 form, which is a third larger than the file.
    @Test("The size limit is judged on the base64 form, not the file")
    func sizeLimitIsOnTheEncodedForm() {
        #expect(ShotCapture.base64Length(ofByteCount: 3) == 4)
        #expect(ShotCapture.base64Length(ofByteCount: 4) == 8, "padding rounds up to a whole group")
        #expect(ShotCapture.base64Length(ofByteCount: 0) == 0)

        #expect(ShotCapture.fitsTheAPI(byteCount: 7_500_000))
        #expect(!ShotCapture.fitsTheAPI(byteCount: 7_500_001), "10,000,004 encoded bytes")
        #expect(!ShotCapture.fitsTheAPI(byteCount: 9_000_000), "under 10 MB as a file, over it encoded")
    }

    /// Read from the header rather than through ImageIO, which would bring an image framework
    /// into a tool that has none, to learn two integers.
    @Test("A PNG's size is read from its header")
    func readsDimensions() throws {
        let size = try #require(ShotCapture.pngDimensions(pngHeader(width: 3600, height: 2338)))
        #expect(size.width == 3600)
        #expect(size.height == 2338)
    }

    @Test("Something that is not a PNG has no size, rather than a wrong one")
    func rejectsNonPNG() {
        #expect(ShotCapture.pngDimensions(Data("not a png at all, just text".utf8)) == nil)
        #expect(ShotCapture.pngDimensions(Data()) == nil)
        #expect(ShotCapture.pngDimensions(pngHeader(width: 10, height: 10).prefix(20)) == nil,
                "a header cut short before the height")
        var wrongChunk = pngHeader(width: 10, height: 10)
        wrongChunk.replaceSubrange(12..<16, with: Array("IDAT".utf8))
        #expect(ShotCapture.pngDimensions(wrongChunk) == nil, "the first chunk must be IHDR")
    }

    @Test("A mode is spelled on the wire the way it is typed")
    func modeSpelling() {
        #expect(ShotMode(rawValue: "screen") == .screen)
        #expect(ShotMode(rawValue: "region") == .region)
        #expect(ShotMode(rawValue: "window") == nil)
        #expect(ShotCapture.triggerBody(mode: .region) == #"{"mode":"region"}"#)
    }
}
