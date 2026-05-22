import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Side-by-side renderings of the completed status glyph at the two
/// sizes it ships at: popover row (14pt) and chrome button (10pt).
/// Opt-in (filename ends in `SnapshotTests`); see CLAUDE.md.
@MainActor
final class TodoStatusGlyphSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletedGlyphSizes() throws {
        let size = CGSize(width: 360, height: 90)
        let view = HStack(spacing: 28) {
            labeled("Popover 14×14") {
                TodoStatusGlyph(status: .completed)
                    .frame(width: 14, height: 14)
            }
            labeled("Chrome 10×10") {
                TodoStatusGlyph(status: .completed, muted: true)
                    .frame(width: 10, height: 10)
            }
            labeled("Chrome 14×14") {
                TodoStatusGlyph(status: .completed, muted: true)
                    .frame(width: 14, height: 14)
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: size.width, height: size.height)

        let image = ViewSnapshot.render(view, size: size, settle: 0.4)
        let url = ViewSnapshot.writePNG(image, name: "TodoStatusGlyph-completed")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "TodoStatusGlyph-completed.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @ViewBuilder
    private func labeled<Content: View>(
        _ caption: String, @ViewBuilder content: () -> Content
    )
        -> some View
    {
        VStack(spacing: 6) {
            content()
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary)
        }
    }
}
