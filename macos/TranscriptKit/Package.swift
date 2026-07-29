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
        .target(
            name: "TranscriptKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        )
    ]
)
