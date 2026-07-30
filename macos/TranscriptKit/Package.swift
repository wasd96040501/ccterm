// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptKit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    dependencies: [
        // Apple's CommonMark/GFM parser (cmark-gfm underneath). Pinned exactly:
        // `MarkdownConvert` switches over its AST by dynamic cast, so a node
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
            ]
        ),
        // `swift test`. Kept in the package rather than folded into the app's
        // Xcode test target so the package stays buildable and testable on its
        // own — the point of it being a package.
        .testTarget(name: "TranscriptKitTests", dependencies: ["TranscriptKit"]),
    ]
)
