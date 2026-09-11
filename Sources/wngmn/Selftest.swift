import AVFoundation
import Foundation
import WngmnAudio
import WngmnCore

/// `wngmn selftest` — the go/no-go gate, run on the morning of an interview.
///
/// It has to be an *active* probe. A silent TCC denial returns `noErr` from every Core Audio
/// call and hands back pure digital silence, and the passive alternative — "did we see three
/// seconds of zeros" — cannot distinguish it from a quiet room, because the tap legitimately
/// delivers nothing when the tapped output device is not clocking. So this plays a known
/// tone and asserts the tap hears it.
///
/// It also separates the two failure modes explicitly, because they look identical from the
/// outside and have completely different fixes: *no buffers at all* means the capture graph
/// is not clocking, *buffers full of zeros* means the recording permission is missing.
enum Selftest {
    private static let toneHz: Double = 440
    private static let toneAmplitude: Float = 0.15
    /// Well above the noise floor of a real capture, well below the tone's own level.
    private static let passThreshold: Float = 0.001

    static func run(options: Options, writer: EventWriter, teardown: TeardownCoordinator) async -> Bool {
        let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "(unknown)"
        EventWriter.note("wngmn selftest — playing a \(Int(toneHz)) Hz tone for \(Int(options.selftestSeconds))s.")
        EventWriter.note("  terminal app: \(terminal)  (the System Audio Recording grant belongs to this app, not to wngmn)")

        // Always a global tap: the tone comes from this process, so a tap scoped to Zoom or
        // Chrome would correctly capture nothing and the result would mean nothing.
        var configuration = SystemAudioTap.Configuration()
        configuration.globalTap = true
        configuration.keepOutputAlive = options.keepOutputAlive
        let tap = SystemAudioTap(configuration: configuration)
        teardown.onTeardown { tap.teardown() }

        do {
            try tap.start()
        } catch {
            EventWriter.note("FAIL  could not build the capture graph: \(error)")
            writer.emit(.error(code: "selftest_setup", detail: "\(error)"))
            return false
        }
        writer.emit(.status(
            state: "selftest",
            format: StreamFormat(rate: tap.format.sampleRate, ch: Int(tap.format.channelCount)),
            detail: "terminal=\(terminal)"
        ))

        let tone = ToneGenerator()
        let tonePlaying = tone.start()
        if !tonePlaying {
            EventWriter.note("  WARNING: audio playback would not start. A silent result below proves nothing —")
            EventWriter.note("           there was no tone to hear. Check the output device and volume.")
        }

        var peak: Float = 0
        var sumSquares: Double = 0
        var counted: UInt64 = 0
        var nonZero: UInt64 = 0
        var scratch = [Float](repeating: 0, count: 16_384)

        let deadline = Date().addingTimeInterval(options.selftestSeconds)
        while Date() < deadline {
            while let segment = (scratch.withUnsafeMutableBufferPointer {
                tap.ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
            }) {
                for i in 0..<segment.frameCount {
                    let sample = scratch[i]
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    if magnitude > 0 { nonZero += 1 }
                    sumSquares += Double(sample) * Double(sample)
                    counted += 1
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        tone.stop()
        let diagnostics = tap.diagnostics
        tap.teardown()

        let rms = counted > 0 ? (sumSquares / Double(counted)).squareRoot() : 0
        let dB = rms > 0 ? 20 * log10(rms) : -.infinity
        writer.emit(.metric(name: "selftest_peak", value: Double(peak), unit: "amplitude"))
        writer.emit(.metric(name: "selftest_rms_db", value: dB.isFinite ? dB : -120, unit: "dBFS"))
        writer.emit(.metric(name: "selftest_frames", value: Double(counted), unit: "frames"))

        EventWriter.note("")
        EventWriter.note("  IOProc callbacks : \(diagnostics.callbacks)")
        EventWriter.note("  frames captured  : \(counted)")
        EventWriter.note("  non-zero samples : \(nonZero)")
        EventWriter.note(String(
            format: "  peak / rms       : %.6f / %.1f dBFS",
            Double(peak), dB.isFinite ? dB : -120.0
        ))
        EventWriter.note("")

        if diagnostics.callbacks == 0 {
            EventWriter.note("FAIL  The IOProc never fired — the capture graph is not clocking.")
            EventWriter.note("      The tap-backed aggregate only runs while the tapped OUTPUT device is running.")
            if !options.keepOutputAlive {
                EventWriter.note("      You passed --no-keepalive, which removes the silent IOProc that guarantees this.")
            }
            EventWriter.note("      Check `wngmn devices` for the default output device, and that it is alive.")
            writer.emit(.error(code: "selftest_no_buffers", detail: "IOProc never fired"))
            return false
        }

        if counted == 0 {
            EventWriter.note("FAIL  The IOProc fired but no frames reached the consumer.")
            EventWriter.note("      This is not a permission problem — nothing was examined, so nothing")
            EventWriter.note("      can be concluded about the grant. Re-run; if it persists, it is a bug.")
            writer.emit(.error(code: "selftest_no_frames", detail: "callbacks fired but zero frames drained"))
            return false
        }

        if nonZero == 0 {
            EventWriter.note("FAIL  Buffers arrived, and every sample was digital silence.")
            if !tonePlaying {
                EventWriter.note("      NOTE: playback never started, so this may be the tone's absence rather")
                EventWriter.note("      than a denied grant. Fix playback and re-run before concluding.")
            }
            EventWriter.note("      This is what a denied System Audio Recording grant looks like: every Core Audio")
            EventWriter.note("      call still returns noErr. The grant belongs to \(terminal), not to wngmn.")
            EventWriter.note("")
            EventWriter.note("      System Settings → Privacy & Security → Screen & System Audio Recording")
            EventWriter.note("        → enable \(terminal), then QUIT AND REOPEN it and run this again.")
            EventWriter.note("      macOS also re-authorises this category about every 30 days, so the prompt")
            EventWriter.note("      can reappear mid-call.")
            writer.emit(.error(code: "selftest_silent", detail: "buffers arrived but all samples were zero"))
            return false
        }

        if peak < passThreshold {
            EventWriter.note(String(format: "FAIL  Captured audio is far too quiet (peak %.6f).", peak))
            EventWriter.note("      Check the output volume, and that the tone was audible.")
            writer.emit(.error(code: "selftest_too_quiet", detail: "peak \(peak)"))
            return false
        }

        EventWriter.note("PASS  The tap hears system audio. Capture is working.")
        if diagnostics.framesDropped > 0 {
            EventWriter.note("      note: \(diagnostics.framesDropped) frames were dropped; the consumer fell behind.")
        }
        return true
    }
}

/// Plays a steady tone through the default output so the tap has something to hear.
private final class ToneGenerator {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func start() -> Bool {
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)
              ), let channels = buffer.floatChannelData
        else { return false }

        buffer.frameLength = buffer.frameCapacity
        let step = 2 * Double.pi * Selftest.toneHzValue / format.sampleRate
        for frame in 0..<Int(buffer.frameLength) {
            let value = Float(sin(step * Double(frame))) * Selftest.toneAmplitudeValue
            for channel in 0..<Int(format.channelCount) { channels[channel][frame] = value }
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return false }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        return engine.isRunning
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

extension Selftest {
    // Bridged out so the private generator can read them.
    static var toneHzValue: Double { toneHz }
    static var toneAmplitudeValue: Float { toneAmplitude }
}
