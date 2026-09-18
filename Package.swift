// swift-tools-version: 6.2
import PackageDescription

// Warnings are errors: the Swift 6 data-race diagnostics that matter here (sending a buffer
// pointer across an isolation boundary, a global `var` silently inferred @MainActor) are
// exactly the ones that produce a crash on the audio thread rather than a compile failure.
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

// Laid out by layer, not by name. Sources/Engine is the part that has to travel to other
// operating systems, so nothing under it may import an Apple framework; Sources/UI is the page
// and its server; Sources/Platform/Apple is Core Audio and SpeechAnalyzer; Sources/App is the
// macOS command line. Target names stay as they were, so imports and --filter do not move.
var products: [Product] = []
var targets: [Target] = [
    // Pure logic: endpointing, text repair, the ring buffer, the output protocol.
    // Deliberately free of Core Audio and Speech so its tests run in any terminal,
    // with no system-audio permission — and on any operating system Swift runs on.
    .target(name: "WngmnCore", path: "Sources/Engine/WngmnCore", swiftSettings: settings),

    .testTarget(
        name: "WngmnCoreTests",
        dependencies: ["WngmnCore"],
        // Real speech, synthesised with `say`, stored as headerless 16 kHz mono
        // little-endian Int16 so the pure-logic target needs no audio framework.
        resources: [.copy("Fixtures")],
        swiftSettings: settings
    ),

    // Outbound Claude calls: credentials, prompt assembly, streaming HTTP. Separate
    // from WngmnServe on purpose — the server renders the transcript and knows
    // nothing about where an answer comes from, so the Claude dependency stays on one
    // side of that line.
    .target(
        name: "WngmnAsk", dependencies: ["WngmnCore"],
        path: "Sources/Engine/WngmnAsk", swiftSettings: settings),
    .testTarget(
        name: "WngmnAskTests",
        dependencies: ["WngmnAsk"],
        swiftSettings: settings
    ),
]

// Everything below still needs an Apple framework, so off macOS it is left out of the
// package rather than left to fail: a Linux `swift build` then builds, and `swift test`
// tests, exactly the part of wngmn that has crossed.
#if os(macOS)
products.append(.executable(name: "wngmn", targets: ["wngmn"]))
targets += [
    // Everything that touches the system: the process tap, the analyser, the clock.
    .target(
        name: "WngmnAudio", dependencies: ["WngmnCore"],
        path: "Sources/Platform/Apple/WngmnAudio", swiftSettings: settings),

    // The localhost transcript view: a hand-rolled HTTP/1.1 + Server-Sent Events
    // listener on Network.framework, and the page it serves. Hand-rolled because
    // success criterion 4 is setup with no network fetch, and every Swift HTTP server
    // is a package dependency. Depends on WngmnCore only — it renders events, it
    // does not know where they came from.
    .target(
        name: "WngmnServe", dependencies: ["WngmnCore"],
        path: "Sources/UI/WngmnServe", swiftSettings: settings),

    .executableTarget(
        name: "wngmn",
        dependencies: ["WngmnCore", "WngmnAudio", "WngmnServe", "WngmnAsk"],
        path: "Sources/App/wngmn",
        swiftSettings: settings
    ),

    .testTarget(
        name: "WngmnServeTests",
        dependencies: ["WngmnServe"],
        swiftSettings: settings
    ),
    .testTarget(
        name: "WngmnAudioTests",
        dependencies: ["WngmnAudio"],
        resources: [.copy("Fixtures")],
        swiftSettings: settings
    ),
]
#endif

let package = Package(
    name: "wngmn",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets
)
