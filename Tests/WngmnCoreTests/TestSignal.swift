import Foundation
@testable import WngmnCore

/// Synthesises RMS envelopes for endpointer tests.
///
/// Samples alternate between +a and -a, so the RMS of any whole number of pairs is exactly
/// `a` and the level in dBFS is exactly `20*log10(a)`. That makes threshold assertions exact
/// rather than approximate.
enum TestSignal {
    static let rate: Double = 48_000

    static func amplitude(dB: Double) -> Float { Float(pow(10, dB / 20)) }

    static func frames(seconds: Double, dB: Double) -> [Float] {
        let n = Int((seconds * rate).rounded())
        guard n > 0 else { return [] }
        let a = amplitude(dB: dB)
        return (0..<n).map { $0 % 2 == 0 ? a : -a }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * rate).rounded()))
    }

    /// Concatenates `(seconds, dB)` spans into one contiguous buffer. `nil` dB means silence.
    static func envelope(_ spans: [(Double, Double?)]) -> [Float] {
        var out: [Float] = []
        for (seconds, dB) in spans {
            out += dB.map { frames(seconds: seconds, dB: $0) } ?? silence(seconds: seconds)
        }
        return out
    }
}

extension Array where Element == EndpointerEvent {
    var endpoints: [Endpoint] { compactMap { if case let .endpoint(e) = $0 { return e } else { return nil } } }
    var starts: [Double] { compactMap { if case let .speechStarted(t) = $0 { return t } else { return nil } } }
    var discards: Int { filter { if case .discarded = $0 { return true } else { return false } }.count }
}
