import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit
/// `PermissionFilesystemReadCardBodyView` (migration plan §4.4, §9). Drives the
/// REAL body view built through the production `PermissionFilesystemReadCardBodyBuilder`
/// (the dispatch's `.filesystemRead` arm), and asserts the parsed per-tool
/// fields actually RENDER into the view's labels — not just that the data
/// getters return the right strings.
///
/// Tests compare against `String(localized:)` because the suite runs under the
/// system locale (zh-Hans on the build box) — same convention as the original
/// `PermissionFilesystemReadCardBodyTests`.
@MainActor
final class PermissionFilesystemReadBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func request(toolName: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "fs-\(UUID().uuidString)",
            toolName: toolName,
            input: input)
    }

    /// Build the body the production way — through the dispatch builder — and
    /// downcast to the concrete view so the test reads its rendered surface.
    private func makeBody(
        toolName: String, input: [String: Any]
    ) throws -> PermissionFilesystemReadCardBodyView {
        let builder = PermissionFilesystemReadCardBodyBuilder()
        let view = builder.makeBody(request: request(toolName: toolName, input: input), engine: nil)
        return try XCTUnwrap(
            view as? PermissionFilesystemReadCardBodyView,
            "The .filesystemRead builder must produce a PermissionFilesystemReadCardBodyView.")
    }

    /// Mount the body in a container and settle layout so the rendered labels
    /// reflect their final state.
    @discardableResult
    private func mounted(_ body: PermissionFilesystemReadCardBodyView) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return container
    }

    // MARK: - Read: file_path renders as the primary line, no secondary

    func testReadRendersFilePathAsPrimary() throws {
        let body = try makeBody(toolName: "Read", input: ["file_path": "/repo/src/main.swift"])
        mounted(body)
        XCTAssertEqual(body.renderedToolLabel, String(localized: "Read"))
        XCTAssertEqual(body.renderedPrimary, "/repo/src/main.swift")
        XCTAssertNil(body.renderedSecondary, "Read has no secondary line.")
        XCTAssertEqual(body.renderedIconSymbol, "doc.text")
    }

    func testReadAcceptsCamelCaseFilePath() throws {
        // Older builds emit `filePath`. The body falls through file_path →
        // filePath → path.
        let body = try makeBody(toolName: "Read", input: ["filePath": "/repo/legacy.swift"])
        mounted(body)
        XCTAssertEqual(body.renderedPrimary, "/repo/legacy.swift")
    }

    func testFileReadAliasUsesReadHeadline() throws {
        // The `FileRead` alias maps to the same kind upstream; the body keeps
        // the "Read" headline.
        let body = try makeBody(toolName: "FileRead", input: ["file_path": "/repo/a.txt"])
        mounted(body)
        XCTAssertEqual(body.renderedToolLabel, String(localized: "Read"))
        XCTAssertEqual(body.renderedPrimary, "/repo/a.txt")
    }

    // MARK: - Glob: pattern primary + optional path secondary

    func testGlobRendersPatternAsPrimary() throws {
        let body = try makeBody(toolName: "Glob", input: ["pattern": "**/*.swift"])
        mounted(body)
        XCTAssertEqual(body.renderedToolLabel, String(localized: "Glob"))
        XCTAssertEqual(body.renderedPrimary, "**/*.swift")
        XCTAssertNil(body.renderedSecondary)
        XCTAssertEqual(body.renderedIconSymbol, "doc.text.magnifyingglass")
    }

    func testGlobRendersPathAsSecondary() throws {
        let body = try makeBody(
            toolName: "Glob", input: ["pattern": "**/*.ts", "path": "src/"])
        mounted(body)
        XCTAssertEqual(body.renderedPrimary, "**/*.ts")
        let srcPath = "src/"
        XCTAssertEqual(body.renderedSecondary, String(localized: "path: \(srcPath)"))
    }

    // MARK: - Grep: pattern primary + path/mode secondary join

    func testGrepRendersPatternAndPath() throws {
        let body = try makeBody(
            toolName: "Grep", input: ["pattern": "TODO", "path": "src/"])
        mounted(body)
        XCTAssertEqual(body.renderedToolLabel, String(localized: "Grep"))
        XCTAssertEqual(body.renderedPrimary, "TODO")
        let srcPath = "src/"
        XCTAssertEqual(body.renderedSecondary, String(localized: "path: \(srcPath)"))
        XCTAssertEqual(body.renderedIconSymbol, "text.magnifyingglass")
    }

    func testGrepCombinesPathAndOutputModeWithMiddleDot() throws {
        let body = try makeBody(
            toolName: "Grep",
            input: [
                "pattern": "fn ",
                "path": "src/",
                "output_mode": "files_with_matches",
            ])
        mounted(body)
        let srcPath = "src/"
        let modeVal = "files_with_matches"
        let path = String(localized: "path: \(srcPath)")
        let mode = String(localized: "mode: \(modeVal)")
        XCTAssertEqual(body.renderedSecondary, "\(path) · \(mode)")
    }

    // MARK: - Empty fields collapse the optional rows (no placeholder)

    func testEmptyFieldsCollapseRows() throws {
        let body = try makeBody(toolName: "Read", input: ["file_path": ""])
        mounted(body)
        // The headline alone renders; both optional monospace rows are absent.
        XCTAssertEqual(body.renderedToolLabel, String(localized: "Read"))
        XCTAssertNil(body.renderedPrimary, "Empty file_path must not render an '—' placeholder row.")
        XCTAssertNil(body.renderedSecondary)
    }

    // MARK: - Parity: line limits + selectability

    func testPrimaryWrapsToTwoLinesSelectable() throws {
        let body = try makeBody(toolName: "Read", input: ["file_path": "/a/b/c.swift"])
        mounted(body)
        XCTAssertEqual(
            body.primaryMaxLines, PermissionFilesystemReadCardBodyView.primaryLineLimit,
            "Primary line limit = 2 (SwiftUI .lineLimit(2)).")
    }

    func testSecondaryIsSingleLine() throws {
        let body = try makeBody(
            toolName: "Glob", input: ["pattern": "*.swift", "path": "src/"])
        mounted(body)
        XCTAssertEqual(
            body.secondaryMaxLines, PermissionFilesystemReadCardBodyView.secondaryLineLimit,
            "Secondary line limit = 1 (SwiftUI .lineLimit(1)).")
    }

    // MARK: - Constants match the SwiftUI source verbatim

    func testLayoutConstantsMatchSource() {
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.rowSpacing, 8)
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.columnSpacing, 4)
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.iconFrameWidth, 14)
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.iconSize, 12)
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.primaryFontSize, 12)
        XCTAssertEqual(PermissionFilesystemReadCardBodyView.secondaryFontSize, 11)
    }

    // MARK: - R1: the body publishes no intrinsic min-width (no leak to host)

    func testPublishesNoIntrinsicWidth() throws {
        // A long path / pattern must not surface as a body min-width that could
        // leak up into the full-pane card host and collapse the window (plan R1).
        let body = try makeBody(
            toolName: "Read",
            input: ["file_path": "/very/long/repository/path/that/keeps/going/main.swift"])
        mounted(body)
        XCTAssertEqual(body.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(body.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }
}
