import AppKit
import XCTest

@testable import ccterm

/// The file document as a change, a new file and a read, and a change that
/// failed, in light and dark (design/transcript/03-file.md). Review only —
/// `make test-unit FILTER=SourceDocumentViewControllerSnapshotTests`, then
/// open `/tmp/ccterm-screenshots/SourceDocumentViewController-<state>.png`.
@MainActor
final class SourceDocumentViewControllerSnapshotTests: XCTestCase {
    private let size = CGSize(width: 640, height: 300)

    private static let swift = """
        import AppKit

        final class TranscriptView: NSView {
            var rowSpacing: CGFloat = 6 // gap between rows
            func reload() {
                let count = rows.count
                guard count > 0 else { return }
                print("rows: \\(count)")
            }
        }
        """

    private func snapshot(_ name: String, _ mode: SourceDocumentViewController.Mode) {
        let sheet = ViewSnapshot.renderLightAndDark(
            { SourceDocumentViewController(mode) }, size: size, name: name)
        let url = ViewSnapshot.writePNG(sheet, name: "SourceDocumentViewController-\(name)")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAChangeWithFoldsAndTheCharactersThatDiffer() {
        let edit = ToolCallFixture.edit(
            "/r/TranscriptView.swift", old: "private var rowSpacing: CGFloat = 4", new: "var rowSpacing: CGFloat = 6",
            hunks: [
                ToolCallFixture.hunk(
                    oldStart: 13, oldLines: 4, newStart: 13, newLines: 4,
                    lines: [
                        " final class TranscriptView: NSView {", "-    private var rowSpacing: CGFloat = 4",
                        "+    var rowSpacing: CGFloat = 6", "     func reload() {",
                        "         let count = rows.count",
                    ]),
                ToolCallFixture.hunk(
                    oldStart: 60, oldLines: 3, newStart: 60, newLines: 4,
                    lines: [" }", "+    // done", " }", " "]),
            ], originalFile: (1...80).map { "line \($0)" }.joined(separator: "\n"))
        snapshot("change", .change([edit]))
    }

    func testANewFileAndARead() {
        snapshot("new", .newFile(ToolCallFixture.write("/r/TranscriptView.swift", content: Self.swift)))
        snapshot(
            "read",
            .read(ToolCallFixture.read("/r/TranscriptView.swift", content: Self.swift, startLine: 40, total: 880)))
    }

    func testAFailedChangeShowsTheProposalUnderItsError() {
        let failed = ToolCallFixture.call(
            "Edit", #"{"file_path":"/r/A.swift","old_string":"let a = 1","new_string":"let a = 2\nlet b = 3"}"#,
            state: .failed(message: "<tool_use_error>String to replace not found in file.</tool_use_error>"),
            isError: true)
        snapshot("failed", .change([failed]))
    }
}
