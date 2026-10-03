// swift-tools-version: 6.2

import PackageDescription

/// The app's own settings, so a component compiles here exactly as it did in
/// the app: Swift 5 mode, `MainActor` by default, approachable concurrency,
/// member imports visible only where imported.
let appSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

/// The display models' settings: the app's, less `MainActor` by default —
/// they are values, built off the main actor too (the transcript's pages).
let valueSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Components",
    // A component puts words on screen of its own (an accessibility label, a
    // fixed control title), so the package carries its own catalogue, as
    // TranscriptKit does and for its reason: `.lproj/Localizable.strings`,
    // which SwiftPM compiles, looked up with `bundle: .module`.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // Every view the app draws with: generic controls and the app's own
        // components, each built from its init, a display model and a delegate.
        // It depends on nothing — not the app, not AgentSDK — so a component
        // can't reach a store, a session or a sibling, and the compiler says so.
        // DisplayModels rides along: the values those components draw, which
        // the app's models build without importing AppKit.
        .library(name: "Components", targets: ["Components", "DisplayModels"])
    ],
    dependencies: [
        // The style page's alone, never the libraries': the main window's
        // transcript and tabs are TranscriptKit's, and the page shows the
        // window whole.
        .package(path: "../TranscriptKit")
    ],
    targets: [
        // What a component is shown, as values: Foundation only, no AppKit, so
        // a model or a view model can build them. Words of its own (a check's
        // sentence) are in its own catalogue.
        .target(name: "DisplayModels", resources: [.process("Resources")], swiftSettings: valueSettings),
        .target(
            name: "Components", dependencies: ["DisplayModels"], resources: [.process("Resources")],
            swiftSettings: appSettings),
        // The style page: every component tiled on one page, live, with fixture
        // models — `make design`. What the design sheet shows, built from the
        // same components the app uses.
        .executableTarget(
            name: "ComponentsDesign",
            dependencies: [
                "Components",
                .product(name: "TranscriptKit", package: "TranscriptKit"),
                .product(name: "TranscriptWorkspace", package: "TranscriptKit"),
            ],
            exclude: ["CLAUDE.md"],
            swiftSettings: appSettings),
        .testTarget(name: "ComponentsTests", dependencies: ["Components", "DisplayModels", "ComponentsDesign"], swiftSettings: appSettings),
    ]
)
