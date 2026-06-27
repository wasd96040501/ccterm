import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders `CompletionListView` populated with slash-command matches so
/// the post-simplification UI can be reviewed without launching the app:
/// text-only rows (no leading icon), no inline right-side description,
/// and a two-line description footer for the selected row whose text has
/// been trimmed / whitespace-folded.
@MainActor
final class CompletionListSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSlashCommandsSelectedDetail() throws {
        let vm = CompletionState()
        vm.items = [
            SlashCommandStore.Match(
                name: "commit",
                description: "Create a git commit",
                rank: 0),
            SlashCommandStore.Match(
                name: "review",
                // Deliberately messy: leading/trailing whitespace, tabs,
                // a newline, and a double space — the footer must fold all
                // of these into single spaces and render at most two lines.
                description:
                    "  Review the current diff for correctness bugs\tand   reuse\ncleanups at the configured effort level, then optionally apply the fixes.  ",
                rank: 1),
            SlashCommandStore.Match(
                name: "security-review",
                description: nil,
                rank: 2),
        ]
        vm.selectedIndex = 1

        capture(viewModel: vm, name: "CompletionList-Slash")
    }

    // MARK: - Helpers

    private func capture(viewModel: CompletionState, name: String) {
        let size = CGSize(width: 420, height: 240)
        let view = ZStack {
            Color(nsColor: .windowBackgroundColor)
            CompletionListView(viewModel: viewModel, onConfirm: { _ in })
                .barSurface(cornerRadius: 12)
                .frame(width: 360)
        }
        .frame(width: size.width, height: size.height)

        let image = ViewSnapshot.render(view, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: name)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}
