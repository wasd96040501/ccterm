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
        .library(name: "TranscriptKit", targets: ["TranscriptKit"]),
        // Separate product, not a folder inside the other one. `TranscriptKit`'s
        // §4 turns on a boundary — the package draws rows and owns none of the
        // presentation around them — and a boundary both sides can `import`
        // across is not one. Two
        // products make the arrow single-direction and the compiler the thing
        // that holds it: `TranscriptMedia` depends on `TranscriptKit`, and
        // nothing in `TranscriptKit` can name a window, an overlay or a grid.
        .library(name: "TranscriptMedia", targets: ["TranscriptMedia"]),
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
        .executableTarget(
            name: "TranscriptKitDemo", dependencies: ["TranscriptKit", "TranscriptMedia"]),
        .target(
            name: "TranscriptKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [.process("Resources")]
        ),
        // What a transcript host needs and `TranscriptKit` deliberately refuses:
        // rows built out of pictures, and the overlay a picture or a cut-short
        // message opens into. Both are presentation with product decisions in
        // them — how a group of images packs, how dark the mask is, what a
        // preview's face is — which is exactly the material §4 keeps out of the
        // renderer. Kept in this package rather than in the app so the demo and
        // the app get the same components, and so they stay buildable without an
        // Xcode project.
        .target(name: "TranscriptMedia", dependencies: ["TranscriptKit"]),
        // `swift test`. Kept in the package rather than folded into the app's
        // Xcode test target so the package stays buildable and testable on its
        // own — the point of it being a package.
        .testTarget(name: "TranscriptKitTests", dependencies: ["TranscriptKit"]),
    ]
)
