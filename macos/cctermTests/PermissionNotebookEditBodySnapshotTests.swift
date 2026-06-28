import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshot tests (opt-in; NOT a CI gate — the runner SKIPS
/// `*SnapshotTests.swift` on the unfiltered suite) for the AppKit `.notebookEdit`
/// permission-card body. Renders the real `PermissionNotebookEditCardBodyView`
/// (built through the production dispatch conformer) so the
/// subtitle + cell label + capped monospace source-scroll parity can be eyeballed
/// against the SwiftUI `PermissionNotebookEditCardBody` original. The three cases
/// mirror that file's three `#Preview`s
/// (`PermissionNotebookEditCardBody.swift:107-158`): replace · python cell,
/// insert · markdown cell, and delete · empty source (preview suppressed). The
/// CI gate is the non-snapshot `PermissionNotebookEditBodyTests`.
///
/// Run: `make test-unit FILTER=PermissionNotebookEditBodySnapshotTests`, then open
/// the PNGs under `/tmp/ccterm-screenshots/`.
@MainActor
final class PermissionNotebookEditBodySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap a bare NSView (pinned, padded) in a throwaway VC over a window-tinted
    /// backdrop, for a given appearance — mirrors `PermissionTaskAgentBodySnapshotTests.host`
    /// and the original `#Preview`'s `.padding(14).frame(width: 520)` envelope.
    private func host(
        _ view: NSView, appearance: NSAppearance.Name, width: CGFloat = 520, padding: CGFloat = 14
    ) -> NSViewController {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            view.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor, constant: -padding),
            view.widthAnchor.constraint(equalToConstant: width - 2 * padding),
        ])
        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func attach(_ image: NSImage, _ name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Build the body through the production dispatch conformer (the spine's
    /// same-named STUB coexists pre-integration; the dispatch wiring is pinned by
    /// `PermissionCardDispatchTests`).
    private func body(_ input: [String: Any]) -> NSView {
        let req = PermissionRequest.makePreview(
            requestId: "nb-snap-\(UUID().uuidString)", toolName: "NotebookEdit", input: input)
        return PermissionNotebookEditCardBodyBuilder().makeBody(request: req, engine: nil)
    }

    // MARK: - replace · python cell (the full surface — preview #1)

    func testReplacePythonCellSnapshot() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = body([
                "notebook_path": "/Users/example/notebooks/analysis.ipynb",
                "edit_mode": "replace",
                "cell_type": "code",
                "cell_id": "abc-123",
                "new_source": "import pandas as pd\ndf = pd.read_csv('data.csv')\ndf.head()",
            ])
            let vc = host(view, appearance: appearance)
            let image = ViewSnapshot.renderViewController(
                vc, size: CGSize(width: 520, height: 220))
            attach(
                image,
                "PermissionNotebookEditBody-replace-\(appearance == .aqua ? "light" : "dark")")
            XCTAssertGreaterThanOrEqual(image.size.width, 480)
        }
    }

    // MARK: - insert · markdown cell (preview #2)

    func testInsertMarkdownCellSnapshot() throws {
        let view = body([
            "notebook_path": "/Users/example/notebooks/analysis.ipynb",
            "edit_mode": "insert",
            "cell_type": "markdown",
            "cell_id": "intro",
            "new_source": "## Overview\n\nThis notebook explores the dataset.",
        ])
        let vc = host(view, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 200))
        attach(image, "PermissionNotebookEditBody-insert-markdown")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }

    // MARK: - delete · empty source (preview #3 — source-scroll suppressed)

    func testDeleteEmptySourceSnapshot() throws {
        let view = body([
            "notebook_path": "/Users/example/notebooks/analysis.ipynb",
            "edit_mode": "delete",
            "cell_type": "code",
            "cell_id": "stale-cell-7",
        ])
        let vc = host(view, appearance: .darkAqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 120))
        attach(image, "PermissionNotebookEditBody-delete-empty")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }

    // MARK: - long source · clamps to the 200pt scroll cap

    func testLongSourceCapsSnapshot() throws {
        let source = (0..<60).map { "row_\($0) = compute_value(\($0))" }
            .joined(separator: "\n")
        let view = body([
            "notebook_path": "/Users/example/notebooks/big.ipynb",
            "edit_mode": "replace",
            "cell_type": "code",
            "cell_id": "c1",
            "new_source": source,
        ])
        let vc = host(view, appearance: .aqua)
        let image = ViewSnapshot.renderViewController(vc, size: CGSize(width: 520, height: 320))
        attach(image, "PermissionNotebookEditBody-long-source")
        XCTAssertGreaterThanOrEqual(image.size.width, 480)
    }
}
