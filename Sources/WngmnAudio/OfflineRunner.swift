import AVFoundation
import Foundation
import WngmnCore

/// Runs a recorded file through the same endpointer, resampler, analyser and assembler as a
/// live call, and emits the same JSON Lines.
///
/// This is the golden-file tier: it exercises everything except the tap itself, needs no
/// system-audio permission, and therefore runs in any terminal. It is also how a rehearsal
/// recording gets replayed after the fact to tune `--hangover-ms` without booking another
/// call.
public struct OfflineRunner {
    public struct Configuration: Sendable {
        public var transcriber: Transcriber.Configuration
        public var endpointer: EndpointerConfig
        public var terms: TermList
        public var emitPartials: Bool
        /// Emit a `metric` line per VAD window. This is the point of replaying a rehearsal
        /// recording: pick thresholds from the distribution rather than from a guess.
        public var debugVAD: Bool
        /// Playback speed relative to real time.
        ///
        /// Pacing is not cosmetic. The endpointer forces finalisation 250 ms after speech
        /// stops, and the recogniser needs to have actually decoded that speech by then. On
        /// a live call it has — decoding runs at 0.007x real time — but feeding a whole file
        /// at once puts the forced finalise far ahead of the decoder, which then returns a
        /// final containing nothing but punctuation and the words are lost for good.
        public var speed: Double

        public init(
            transcriber: Transcriber.Configuration,
            endpointer: EndpointerConfig,
            terms: TermList = .empty,
            emitPartials: Bool = true,
            debugVAD: Bool = false,
            speed: Double = 8
        ) {
            self.transcriber = transcriber
            self.endpointer = endpointer
            self.terms = terms
            self.emitPartials = emitPartials
            self.debugVAD = debugVAD
            self.speed = speed
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case conversionFailed(String)

        public var description: String {
            switch self {
            case let .unreadable(path): return "cannot read audio file: \(path)"
            case let .conversionFailed(detail): return "cannot convert input: \(detail)"
            }
        }
    }

    /// Matches the tap: Float32, 48 kHz, mono.
    static let captureRate: Double = 48_000
    private static let chunkFrames = 512

    private let configuration: Configuration
    private let writer: EventWriter

    public init(configuration: Configuration, writer: EventWriter) {
        self.configuration = configuration
        self.writer = writer
    }

    public func run(url: URL) async throws {
        let samples = try Self.readMono48k(url: url)
        writer.emit(.status(
            state: "capturing",
            format: StreamFormat(rate: Self.captureRate, ch: 1),
            detail: "offline: \(url.lastPathComponent), \(String(format: "%.2f", Double(samples.count) / Self.captureRate)) s"
        ))

        try await Pipeline.requireModel(configuration.transcriber.locale)

        let transcriber = try await Transcriber(configuration: configuration.transcriber)
        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.captureRate, channels: 1
        ) else { throw Failure.conversionFailed("cannot build the capture format") }
        try await transcriber.prepare(sourceFormat: sourceFormat)

        let collector = QuestionCollector(
            terms: configuration.terms, writer: writer, emitPartials: configuration.emitPartials
        )
        let transcripts = transcriber.transcripts
        let consumer = Task { for await t in transcripts { await collector.handle(t) } }

        var endpointer = Endpointer(config: configuration.endpointer)
        let speed = max(configuration.speed, 0.1)
        let chunkNanos = UInt64(Double(Self.chunkFrames) / Self.captureRate / speed * 1_000_000_000)
        var offset = 0
        while offset < samples.count {
            let n = min(Self.chunkFrames, samples.count - offset)
            let chunk = Array(samples[offset..<(offset + n)])
            let start = Double(offset) / Self.captureRate

            var events: [EndpointerEvent] = []
            chunk.withUnsafeBufferPointer {
                endpointer.push($0, startTime: start, sampleRate: Self.captureRate) { events.append($0) }
            }
            try await transcriber.advance(toStreamSeconds: start)
            try await transcriber.feed(chunk)
            if configuration.debugVAD {
                writer.emit(.metric(name: "vad_db", value: endpointer.lastLevelDB, unit: "dBFS"))
            }
            for event in events {
                if case let .endpoint(endpoint) = event {
                    await collector.endpointDetected(endpoint)
                    await transcriber.finalize(throughStreamSeconds: endpoint.decisionTime)
                }
            }
            offset += n
            // Keep the decoder within reach of the endpointer, as it would be live.
            if chunkNanos > 0 { try? await Task.sleep(for: .nanoseconds(chunkNanos)) }
        }

        // Let the recogniser finish the tail before forcing the last boundary.
        try? await Task.sleep(for: .milliseconds(250))

        // Close any question still open at the end of the file.
        var trailing: [EndpointerEvent] = []
        endpointer.flush(at: Double(samples.count) / Self.captureRate) { trailing.append($0) }
        for event in trailing {
            if case let .endpoint(endpoint) = event {
                await collector.endpointDetected(endpoint)
                await transcriber.finalize(throughStreamSeconds: endpoint.decisionTime)
            }
        }

        await transcriber.finish()
        _ = await consumer.result
        await collector.drain()
        writer.emit(.status(state: "stopped", format: nil, detail: nil))
    }

    /// Decodes any readable audio file into Float32 mono at the capture rate, so the offline
    /// path goes through exactly the same resampler configuration as the live one.
    static func readMono48k(url: URL) throws -> [Float] {
        // `AVAudioConverterInputBlock` is imported as `@Sendable`, but it is only ever
        // invoked synchronously from inside `convert()` on this thread. The annotation is
        // the audited escape hatch for exactly that.
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable(url.path) }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: captureRate, channels: 1),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw Failure.conversionFailed("no converter from \(file.processingFormat)") }
        converter.downmix = true

        let inCapacity = AVAudioFrameCount(16_384)
        nonisolated(unsafe) let input: AVAudioPCMBuffer
        if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity) {
            input = buffer
        } else {
            throw Failure.conversionFailed("cannot allocate the read buffer")
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * captureRate / file.processingFormat.sampleRate) + 1024)
        var reachedEnd = false

        while !reachedEnd {
            let ratio = captureRate / file.processingFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inCapacity) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
                throw Failure.conversionFailed("cannot allocate the output buffer")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                do {
                    try file.read(into: input, frameCount: inCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if status == .error { throw Failure.conversionFailed(error?.localizedDescription ?? "unknown") }
            if let data = output.floatChannelData, output.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream { reachedEnd = true }
        }
        return out
    }
}

/// Serialises assembler access between the feeding loop and the results consumer.
actor QuestionCollector {
    private var assembler: QuestionAssembler
    private let writer: EventWriter
    private let emitPartials: Bool

    init(terms: TermList, writer: EventWriter, emitPartials: Bool) {
        assembler = QuestionAssembler(terms: terms)
        self.writer = writer
        self.emitPartials = emitPartials
    }

    func endpointDetected(_ endpoint: Endpoint) {
        assembler.endpointDetected(endpoint, now: Self.now)
    }

    func handle(_ transcript: Transcriber.Transcript) {
        if transcript.isFinal {
            let questions = assembler.finalArrived(
                start: transcript.start, end: transcript.end, text: transcript.text,
                now: Self.now
            )
            reportDropped()
            for question in questions {
                if question.usedVolatileFallback {
                    writer.emit(.warning(
                        code: "volatile_fallback",
                        detail: "the forced final for this region was empty; used volatile text"
                    ))
                }
                writer.emit(.question(question))
            }
        } else {
            assembler.volatileArrived(
                start: transcript.start, end: transcript.end, text: transcript.text
            )
            guard emitPartials else { return }
            let text = TextNormalizer.stripArtifacts(transcript.text)
            guard !text.isEmpty else { return }
            writer.emit(.partial(text: text, t: transcript.end))
        }
    }

    /// Emits anything still pending once the file has been fully consumed.
    func drain() {
        let questions = assembler.tick(now: Self.now + assembler.finalTimeout + 1)
        reportDropped()
        for question in questions { writer.emit(.question(question)) }
    }

    private func reportDropped() {
        for drop in assembler.takeDropped() {
            writer.emit(.warning(
                code: "question_lost",
                detail: String(
                    format: "boundary at t0=%.2f t1=%.2f produced no usable text",
                    drop.endpoint.speechStart, drop.endpoint.speechEnd
                )
            ))
        }
    }

    private static var now: Double {
        Double(HostClock.nanos(fromTicks: HostClock.now())) / 1_000_000_000
    }
}
