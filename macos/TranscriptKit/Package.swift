// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptKit",
    // The package puts user-visible text on screen of its own — the titles of
    // the menu items it contributes — so it carries its own catalogue rather
    // than borrowing the host's. A host's `Localizable.xcstrings` lives in the
    // host's bundle and `Bundle.module` cannot reach it.
    //
    // `.lproj/Localizable.strings` rather than the app's `.xcstrings`, and the
    // reason is the toolchain rather than taste: SwiftPM copies an `.xcstrings`
    // through verbatim without compiling it, so the lookup would resolve under
    // Xcode (which does compile it) and silently fall back to the key under
    // `swift test` / `swift run` — two of this package's three entry points.
    // Measured, not assumed: the built bundle held the `.xcstrings` unchanged.
    defaultLocalization: "en",
    // 12 rather than the app's 14: the floor is what the code actually needs —
    // `NSImage.SymbolConfiguration(paletteColors:)`, which is how an inline SF
    // Symbol gets tinted. Raising it to match the app would be a restriction
    // nothing in here can point at.
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    dependencies: [
        // Apple's CommonMark/GFM parser (cmark-gfm underneath). Pinned exactly:
        // `MarkdownParser` switches over its AST by dynamic cast, so a node
        // type appearing or changing shape is a silent behaviour change rather
        // than a compile error.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.7.3")
    ],
    targets: [
        // Opens a real window with a transcript in it: `swift run
        // TranscriptKitDemo`. For the things only hands and eyes catch —
        // scrolling, dragging across the content-width clamp, chrome insets.
        .executableTarget(name: "TranscriptKitDemo", dependencies: ["TranscriptKit"]),
        .target(
            name: "TranscriptKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [.process("Resources")]
        ),
        // `swift test`. Kept in the package rather than folded into the app's
        // Xcode test target so the package stays buildable and testable on its
        // own — the point of it being a package.
        .testTarget(name: "TranscriptKitTests", dependencies: ["TranscriptKit"]),
    ]
)
