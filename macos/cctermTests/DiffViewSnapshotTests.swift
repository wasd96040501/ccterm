import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders the standalone `DiffView` at a couple of representative
/// `DiffBlock` inputs (modified file + new file) and writes a PNG so the
/// layout can be reviewed without launching the app.
///
/// Syntax highlighting is fed by `\.syntaxEngine`, which the snapshot
/// scaffold provides; the engine's `.load()` is async and may not finish
/// before the `settle` window closes, in which case the diff renders in
/// the cold-state `labelColor` for all lines. Layout / chrome / selection
/// chrome don't depend on tokens, so the snapshot is meaningful either
/// way — the highlight back-fill is exercised separately through
/// `Transcript2HighlightStorage` tests.
@MainActor
final class DiffViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDiffViewSnapshot() throws {
        let edit = DiffBlock(
            filePath: "Sources/Greeter.swift",
            oldString: """
                import Foundation

                struct Greeter {
                    let name: String

                    func greet() -> String {
                        return "Hello, " + name
                    }
                }
                """,
            newString: """
                import Foundation

                struct Greeter {
                    let name: String
                    let formal: Bool

                    func greet() -> String {
                        let prefix = formal ? "Good day, " : "Hello, "
                        return prefix + name + "!"
                    }
                }
                """)
        let newFile = DiffBlock(
            filePath: "Sources/HelloWorld.swift",
            oldString: nil,
            newString: """
                import Foundation

                @main
                struct HelloWorld {
                    static func main() {
                        print("Hello, world!")
                    }
                }
                """)

        let view = VStack(alignment: .leading, spacing: 16) {
            DiffView(diff: edit)
            DiffView(diff: newFile)
        }
        .padding(20)
        .frame(width: 680, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.syntaxEngine, SyntaxHighlightEngine())

        let image = ViewSnapshot.render(
            view, size: CGSize(width: 680, height: 720), settle: 0.8)
        let url = ViewSnapshot.writePNG(image, name: "DiffView")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "DiffView.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 670)

        let bitmap: NSBitmapImageRep? = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first
        guard let bitmap else {
            XCTFail("snapshot has no bitmap representation")
            return
        }
        XCTAssertFalse(
            isUniform(bitmap),
            "snapshot is a single flat color — view likely did not render")
    }

    private func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 4, h > 4 else { return true }
        let probes: [(Int, Int)] = [
            (w / 4, h / 4),
            (w / 2, h / 4),
            (3 * w / 4, h / 4),
            (w / 4, h / 2),
            (w / 2, h / 2),
            (3 * w / 4, h / 2),
            (w / 4, 3 * h / 4),
            (w / 2, 3 * h / 4),
            (3 * w / 4, 3 * h / 4),
        ]
        let colors = probes.compactMap { rep.colorAt(x: $0.0, y: $0.1) }
        guard let first = colors.first else { return true }
        return colors.allSatisfy { $0 == first }
    }
}
