import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot (the `*Snapshot` suffix → SKIPPED on the default CI
/// gate; the four non-snapshot completion tests are the gate). Migrated from
/// the deleted `CompletionListSnapshotTests` (which constructed the SwiftUI
/// `CompletionListView`): renders the AppKit `CompletionPopupView` with the
/// same slash fixture (3 matches, selectedIndex 1, a messy multi-line
/// description folded to two lines) via `ViewSnapshot.renderViewController`,
/// wrapping the bare popup NSView in a throwaway VC. Asserts image
/// plausibility only — open the PNG to review parity.
@MainActor
final class CompletionPopupViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSlashCommandsSelectedDetail() throws {
        let state = CompletionState()
        state.items = [
            SlashCommandStore.Match(
                name: "commit",
                description: "Create a git commit",
                rank: 0),
            SlashCommandStore.Match(
                name: "review",
                // Deliberately messy: leading/trailing whitespace, tabs, a
                // newline, and a double space — the footer must fold all of
                // these into single spaces and render at most two lines.
                description:
                    "  Review the current diff for correctness bugs\tand   reuse\ncleanups at the configured effort level, then optionally apply the fixes.  ",
                rank: 1),
            SlashCommandStore.Match(
                name: "security-review",
                description: nil,
                rank: 2),
        ]
        state.selectedIndex = 1

        capture(state: state, name: "CompletionPopup-Slash")
    }

    // MARK: - Helpers

    private func capture(state: CompletionState, name: String) {
        let size = CGSize(width: 420, height: 240)

        // Throwaway host VC: a background + a width-capped popup pinned top,
        // reconciled active so the rows + selected detail render.
        let host = NSViewController()
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let popup = CompletionPopupView()
        popup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            popup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            popup.widthAnchor.constraint(equalToConstant: 360),
        ])
        host.view = root

        // Drive the popup exactly as the controller does.
        popup.reconcile(state: state)
        popup.isHidden = false
        root.layoutSubtreeIfNeeded()

        let image = ViewSnapshot.renderViewController(host, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: name)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}
