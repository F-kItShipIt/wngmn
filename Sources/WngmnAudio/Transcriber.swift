import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

/// On-device transcription: resample the tap's audio into the analyser's format, feed it,
/// and force finalisation the moment the endpointer says the question is over.
///
/// Forcing finalisation is the whole latency story. Waiting for the framework's own
/// `isFinal` costs 857–921 ms after the last speech sample, measured; dispatching
/// `finalize(through:)` at the VAD endpoint delivers the same text 67–121 ms after
/// dispatch. On a clip with a one-second pause between two questions it is worse than a
/// tie — the framework's final for the first question arrived 770 ms *after the second
/// question had already started*.
///
/// An actor rather than a plain class, because the resampler is genuinely stateful — a
/// second pass on the same instance without `reset()` produces different samples — and it
/// must be driven from one serial context. Making that a compiler-enforced property is
/// cheaper than an audit. The only work that escapes the actor is `finalize(through:)`,
/// which is deliberately detached.
public actor Transcriber {
    public struct Configuration: Sendable {
        public var locale: String = "en-US"
        /// Apple documents `.fastResults` as "faster but also less accurate". Latency now
        /// comes from `finalize(through:)` rather than from waiting on `isFinal`, so
        /// dropping it may cost nothing and improve jargon accuracy. Settle it in rehearsal.
        public var fastResults: Bool = true
        public var volatileResults: Bool = true

        public init() {}
    }

    /// One transcript update from the recogniser.
    ///
    /// `start` and `end` are stream seconds on the caller's timeline — the one every
    /// endpoint is stamped on — not the recogniser's own zero-based count. A non-finite
    /// time, which `CMTimeGetSeconds` returns for an invalid range rather than failing, is
    /// reported as zero so it cannot poison every timestamp downstream.
    public struct Transcript: Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public let isFinal: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case noCompatibleFormat
        case modelUnavailable(String)
        case converterUnavailable(from: String, to: String)
        case bufferAllocationFailed
        case conversion(String)
        case recognitionStopped

        public var description: String {
            switch self {
            case .noCompatibleFormat:
                return "SpeechAnalyzer reported no compatible audio format"
            case let .modelUnavailable(detail):
                return "speech model unavailable: \(detail)"
            case let .converterUnavailable(from, to):
                return "no AVAudioConverter from \(from) to \(to)"
            case .bufferAllocationFailed:
                return "could not allocate an audio buffer"
            case let .conversion(detail):
                return "resampling failed: \(detail)"
            case .recognitionStopped:
                return "the recogniser stopped mid-session; questions after that point were lost"
            }
        }
    }

    public nonisolated let analyzerFormat: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    /// Frames handed to the analyser so far, counted **in the analyser's own sample rate**.
    /// This is the single source of truth for `bufferStartTime`, and it is not optional.
    ///
    /// Deriving the start time from the 48 kHz capture clock instead looks natural and is a
    /// trap: a 512-frame tap buffer resamples to 170 or 171 frames at 16 kHz (170.67
    /// exactly), so a 48 kHz-derived start paired with a 171-frame buffer covers slightly
    /// *past* the next buffer's start. Overlapping input ranges do not degrade gracefully —
    /// they terminate `transcriber.results` with `SFSpeechErrorDomain Code=2`, which kills
    /// transcription for the rest of the session rather than for one buffer.
    ///
    /// Keeping the counter contiguous means gaps must be filled explicitly rather than
    /// skipped: see `advance(toStreamSeconds:)`.
    private var analyzerFrames: Int64 = 0

    /// Where the recogniser's zero sits on the caller's timeline: the stream seconds of the
    /// first `advance(toStreamSeconds:)`, or zero if audio is fed before any.
    ///
    /// The two capture sources share one timeline, so a source's first buffer is rarely at
    /// zero on it — and is *before* zero when its buffers predate the origin the other
    /// source set. Filling silence from zero up to a late start would work; filling up to a
    /// negative one cannot, and skipping the shortfall instead left every time the
    /// recogniser reported offset from the endpointer's by that amount for the whole
    /// session, so no final ever covered the endpoint that asked for it. Anchoring here and
    /// translating on the way out makes both directions the same, trivial case.
    ///
    /// A mutex rather than actor state because the results task translates on the way out.
    private nonisolated let streamOrigin = Mutex<Double?>(nil)

    /// The origin, anchoring it at `streamSeconds` if nothing has yet.
    private nonisolated func origin(anchoringAt streamSeconds: Double) -> Double {
        streamOrigin.withLock { origin in
            if let origin { return origin }
            origin = streamSeconds
            return streamSeconds
        }
    }

    private nonisolated var origin: Double { streamOrigin.withLock { $0 } ?? 0 }

    public nonisolated let transcripts: AsyncStream<Transcript>
    private let transcriptContinuation: AsyncStream<Transcript>.Continuation

    /// - Note: `AssetInventory.reserve(locale:)` is *not* required — verified: a fresh
    ///   process with no reserved locales transcribes correctly.
    public init(configuration: Configuration) async throws {
        var reporting: Set<SpeechTranscriber.ReportingOption> = []
        if configuration.volatileResults { reporting.insert(.volatileResults) }
        if configuration.fastResults { reporting.insert(.fastResults) }

        let module = SpeechTranscriber(
            locale: Locale(identifier: configuration.locale),
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: [.audioTimeRange]
        )
        transcriber = module

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.noCompatibleFormat
        }
        // Measured: 16 kHz, mono, **Int16**, interleaved — not Float32. Reading
        // `floatChannelData` on one of these buffers returns nil.
        analyzerFormat = format

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation
        let (transcripts, transcriptContinuation) = AsyncStream<Transcript>.makeStream()
        self.transcripts = transcripts
        self.transcriptContinuation = transcriptContinuation

        analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [module],
            options: nil,
            analysisContext: AnalysisContext(),
            volatileRangeChangedHandler: nil
        )
    }

    /// Model availability for the configured locale.
    ///
    /// Deliberately checks `installedLocales` rather than `AssetInventory.status`, which
    /// reports *reservation* rather than installation: a fresh process with no reserved
    /// locales reads `.supported` and transcribes perfectly. Gating on the status value
    /// would refuse to start on a machine where everything works.
    public static func isModelInstalled(locale: String) async -> Bool {
        guard let resolved = await resolvedLocale(locale) else { return false }
        let key = normalize(resolved)
        return await SpeechTranscriber.installedLocales.contains { normalize($0) == key }
    }

    public static func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map(\.identifier)
    }

    /// The locale the framework will actually use, e.g. `en-US` -> `en_US`.
    public static func resolvedLocale(_ locale: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale))
    }

    private static func normalize(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Downloads the locale's model. Only invoked explicitly — a 396 MB download is not
    /// something to start by accident an hour before an interview.
    public static func installModel(locale: String) async throws {
        let module = SpeechTranscriber(
            locale: Locale(identifier: locale),
            transcriptionOptions: [], reportingOptions: [], attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return  // Already installed.
        }
        try await request.downloadAndInstall()
    }

    /// Builds the resampler and preloads the model. Call before the first buffer:
    /// `prepareToAnalyze` costs 51–59 ms that would otherwise land on the first question.
    public func prepare(sourceFormat: AVAudioFormat) async throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
            throw Failure.converterUnavailable(
                from: "\(sourceFormat)", to: "\(analyzerFormat)"
            )
        }
        // The default sample-rate converter is not flat across the speech band: measured
        // -2.12 dB at 6 kHz and -5.17 dB at 7 kHz, which is real fricative energy. Minimum
        // phase at maximum quality measured flat to 0.09 dB from 1–7 kHz with *zero* added
        // latency and 0.04% of real time. (Mastering quality is also flat but adds 36 ms of
        // latency, which is a bad trade for live captions.)
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // Unconditional: the default channel map is [0], so if the tap ever comes back as
        // two channels the right one would be silently discarded rather than mixed.
        converter.downmix = true
        self.converter = converter
        self.sourceFormat = sourceFormat

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        resultsTask = Task { [transcriber, transcriptContinuation] in
            do {
                for try await result in transcriber.results {
                    // Translated here, once, so no consumer can forget to.
                    let origin = self.origin
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(result.range.end)
                    transcriptContinuation.yield(Transcript(
                        text: String(result.text.characters),
                        start: origin + (start.isFinite ? start : 0),
                        end: origin + (end.isFinite ? end : 0),
                        isFinal: result.isFinal
                    ))
                }
            } catch {
                // The analyser closed the sequence; the pipeline notices via the stream end.
            }
            transcriptContinuation.finish()
        }
    }

    /// How far along the caller's timeline the analyser has been fed. Because gaps are
    /// filled with silence rather than skipped, this tracks the capture clock, and every
    /// emitted timestamp lives on the same timeline.
    public var cursorSeconds: Double { origin + Double(analyzerFrames) / analyzerFormat.sampleRate }

    /// Resamples one captured chunk and hands it to the analyser.
    public func feed(_ samples: [Float]) throws {
        guard converter != nil, let sourceFormat, !samples.isEmpty else { return }
        // Audio fed before any `advance` sits at zero, as the origin's contract says; a
        // later `advance` then fills from here rather than re-basing what was already fed.
        _ = origin(anchoringAt: 0)

        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = input.floatChannelData else {
            throw Failure.bufferAllocationFailed
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channelData[0].update(from: $0.baseAddress!, count: $0.count) }

        // A zero-frame buffer offered as `.haveData` permanently wedges the resampler: it
        // returns `.endOfStream` and every later push yields nothing until `reset()`, with
        // no error surfaced anywhere. Guarded here and by the `isEmpty` check above.
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        try drain(capacity: capacity) { _, outStatus in
            if let buffer = pending, buffer.frameLength > 0 {
                pending = nil
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
    }

    /// Fills the analyser's timeline with silence up to `streamSeconds`.
    ///
    /// Two situations need this, and both are routine rather than exceptional:
    ///
    /// * A gap in capture. The tap stops delivering buffers when the tapped output device
    ///   is not clocking, so elapsed time cannot be recovered from a frame count. Skipping
    ///   the gap instead would compress the analyser's timeline away from the capture
    ///   clock, and every `t0`/`t1` after it would be wrong.
    /// * Keeping `finalize(through:)` satisfiable. It does not return until input past its
    ///   boundary has been consumed, so a tap that stalls right after a question — which is
    ///   exactly when the endpointer fires — would leave the finalise pending forever, with
    ///   no error and no result. Silence keeps the timeline moving so it always completes.
    /// - Parameter minimumFill: shortfalls smaller than this are ignored. The resampler
    ///   emits 170 or 171 frames for a 512-frame buffer and holds a constant six-frame lag,
    ///   so the cursor sits a hair behind the capture clock at all times. Filling that would
    ///   splice a sub-millisecond silence into the middle of a word on almost every buffer,
    ///   to correct an error far below anything the recogniser or the timestamps care about.
    @discardableResult
    public func advance(toStreamSeconds streamSeconds: Double, minimumFill: Double = 0.02) throws -> Double {
        let rate = analyzerFormat.sampleRate
        // The first call is where the caller's timeline meets the recogniser's: nothing is
        // filled, whatever the stream time, and later calls fill from there.
        let origin = origin(anchoringAt: streamSeconds)
        let target = Int64(((streamSeconds - origin) * rate).rounded())
        guard target > analyzerFrames,
              Double(target - analyzerFrames) / rate >= minimumFill
        else { return 0 }
        let missing = Int(target - analyzerFrames)
        let filled = Double(missing) / rate

        var remaining = missing
        while remaining > 0 {
            let chunk = min(remaining, Int(rate))  // at most one second per buffer
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(chunk)
            ) else { throw Failure.bufferAllocationFailed }
            buffer.frameLength = AVAudioFrameCount(chunk)
            if let data = buffer.int16ChannelData {
                memset(data[0], 0, chunk * MemoryLayout<Int16>.size * Int(buffer.stride))
            }
            yield(buffer)
            remaining -= chunk
        }
        return filled
    }

    /// Runs the resampler's output loop, yielding every produced buffer.
    private func drain(
        capacity: AVAudioFrameCount,
        input: @escaping AVAudioConverterInputBlock
    ) throws {
        guard let converter else { return }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                throw Failure.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            if status == .error {
                throw Failure.conversion(error?.localizedDescription ?? "unknown")
            }
            // `.inputRanDry` and `.endOfStream` can still have written frames, so read
            // frameLength on every status rather than only on `.haveData`.
            if output.frameLength > 0 { yield(output) }
            // `.haveData` means the output buffer hit its capacity: loop, or lose frames.
            if status != .haveData { break }
        }
    }

    /// Hands one buffer to the analyser at the next contiguous position on its timeline.
    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let start = CMTime(value: analyzerFrames, timescale: CMTimeScale(analyzerFormat.sampleRate))
        inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
        analyzerFrames += Int64(buffer.frameLength)
    }

    /// Forces finalisation of everything up to `time`.
    ///
    /// **Must not be awaited from the task feeding audio.** `finalize(through:)` does not
    /// return until input past `time` has been consumed, so awaiting it inline deadlocks
    /// the process outright — verified: zero further results, and a 20 s watchdog had to
    /// hard-exit. A background feeder unblocked the identical inline await in 109 ms.
    public nonisolated func finalize(through time: CMTime) {
        let analyzer = self.analyzer
        Task.detached(priority: .userInitiated) {
            try? await analyzer.finalize(through: time)
        }
    }

    /// Finalise everything handed over so far. Clamped to the cursor because a boundary
    /// past the end of the fed audio cannot complete until more audio arrives.
    public func finalize(throughStreamSeconds seconds: Double) {
        let rate = analyzerFormat.sampleRate
        let frames = max(0, min(Int64(((seconds - origin) * rate).rounded()), analyzerFrames))
        finalize(through: CMTime(value: frames, timescale: CMTimeScale(rate)))
    }

    /// Flushes the resampler and closes the analyser. Safe to call twice.
    ///
    /// The results task is **drained**, not cancelled. Awaiting
    /// `finalizeAndFinishThroughEndOfInput()` only guarantees the analyser is done; the
    /// results it produced are still travelling through a separate task, so cancelling here
    /// silently drops the last question of the session — the one the endpointer forced
    /// moments before shutdown.
    public func finish() async {
        flushConverter()
        inputContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()

        // Bounded, so a recogniser that never closes its stream cannot hang the exit path.
        let results = resultsTask
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            results?.cancel()
        }
        await results?.value
        watchdog.cancel()
        transcriptContinuation.finish()
    }

    /// Drains the resampler's residual frames — a constant six output frames, measured, and
    /// not cumulative. After this the converter is dead until `reset()`.
    private func flushConverter() {
        guard converter != nil else { return }
        try? drain(capacity: 1024) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
    }
}
