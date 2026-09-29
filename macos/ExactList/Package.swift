// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ExactList",
    // TranscriptKit's floor, which is the first consumer's: nothing here needs
    // more than macOS 12. The display-link sampler in the tests is macOS 14 and
    // sits behind `#available`.
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ExactList", targets: ["ExactList"])
    ],
    targets: [
        // Values and pure functions: geometry, anchoring, planning a commit.
        // Foundation only — the compiler is what keeps AppKit out (SPEC §15).
        .target(name: "ExactListCore"),
        // The AppKit engine and the public API.
        .target(name: "ExactList", dependencies: ["ExactListCore"]),
        // What the demo shows, so the demo app and the recordings run the same thing.
        .target(name: "ExactListDemoSupport", dependencies: ["ExactList"]),
        // `swift run ExactListDemo`: the checks only eyes and VoiceOver can make.
        .executableTarget(
            name: "ExactListDemo", dependencies: ["ExactListDemoSupport"], exclude: ["CLAUDE.md"]),
        // Shared by the window tests and the benchmarks; in no product.
        .target(
            name: "ExactListTestSupport", dependencies: ["ExactList"], path: "Tests/ExactListTestSupport"),
        .testTarget(name: "ExactListCoreTests", dependencies: ["ExactListCore"]),
        // A child process for the programmer errors (L9, L10, L12): each dies on
        // a precondition by design, which a test can only watch from outside.
        .executableTarget(
            name: "ExactListProbe", dependencies: ["ExactList"], path: "Tests/ExactListProbe"),
        .testTarget(
            name: "ExactListTests", dependencies: ["ExactList", "ExactListTestSupport", "ExactListProbe"],
            exclude: ["CLAUDE.md"]),
        // Meaningful only under `-O`: `make bench-list`.
        .testTarget(name: "ExactListBenchmarks", dependencies: ["ExactList", "ExactListTestSupport"]),
        // For eyes, not a gate: `make record-list`. An executable, because TCC
        // attributes `xctest` to Xcode.app, which has no Screen Recording grant.
        .executableTarget(
            name: "ExactListRecordings", dependencies: ["ExactListDemoSupport", "ExactListTestSupport"],
            path: "Tests/ExactListRecordings"),
    ]
)
