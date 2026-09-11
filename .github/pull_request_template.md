## What this changes

<!-- The behaviour, and the failure that motivated it. -->

## How it was verified

- [ ] `swift build -c release` — warnings are errors, so this has to be clean
- [ ] `swift test` locally, including the four suites CI skips (`OfflinePipelineTests`,
      `ContinuationWindowTests`, `HangoverPauseTests`, `TranscriberTimelineTests`), which
      need the en-US speech model
- [ ] `wngmn selftest` if anything under `WngmnAudio` changed — CI cannot run it, because
      System Audio Recording is granted to the launching process and a denial returns `noErr`

<!-- If you rehearsed on a real call, say what you watched for: false endpoints, drift over
     ten minutes, a device change mid-call. Do not paste transcript text or notes. -->

## Notes

<!-- Anything a reviewer would otherwise have to discover: a measured number, a case you
     decided not to handle, a test you could not write. -->
