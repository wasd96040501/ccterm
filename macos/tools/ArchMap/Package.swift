// swift-tools-version: 6.0

import PackageDescription

// `make arch`'s engine: parses the Swift sources and writes the architecture
// map (types, dependencies, data flow, unit surfaces) to build/arch/.
let package = Package(
    name: "ArchMap",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ArchMap",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        )
    ]
)
