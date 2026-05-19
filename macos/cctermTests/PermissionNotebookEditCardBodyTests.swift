import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the NotebookEdit body's data extraction: it
/// pulls `notebook_path`, `cell_id`, `cell_type`, `edit_mode`, and
/// `new_source` from `rawInput` and derives a subtitle (insert /
/// delete / replace) plus a cell-type-labeled metadata line.
final class PermissionNotebookEditCardBodyTests: XCTestCase {

    func testReplaceModeIsDefaultSubtitle() {
        // `edit_mode` defaults to "replace" upstream; the card shows
        // "Edit cell in <basename>".
        let body = makeBody(input: [
            "notebook_path": "/tmp/Analysis.ipynb",
            "cell_id": "abc-1",
            "cell_type": "code",
            "new_source": "x = 1\n",
        ])
        XCTAssertEqual(body.editMode, "replace")
        XCTAssertEqual(body.subtitle, String(localized: "Edit cell in \("Analysis.ipynb")"))
    }

    func testInsertSubtitle() {
        let body = makeBody(input: [
            "notebook_path": "/tmp/Foo.ipynb",
            "cell_id": "new-1",
            "cell_type": "markdown",
            "edit_mode": "insert",
            "new_source": "# Title\n",
        ])
        XCTAssertEqual(body.subtitle, String(localized: "Insert cell into \("Foo.ipynb")"))
    }

    func testDeleteSubtitleAndEmptyPreview() {
        // "delete" carries an empty new_source; the preview block is
        // suppressed and the user identifies the cell via cellLabel.
        let body = makeBody(input: [
            "notebook_path": "/tmp/Foo.ipynb",
            "cell_id": "doomed",
            "cell_type": "code",
            "edit_mode": "delete",
            "new_source": "",
        ])
        XCTAssertEqual(body.subtitle, String(localized: "Delete cell from \("Foo.ipynb")"))
        XCTAssertNil(body.sourcePreview)
    }

    func testCellLabelUsesMarkdownTypeText() {
        let body = makeBody(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
            "cell_type": "markdown",
        ])
        XCTAssertEqual(
            body.cellLabel,
            String(localized: "Cell \("c1") · \(String(localized: "markdown"))"))
    }

    func testCellLabelDefaultsToPython() {
        // Missing or unknown cell_type falls back to "python" so the
        // monospaced preview renders against a sensible default.
        let bodyMissing = makeBody(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c1",
        ])
        XCTAssertEqual(
            bodyMissing.cellLabel,
            String(localized: "Cell \("c1") · \(String(localized: "python"))"))

        let bodyCode = makeBody(input: [
            "notebook_path": "/tmp/x.ipynb",
            "cell_id": "c2",
            "cell_type": "code",
        ])
        XCTAssertEqual(
            bodyCode.cellLabel,
            String(localized: "Cell \("c2") · \(String(localized: "python"))"))
    }

    func testCellLabelNilWithoutCellId() {
        let body = makeBody(input: [
            "notebook_path": "/tmp/x.ipynb"
        ])
        XCTAssertNil(body.cellLabel)
    }

    func testWithoutNotebookPathYieldsNoSubtitle() {
        let body = makeBody(input: [
            "cell_id": "c1", "edit_mode": "insert", "new_source": "x",
        ])
        XCTAssertNil(body.subtitle)
    }

    // MARK: - Helpers

    private func makeBody(input: [String: Any]) -> PermissionNotebookEditCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "nb-\(UUID().uuidString)",
            toolName: "NotebookEdit",
            input: input)
        return PermissionNotebookEditCardBody(request: req)
    }
}
