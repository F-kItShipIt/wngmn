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

/// A screenshot is part of the call's history, like the lines and the answers, and is kept
/// with the rest of it: beside the transcript, named after it. Without that, the pictures
/// behind a call's answers were gone the moment they were read, and asked for afterwards,
/// there was nothing to give.
@Suite("Kept screenshots")
struct KeptShotTests {
    let log = URL(fileURLWithPath: "/tmp/wngmn/sessions/2026-09-21T10-57-39.jsonl")

    @Test("They sit beside the session's transcript, in a folder named after it")
    func besideTheLog() {
        let directory = ShotCapture.shotsDirectory(forSession: log)
        #expect(directory.path == "/tmp/wngmn/sessions/2026-09-21T10-57-39.shots")
    }

    /// Named by the key the log already uses for the row, so a picture, its row and its
    /// answer are found by the same name.
    @Test("Each is named by its row's key")
    func namedByKey() {
        let shot = Shot(base64: "", t: 181.292, mode: .region, width: 1, height: 1, byteCount: 1)
        let file = ShotCapture.keptFile(for: shot, in: ShotCapture.shotsDirectory(forSession: log))
        #expect(file.lastPathComponent == "screen@181.292.png")
        #expect(file.lastPathComponent == "\(shot.key).png")
    }

    /// `--resume` continues the same transcript, so it continues the same folder.
    @Test("A resumed session keeps adding to the same folder")
    func resumed() {
        #expect(ShotCapture.shotsDirectory(forSession: log) == ShotCapture.shotsDirectory(forSession: log))
    }
}

/// A shot's row is keyed by its time, rounded to the millisecond, so two shots must never
/// round to the same one.
@Suite("Shot clock")
struct ShotClockTests {
    @Test("A shot is stamped with the stream time, to the millisecond")
    func usesTheClock() {
        #expect(ShotCapture.nextT(now: 83.41249, last: -.infinity) == 83.412)
    }

    /// `offline` has no capture clock, so `now` is the newest line seen and stands still between
    /// lines. Stepping the *unrounded* value by a millisecond is not enough: 5.0004 and 5.0014
    /// are a millisecond apart and both round to keys a reader would take for different rows
    /// only by luck. Stepping from the rounded value cannot collide.
    @Test("On a clock that stands still, each shot is a millisecond after the last")
    func neverRepeats() {
        var last = -Double.infinity
        var keys = Set<String>()
        for _ in 0..<500 {
            last = ShotCapture.nextT(now: 5.0004, last: last)
            keys.insert(EventEncoder.number(last))
        }
        #expect(keys.count == 500)
    }

    @Test("A clock that jumps backwards does not take the shots back with it")
    func neverGoesBackwards() {
        let first = ShotCapture.nextT(now: 90, last: -.infinity)
        let second = ShotCapture.nextT(now: 12, last: first)
        #expect(second > first)
    }
}

/// The half of `wngmn shot` that is not a network call. The executable has no test target,
/// so whatever it decides has to be decided here to be tested at all.
@Suite("Shot client")
struct ShotClientTests {
    @Test("It posts to this machine, and only this machine")
    func triggerURL() {
        #expect(ShotCapture.triggerURL(port: 7373, token: nil).absoluteString == "http://127.0.0.1:7373/shot")
        #expect(ShotCapture.triggerURL(port: 7400, token: "abcd2345").absoluteString
                == "http://127.0.0.1:7400/shot?t=abcd2345")
    }

    /// Bound to a key, this command has no terminal to print to and nobody watching one. The
    /// exit status is all a launcher sees, so every refusal is a failure and says why.
    @Test("Each way of being refused says what to do about it")
    func outcomes() {
        #expect(ShotCapture.outcome(status: 202, port: 7373) == .accepted)
        let cases: [(Int, String)] = [
            (403, "--token"), (404, "restart"), (405, "restart"), (503, "503"), (400, "400"), (0, "0"),
        ]
        for (status, hint) in cases {
            guard case let .failed(why) = ShotCapture.outcome(status: status, port: 7373) else {
                Issue.record("\(status) was accepted"); continue
            }
            #expect(why.contains(hint), "\(status): \(why)")
        }
        #expect(ShotCapture.unreachable(port: 7400).contains("7400"))
        #expect(ShotCapture.unreachable(port: 7400).contains("--serve"))
    }
}

/// A shot row is born asking, and only a frame under its key ends that. If wngmn died with a
/// request in flight, `--resume` replays the row and nothing will ever answer it: the
/// conversation that held the picture is gone.
@Suite("Resumed screenshots")
struct ResumedShotTests {
    let shot5 = #"{"type":"shot","key":"screen@5","t":5,"mode":"region","w":10,"h":10,"bytes":9}"#
    let shot9 = #"{"type":"shot","key":"screen@9","t":9,"mode":"screen","w":10,"h":10,"bytes":9}"#

    @Test("A restored screenshot with no answer is closed, with the reason")
    func closesTheUnanswered() {
        let frames = ShotCapture.framesClosingUnansweredShots(in: [
            #"{"type":"question","text":"Hello?","t0":1,"t1":2,"ms":90}"#, shot5,
            #"{"type":"answer_done","key":"screen@5","text":"A merge."}"#, shot9,
        ])
        #expect(frames.count == 1)
        #expect(frames[0].contains(#""type":"answer_failed""#))
        #expect(frames[0].contains(#""key":"screen@9""#))
        #expect(frames[0].contains("stopped before"))
    }

    @Test("An answered or already-failed screenshot is left alone, and so is everything else")
    func leavesTheRestAlone() {
        #expect(ShotCapture.framesClosingUnansweredShots(in: [
            shot5, #"{"type":"answer_failed","key":"screen@5","detail":"HTTP 413"}"#,
            #"{"type":"answer_done","key":"caller@3","text":"x"}"#, "not json at all", "",
        ]).isEmpty)
        #expect(ShotCapture.framesClosingUnansweredShots(in: []).isEmpty)
    }
}
