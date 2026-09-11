import Foundation
import WngmnAudio
import WngmnCore

/// Measures this room and this voice, and prints the `--mic-open-db` to use.
///
/// Written because the alternative was guessing. The shipped default of −35 dBFS was a
/// starting point set without measurement, and both it and the values chosen afterwards
/// failed in the same invisible way: partial text scrolling in the caption line while no
/// question ever finalised. That symptom is identical whether the threshold is too low or
/// too high, which is exactly why it needs an instrument rather than another guess.
enum MicCheck {
    /// The endpointer's own analysis window, so the numbers here are directly comparable to
    /// `openThresholdDB` rather than to a peak meter.
    /// One continuous recording rather than timed phases.
    ///
    /// The two-phase version asked the user to talk on cue, and any wrapper that buffers
    /// output — a shell integration, a CI log, this tool run through an assistant — delays
    /// the cue until after the window has closed. The measurement then inverts and reports
    /// the room as louder than the voice. Recording once and separating by level afterwards
    /// removes the dependency: it no longer matters *when* the talking happened.
    private static let recordSeconds: Double = 15

    static func run(options: Options, writer: EventWriter) async -> Bool {
        let mic = MicCapture(configuration: .init(deviceUID: options.micDeviceUID))
        do {
            try mic.start()
        } catch {
            EventWriter.note("wngmn: cannot open the microphone: \(error)")
            return false
        }
        defer { mic.stop() }

        let deviceName = AudioCatalog.deviceName(mic.deviceID)
        let device = AudioCatalog.devices().first { $0.objectID == mic.deviceID }
        EventWriter.note("wngmn miccheck — measuring \(deviceName).")
        if options.micDeviceUID == nil {
            // The default input is not necessarily the one wngmn will run with, and a
            // threshold measured on the wrong microphone is worse than none: it looks
            // authoritative and describes a device that is not in the path.
            EventWriter.note("  (this is the system default input; pass --mic-device to measure another)")
        }
        EventWriter.note("")
        if device?.isBluetooth == true {
            EventWriter.note("  WARNING  This is a Bluetooth microphone. Using it puts the link into")
            EventWriter.note("           duplex mode, and while it is there the process tap captures")
            EventWriter.note("           nothing — the caller's audio disappears silently.")
            EventWriter.note("           Measure the built-in microphone instead:")
            EventWriter.note("             wngmn miccheck --mic-device BuiltInMicrophoneDevice")
            EventWriter.note("")
        }
        EventWriter.note("  Recording for \(Int(recordSeconds))s starting NOW.")
        EventWriter.note("")
        EventWriter.note("  Talk for roughly half of it, at the volume and distance you would")
        EventWriter.note("  use on the call, and stay quiet for the rest. The order does not")
        EventWriter.note("  matter — the room and your voice are separated by level, not timing.")
        EventWriter.note("")
        _ = await windows(mic, seconds: 1)   // discard the device settling
        let samples = await windows(mic, seconds: recordSeconds)
        EventWriter.note("  Done.")
        EventWriter.note("")

        guard mic.diagnostics.frames > 0 else {
            EventWriter.note("  FAIL  No audio at all. Microphone access is granted to the terminal")
            EventWriter.note("        app, not to wngmn — check System Settings > Privacy & Security.")
            return false
        }
        guard let result = MicCalibration.recommend(
            samples: samples, hysteresisDB: options.micEndpointer.hysteresisDB
        ) else {
            EventWriter.note("  FAIL  Not enough samples to measure.")
            return false
        }

        writer.emit(.metric(name: "mic_ambient_db", value: result.ambientHighDB, unit: "dBFS"))
        writer.emit(.metric(name: "mic_speech_db", value: result.speechHighDB, unit: "dBFS"))
        writer.emit(.metric(name: "mic_recommended_db", value: result.recommended, unit: "dBFS"))

        EventWriter.note(String(format: "  room (loud end)   %6.1f dBFS", result.ambientHighDB))
        EventWriter.note(String(format: "  voice (loud end)  %6.1f dBFS", result.speechHighDB))
        EventWriter.note(String(format: "  separation        %6.1f dB", result.separationDB))
        EventWriter.note("")

        if result.confident {
            EventWriter.note(String(format: "  PASS  Use:  --mic-open-db %.0f", result.recommended))
            EventWriter.note("")
            EventWriter.note("        Below that the detector never hears silence and no question")
            EventWriter.note("        finalises; above it your voice never opens it at all.")
            return true
        }

        EventWriter.note(String(format: "  MARGINAL  Best available:  --mic-open-db %.0f", result.recommended))
        EventWriter.note("")
        EventWriter.note("        Your voice and the room are within \(Int(result.separationDB.rounded())) dB of each other, so no")
        EventWriter.note("        threshold separates them cleanly.")
        EventWriter.note("")
        if result.separationDB < 2 {
            // The overwhelmingly common cause, and the one worth naming first.
            EventWriter.note("        A separation this small usually means no speech was recorded at")
            EventWriter.note("        all. Run it again and talk through the middle of the recording.")
        } else {
            EventWriter.note("        Move closer to the microphone, use a headset, or quiet the room,")
            EventWriter.note("        then run this again.")
        }
        return false
    }

    /// Per-window RMS in dBFS, drained from the capture ring.
    private static func windows(_ mic: MicCapture, seconds: Double) async -> [Double] {
        var out: [Double] = []
        var scratch = [Float](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            while let peek = mic.ring.peekSegment() {
                if peek.frameCount > scratch.count {
                    scratch = [Float](repeating: 0, count: peek.frameCount * 2)
                }
                guard let segment = scratch.withUnsafeMutableBufferPointer({
                    mic.ring.readSegment(into: $0.baseAddress!, capacity: $0.count)
                }) else { break }
                guard segment.frameCount > 0 else { continue }
                var sum = 0.0
                for i in 0..<segment.frameCount {
                    let sample = Double(scratch[i])
                    sum += sample * sample
                }
                let rms = (sum / Double(segment.frameCount)).squareRoot()
                out.append(20 * log10(max(rms, 1e-9)))
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return out
    }
}
