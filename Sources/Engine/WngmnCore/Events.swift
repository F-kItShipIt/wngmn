import Foundation

/// The stage-1 output protocol: JSON Lines on stdout, one object per line.
///
/// Stage 2 (message bank + overlay) consumes this stream rather than linking against
/// internals, so the shape here is a published contract — including key order, which
/// `JSONEncoder` does not preserve. The serialiser below is hand-written for that reason,
/// and because it runs on a live call: it allocates one string and does no reflection.
public enum Event: Sendable, Equatable {
    /// Lifecycle: `starting`, `capturing`, `stopped`. Also `control` when a capture control is
    /// applied, `mic` when the microphone half starts, and `selftest`.
    case status(state: String, format: StreamFormat?, detail: String?)

    /// Volatile (non-final) transcript text. Advisory only — never assembled into a question.
    case partial(text: String, t: Double, speaker: Speaker? = nil)

    /// A complete question. `t0`/`t1` bound the speech in stream seconds; `ms` is the
    /// measured endpoint-to-final latency for that question.
    ///
    /// `revises` is set when the journalist paused mid-question and then carried on: this
    /// line supersedes **the most recent `question` line**, rather than following it.
    /// `warning` and `partial` lines can appear in between, so a consumer must track the
    /// last question it displayed rather than the last line it read. A consumer that ignores
    /// the field still sees a correct — if briefly duplicated — transcript.
    /// `volatile` is set when the text came from the volatile stream because the forced
    /// final was lossy. The question is still the best available transcription — the flag
    /// says its wording is less trustworthy than usual, which is what a rehearsal needs to
    /// see per question rather than only in the aggregate warning line.
    /// `speaker` is carried only when more than one source is being captured. With the mic
    /// off the line is byte-identical to the single-source shape stage 2 already consumes,
    /// so enabling the mic is what introduces the key rather than an unannounced change.
    case question(
        text: String, t0: Double, t1: Double, ms: Int,
        revises: Bool = false, usedVolatile: Bool = false, speaker: Speaker? = nil
    )

    /// Recoverable condition. The binary keeps running.
    case warning(code: String, detail: String)

    /// Unrecoverable condition. The binary is about to exit non-zero.
    case error(code: String, detail: String)

    /// Free-form measurement, used by the latency harness and rehearsal instrumentation.
    case metric(name: String, value: Double, unit: String)

    /// Whether a page that arrives late, or reconnects, has to be told about this.
    ///
    /// A `partial` is a snapshot of a sentence still being spoken, superseded by the next
    /// one a fraction of a second later, and several arrive per second. Remembering them
    /// fills a bounded replay buffer with text that was obsolete on arrival and evicts the
    /// questions — the one thing a reconnecting page cannot reconstruct for itself. Measured
    /// on a live run: 113 of 123 retained frames were partials, leaving three questions.
    ///
    /// A `metric` is derivable for the same reason it is cheap to drop: the latency chart is
    /// drawn from the questions, and there is one metric per question.
    public var isReplayable: Bool {
        switch self {
        case .partial, .metric: false
        case .status, .question, .warning, .error: true
        }
    }
}

/// Who was speaking. `caller` is the tapped call audio, `you` is the local microphone.
///
/// Kept out of the transcript text itself so a consumer can style, filter or route by
/// speaker without parsing prose — and so an answer is never asked for your own sentence.
public enum Speaker: String, Sendable, Equatable {
    case caller
    case you
}

/// Audio format descriptor carried on the `capturing`, `mic` and `selftest` status lines.
public struct StreamFormat: Sendable, Equatable {
    public let rate: Double
    public let ch: Int

    public init(rate: Double, ch: Int) {
        self.rate = rate
        self.ch = ch
    }
}

/// Serialises `Event`s to single-line JSON with a fixed key order.
public struct EventEncoder: Sendable {
    public init() {}

    public func line(_ event: Event) -> String {
        var out = "{"
        switch event {
        case let .status(state, format, detail):
            out += pair("type", "status") + "," + pair("state", state)
            if let format {
                out += ",\"format\":{" + pair("rate", format.rate) + "," + pair("ch", format.ch) + "}"
            }
            if let detail { out += "," + pair("detail", detail) }
        case let .partial(text, t, speaker):
            out += pair("type", "partial") + "," + pair("text", text) + "," + pair("t", t)
            if let speaker { out += "," + pair("speaker", speaker.rawValue) }
        case let .question(text, t0, t1, ms, revises, usedVolatile, speaker):
            out += pair("type", "question") + "," + pair("text", text)
            out += "," + pair("t0", t0) + "," + pair("t1", t1) + "," + pair("ms", ms)
            // Omitted when false so the common line stays exactly as published in the design.
            if revises { out += ",\"revises\":true" }
            if usedVolatile { out += ",\"volatile\":true" }
            // Last, so every key stage 2 already reads keeps its position.
            if let speaker { out += "," + pair("speaker", speaker.rawValue) }
        case let .warning(code, detail):
            out += pair("type", "warning") + "," + pair("code", code) + "," + pair("detail", detail)
        case let .error(code, detail):
            out += pair("type", "error") + "," + pair("code", code) + "," + pair("detail", detail)
        case let .metric(name, value, unit):
            out += pair("type", "metric") + "," + pair("name", name)
            out += "," + pair("value", value) + "," + pair("unit", unit)
        }
        return out + "}"
    }

    private func pair(_ key: String, _ value: String) -> String {
        "\"\(key)\":\(EventEncoder.quote(value))"
    }

    private func pair(_ key: String, _ value: Int) -> String {
        "\"\(key)\":\(value)"
    }

    private func pair(_ key: String, _ value: Double) -> String {
        "\"\(key)\":\(EventEncoder.number(value))"
    }

    /// Timestamps carry at most millisecond meaning; trimming keeps lines short and makes
    /// golden-file comparison stable against floating-point noise. Whole values print
    /// without a trailing `.0` so a sample rate reads as `48000`.
    /// Public because an answer key has to be spelled the same way a question line was, and
    /// `AutoAnswerer` builds that key in another module. Raw interpolation there produced
    /// `you@58.10982145766667` for a line the page had already been given as `58.11`, so the
    /// answer matched no row and was dropped after the model call had been made and charged.
    public static func number(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let rounded = (v * 1000).rounded() / 1000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        return String(rounded)
    }

    /// Minimal RFC 8259 string escaping. Control characters must be escaped or the line
    /// stops being one line, which would break every downstream consumer.
    public static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}
