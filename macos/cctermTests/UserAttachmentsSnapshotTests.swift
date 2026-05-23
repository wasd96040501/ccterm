import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders a tiny transcript with one user message that combines an
/// attachments strip and a caption bubble — the path that lights up
/// when a user sends images through the InputBar. Covers the new
/// `.userAttachments` block kind end-to-end (Bridge → Coordinator →
/// `UserAttachmentsLayout`) plus its visual rhythm next to the
/// adjacent `.userBubble` row.
///
/// Mounts through `TranscriptOnlyHostViewController` (AppKit) — the
/// SwiftUI bridge is gone. The host follows the same canonical
/// attach pattern production uses.
@MainActor
final class UserAttachmentsSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUserAttachmentsRow() throws {
        let controller = Transcript2Controller()
        controller.attachSyntaxEngine(SyntaxHighlightEngine())
        controller.setHistory([
            Block(
                id: UUID(),
                kind: .userAttachments(images: Self.chipImages(count: 1, palette: [.systemPink]))),
            Block(
                id: UUID(),
                kind: .userBubble(text: "single image case — just dragged this into the bar")),
            Block(
                id: UUID(),
                kind: .userAttachments(images: Self.chipImages(count: 3))),
            Block(
                id: UUID(),
                kind: .userBubble(text: "three attachments + caption — strip is right-anchored")),
            Block(
                id: UUID(),
                kind: .userAttachments(images: Self.chipImages(count: 5))),
            Block(
                id: UUID(),
                kind: .userBubble(text: "five files, still single row")),
        ])

        let host = TranscriptOnlyHostViewController(controller: controller)
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 720, height: 360), settle: 0.5)
        let url = ViewSnapshot.writePNG(image, name: "UserAttachments")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "UserAttachments.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, 700)
        XCTAssertGreaterThanOrEqual(image.size.height, 300)
    }

    /// SF-Symbol-backed `NSImage`s, one color per chip. Symbols carry
    /// transparency around the glyph; the chip's draw path renders a
    /// fallback fill underneath when needed.
    private static func chipImages(
        count: Int,
        palette: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple]
    ) -> [NSImage] {
        let symbols = ["photo", "doc.richtext", "camera.macro", "paintpalette"]
        return (0..<count).map { i in
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                .applying(.init(paletteColors: [palette[i % palette.count]]))
            let image =
                NSImage(
                    systemSymbolName: symbols[i % symbols.count],
                    accessibilityDescription: nil) ?? NSImage()
            return image.withSymbolConfiguration(cfg) ?? image
        }
    }
}
