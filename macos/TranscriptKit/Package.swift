// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptKit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    targets: [
        .target(
            name: "TranscriptKit"
        )
    ]
)
