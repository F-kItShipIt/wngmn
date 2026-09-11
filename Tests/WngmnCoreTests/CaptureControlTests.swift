import Testing
@testable import WngmnCore

/// Runtime control over what is being captured.
@Suite("Capture control")
struct CaptureControlTests {
    @Test("Both sources are live by default, so existing runs behave as before")
    func defaults() {
        let control = CaptureControl()
        #expect(!control.micMuted)
        #expect(!control.tapPaused)
        #expect(control.stateDescription == "mic=live tap=listening")
    }

    @Test("Starting paused is expressible at construction")
    func startPaused() {
        let control = CaptureControl(micMuted: true, tapPaused: true)
        #expect(control.micMuted)
        #expect(control.tapPaused)
        #expect(control.stateDescription == "mic=muted tap=paused")
    }

    /// The caller needs to know whether anything actually changed: a redundant toggle must
    /// not flush the endpointer or restart the microphone device for nothing.
    @Test("Setting a flag reports whether it changed")
    func reportsChange() {
        let control = CaptureControl()
        #expect(control.setMicMuted(true))
        #expect(!control.setMicMuted(true))
        #expect(control.setMicMuted(false))
        #expect(control.setTapPaused(true))
        #expect(!control.setTapPaused(true))
    }
}

@Suite("Control payload")
struct ControlPayloadTests {
    @Test("Each field is optional so one control can change without the other")
    func partialUpdates() throws {
        #expect(try ControlRequest.parse(#"{"mic":"muted"}"#) == .init(micMuted: true, tapPaused: nil))
        #expect(try ControlRequest.parse(#"{"tap":"paused"}"#) == .init(micMuted: nil, tapPaused: true))
        #expect(try ControlRequest.parse("{}") == .init(micMuted: nil, tapPaused: nil))
    }

    @Test("Both fields can be set at once")
    func bothFields() throws {
        #expect(
            try ControlRequest.parse(#"{"mic":"live","tap":"listening"}"#)
                == .init(micMuted: false, tapPaused: false)
        )
    }

    /// An unrecognised value must not be read as "off". Silently treating a typo as
    /// "listening" would leave the interviewer being captured while the page said otherwise.
    @Test("An unknown value is rejected rather than guessed at")
    func rejectsUnknown() {
        #expect(throws: ControlRequest.Failure.self) { try ControlRequest.parse(#"{"mic":"maybe"}"#) }
        #expect(throws: ControlRequest.Failure.self) { try ControlRequest.parse(#"{"tap":"off"}"#) }
        #expect(throws: ControlRequest.Failure.self) { try ControlRequest.parse("not json") }
        #expect(throws: ControlRequest.Failure.self) { try ControlRequest.parse(#"{"mic":true}"#) }
    }
}
