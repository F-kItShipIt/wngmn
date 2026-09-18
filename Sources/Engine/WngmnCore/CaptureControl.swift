import Foundation
import Synchronization

/// Runtime control over what is being captured.
///
/// Read on the audio drain loops and written from the HTTP server's queue, so the flags are
/// atomics rather than actor state: a drain loop must not suspend to ask whether it is
/// allowed to keep going.
///
/// The two controls are deliberately not symmetrical, and the difference is worth knowing:
/// muting stops the microphone device outright, so the system microphone indicator goes
/// out; pausing only discards tap audio before it reaches the endpointer or transcriber,
/// leaving the capture graph registered. Tearing the tap's aggregate down and back up on
/// every toggle would risk the stall that `captureHealthAction` exists to recover from.
public final class CaptureControl: Sendable {
    private let mic = Atomic<Bool>(false)
    private let tap = Atomic<Bool>(false)
    private let auto = Atomic<Bool>(false)

    public init(micMuted: Bool = false, tapPaused: Bool = false, autoAnswer: Bool = false) {
        mic.store(micMuted, ordering: .relaxed)
        tap.store(tapPaused, ordering: .relaxed)
        auto.store(autoAnswer, ordering: .relaxed)
    }

    /// The microphone is not being captured at all.
    public var micMuted: Bool { mic.load(ordering: .relaxed) }
    /// Tap audio is being discarded rather than transcribed.
    public var tapPaused: Bool { tap.load(ordering: .relaxed) }
    /// Each turn is answered automatically, without a press of Ask. Off unless it is asked
    /// for here; whether a *run* starts with it on is `Options.startsWithAuto`.
    public var autoAnswer: Bool { auto.load(ordering: .relaxed) }

    /// Returns whether the value actually changed, so a redundant toggle does not restart a
    /// device or flush an endpointer for nothing.
    @discardableResult
    public func setMicMuted(_ muted: Bool) -> Bool {
        mic.exchange(muted, ordering: .relaxed) != muted
    }

    @discardableResult
    public func setTapPaused(_ paused: Bool) -> Bool {
        tap.exchange(paused, ordering: .relaxed) != paused
    }

    @discardableResult
    public func setAutoAnswer(_ on: Bool) -> Bool {
        auto.exchange(on, ordering: .relaxed) != on
    }

    /// Carried on the `control` status line so a second viewer reflects the change rather
    /// than showing stale state.
    public var stateDescription: String {
        "mic=\(micMuted ? "muted" : "live") tap=\(tapPaused ? "paused" : "listening") "
            + "auto=\(autoAnswer ? "on" : "off")"
    }
}

/// The body of a `POST /control` request.
public enum ControlRequest {
    public struct Update: Sendable, Equatable {
        public var micMuted: Bool?
        public var tapPaused: Bool?
        public var autoAnswer: Bool?

        public init(micMuted: Bool? = nil, tapPaused: Bool? = nil, autoAnswer: Bool? = nil) {
            self.micMuted = micMuted
            self.tapPaused = tapPaused
            self.autoAnswer = autoAnswer
        }
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Absent fields are left alone, so one control can change without restating the other.
    ///
    /// An unrecognised value is an error rather than a default. Reading a typo as "off"
    /// would leave the interviewer being captured while the page reported otherwise, which
    /// is the one failure this feature exists to prevent.
    public static func parse(_ payload: String) throws -> Update {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure("control payload is not a JSON object") }

        func flag(_ key: String, on: String, off: String) throws -> Bool? {
            guard let raw = root[key] else { return nil }
            guard let value = raw as? String else {
                throw Failure("\(key) must be \"\(on)\" or \"\(off)\"")
            }
            switch value {
            case on: return true
            case off: return false
            default: throw Failure("\(key) must be \"\(on)\" or \"\(off)\", got \"\(value)\"")
            }
        }

        return Update(
            micMuted: try flag("mic", on: "muted", off: "live"),
            tapPaused: try flag("tap", on: "paused", off: "listening"),
            autoAnswer: try flag("auto", on: "on", off: "off")
        )
    }
}
