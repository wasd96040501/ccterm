import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.notebookEdit` body —
/// `PermissionNotebookEditCardBodyView` (migration plan §4.4, §9). Drives the
/// REAL production body builder (`PermissionNotebookEditCardBodyBuilder.makeBody`)
/// with representative `PermissionRequest`s and asserts the parsed fields render
/// into the real view — never a re-implemented approximation, never the SwiftUI
/// data struct in isolation (the data layer is pinned separately by
/// `PermissionNotebookEditCardBodyTests`; THIS test pins the AppKit render).
@MainActor
final class PermissionNotebookEditBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Build the body through the production dispatch conformer (NOT by calling
    /// the view initializer directly) so the test exercises the same surface the
    /// card mounts.
    private func makeBodyView(input: [String: Any]) -> PermissionNotebookEditCardBodyView {
        let req = PermissionRequest.makePreview(
            requestId: "nb-\(UUID().uuidString)", toolName: "NotebookEdit", input: input)
        let view = PermissionNotebookEditCardBodyBuilder()
            .makeBody(request: req, engine: nil)
        return try! XCTUnwrap(view as? PermissionNotebookEditCardBodyView)
    }

    /// Mount at a fixed settled width so the source block's used-height resolves
    /// (mirrors `PermissionTaskAgentBodyTests.mount`).
    @discardableResult
    private func mount(_ view: NSView, width: CGFloat = 480) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        addTeardownBlock {
            window.contentView = nil
            window.close()
        }
        return window
    }

    // MARK: - Subtitle (edit_mode → insert / delete / replace)

    func testReplaceModeRendersEditSubtitle() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/Analysis.ipynb",
            "cell_id": "abc-1",
            "cell_type": "code",
            "new_source": "x = 1\n",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Edit cell in \("Analysis.ipynb")"),
            "Default edit_mode (replace) → the localized 'Edit cell in <basename>' headline.")
        XCTAssertEqual(
            view.subtitleMaxLines, 1, "Subtitle is single-line (SwiftUI .lineLimit(1)).")
    }

    func testInsertModeRendersInsertSubtitle() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/Foo.ipynb",
            "cell_id": "new-1",
            "cell_type": "markdown",
            "edit_mode": "insert",
            "new_source": "# Title\n",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Insert cell into \("Foo.ipynb")"),
            "edit_mode=insert → the localized 'Insert cell into <basename>' headline.")
    }

    func testDeleteModeRendersDeleteSubtitleAndSuppressesPreview() {
        // "delete" carries an empty new_source — the source preview block is
        // suppressed and the user identifies the cell from the cell label only.
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/Foo.ipynb",
            "cell_id": "doomed",
            "cell_type": "code",
            "edit_mode": "delete",
            "new_source": "",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Delete cell from \("Foo.ipynb")"),
            "edit_mode=delete → the localized 'Delete cell from <basename>' headline.")
        XCTAssertFalse(
            view.hasSourceBlock,
            "An empty new_source (typical for delete) → no monospace source block.")
    }

    func testNoNotebookPathOmitsSubtitleRow() {
        let view = makeBodyView(input: [
            "cell_id": "c1", "edit_mode": "insert", "new_source": "x",
        ])
        mount(view)
        XCTAssertNil(
            view.renderedSubtitle,
            "No notebook_path → no basename → the subtitle row is omitted entirely.")
    }

    // MARK: - Cell label (cell_id + cell_type)

    func testCellLabelUsesMarkdownTypeText() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
            "cell_type": "markdown",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedCellLabel,
            String(localized: "Cell \("c1") · \(String(localized: "markdown"))"),
            "cell_type=markdown → the localized 'Cell <id> · markdown' metadata line.")
    }

    func testCellLabelDefaultsToPythonForCodeAndMissingType() {
        let viewMissing = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
        ])
        mount(viewMissing)
        XCTAssertEqual(
            viewMissing.renderedCellLabel,
            String(localized: "Cell \("c1") · \(String(localized: "python"))"),
            "Missing cell_type → 'python' fallback.")

        let viewCode = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c2",
            "cell_type": "code",
        ])
        mount(viewCode)
        XCTAssertEqual(
            viewCode.renderedCellLabel,
            String(localized: "Cell \("c2") · \(String(localized: "python"))"),
            "cell_type=code → 'python' label text.")
    }

    func testCellLabelRowOmittedWithoutCellId() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "new_source": "x = 1\n",
        ])
        mount(view)
        XCTAssertNil(
            view.renderedCellLabel,
            "No cell_id → the cell-label row is omitted (not blank-but-present).")
    }

    // MARK: - Source preview (200pt-cap monospace scroll)

    func testSourcePreviewRendersInBoundedScrollBlock() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
            "cell_type": "code",
            "new_source": "import pandas as pd\ndf = pd.read_csv('data.csv')\n",
        ])
        mount(view)
        XCTAssertTrue(
            view.hasSourceBlock, "A non-empty new_source mounts the monospace scroll block.")
        let height = try! XCTUnwrap(view.sourceResolvedHeight)
        XCTAssertGreaterThan(
            height, 0, "A short source resolves to a positive (intrinsic) height.")
        XCTAssertLessThanOrEqual(
            height, PermissionNotebookEditCardBodyView.sourceScrollMaxHeight,
            "A short source stays at or below the 200pt cap.")
    }

    func testLongSourceCapsAt200() {
        let source = (0..<200).map { "row_\($0) = compute_value(\($0))" }
            .joined(separator: "\n")
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/big.ipynb",
            "cell_id": "c1",
            "cell_type": "code",
            "new_source": source,
        ])
        mount(view)
        let height = try! XCTUnwrap(view.sourceResolvedHeight)
        XCTAssertEqual(
            height, PermissionNotebookEditCardBodyView.sourceScrollMaxHeight, accuracy: 0.5,
            "A long source clamps to exactly the 200pt cap so the decision buttons stay on-screen.")
    }

    func testSourceBlockOmittedWhenSourceMissing() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
        ])
        mount(view)
        XCTAssertFalse(
            view.hasSourceBlock, "No new_source field → no monospace scroll block.")
    }

    // MARK: - Full surface composition (replace · python cell)

    func testFullReplaceCellRendersAllThreeRows() {
        let view = makeBodyView(input: [
            "notebook_path": "/Users/example/notebooks/analysis.ipynb",
            "edit_mode": "replace",
            "cell_type": "code",
            "cell_id": "abc-123",
            "new_source": "import pandas as pd\ndf = pd.read_csv('data.csv')\ndf.head()",
        ])
        mount(view)
        XCTAssertEqual(view.renderedSubtitle, String(localized: "Edit cell in \("analysis.ipynb")"))
        XCTAssertEqual(
            view.renderedCellLabel,
            String(localized: "Cell \("abc-123") · \(String(localized: "python"))"))
        XCTAssertTrue(view.hasSourceBlock)
        // subtitle + cell label + source block, in that order.
        XCTAssertEqual(
            view.arrangedSubviews.count, 3,
            "Full replace cell renders subtitle + cell label + source block.")
    }

    // MARK: - Sizing (no width leak — regime-B parity, plan R1)

    func testPublishesNoIntrinsicWidth() {
        let view = makeBodyView(input: [
            "notebook_path": "/tmp/x.ipynb", "cell_id": "c1", "new_source": "x",
        ])
        XCTAssertEqual(
            view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body publishes noIntrinsicMetric width so it can't leak a min-width to the host (R1).")
    }
}
