import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.fileEdit` /
/// `.fileWrite` body — `PermissionFileWriteCardBodyView` (migration plan §4.4-5,
/// §9). Drives the REAL production body builder
/// (`PermissionFileWriteCardBodyBuilder.makeBody`) with representative
/// `PermissionRequest`s and asserts the parsed fields render into the real view
/// — never a re-implemented approximation, never the SwiftUI data struct in
/// isolation (the data layer is pinned separately by
/// `PermissionFileWriteCardBodyTests`; THIS test pins the AppKit render: which
/// arm mounts, what subtitle text, and that the diff arm carries the real
/// parsed `DiffBlock` through the embedded production `DiffNSView`).
///
/// The builder is invoked directly (not via `permissionCardBodyBuilder(for:)`)
/// because the dispatch still returns the STUB until the integration step
/// repoints `.fileEdit` / `.fileWrite` — mirroring `PermissionTaskAgentBodyTests`.
@MainActor
final class PermissionFileWriteBodyTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Unique on-disk dir so the Write-overwrite case's real FS read is
        // parallel-safe (cctermTests/CLAUDE.md: per-test unique temp artifacts).
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermFWBody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Build the body through the production dispatch conformer (NOT by calling
    /// the view initializer directly) so the test exercises the same surface the
    /// card mounts.
    private func makeBodyView(
        tool: String, input: [String: Any]
    )
        -> PermissionFileWriteCardBodyView
    {
        let req = PermissionRequest.makePreview(
            requestId: "fw-\(tool)-\(UUID().uuidString)", toolName: tool, input: input)
        let view = PermissionFileWriteCardBodyBuilder()
            .makeBody(request: req, engine: nil)
        return try! XCTUnwrap(view as? PermissionFileWriteCardBodyView)
    }

    /// Mount at a fixed settled width so the embedded diff typesets at a real
    /// width and resolves its clamped height (mirrors `PermissionBoundedDiffViewTests`).
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

    // MARK: - Edit → subtitle + snippet diff

    func testEditRendersSubtitleAndSnippetDiff() {
        let path = tempDir.appendingPathComponent("Greeter.swift").path
        let view = makeBodyView(
            tool: "Edit",
            input: [
                "file_path": path,
                "old_string": "let x = 1",
                "new_string": "let x = 2",
            ])
        mount(view)

        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Edit \("Greeter.swift")"),
            "Edit headline = the localized 'Edit <basename>'.")
        XCTAssertEqual(view.subtitleMaxLines, 1, "Subtitle is single-line (SwiftUI .lineLimit(1)).")
        XCTAssertTrue(view.hasDiffView, "A resolvable Edit mounts the bounded diff arm.")
        XCTAssertFalse(view.hasFallbackHint, "The diff arm took over — no fallback hint.")

        // The diff carries the EXACT parsed old/new through the real production
        // DiffNSView (not a re-implementation) — a snippet diff, not new-file.
        let diff = try! XCTUnwrap(view.renderedDiff)
        XCTAssertEqual(diff.oldString, "let x = 1")
        XCTAssertEqual(diff.newString, "let x = 2")
        XCTAssertFalse(diff.isNewFile)

        let height = try! XCTUnwrap(view.diffResolvedHeight)
        XCTAssertGreaterThan(height, 0, "The diff resolves a positive (intrinsic) height.")
        XCTAssertLessThanOrEqual(
            height, PermissionFileWriteCardBodyView.diffMaxHeight,
            "A short diff stays at or below the 240pt cap.")
    }

    func testEditWithEmptyOldStringRendersNewFileDiff() {
        // Upstream idiom: empty old_string + non-empty new_string → new-file mode.
        let view = makeBodyView(
            tool: "Edit",
            input: [
                "file_path": tempDir.appendingPathComponent("New.swift").path,
                "old_string": "",
                "new_string": "import Foundation\n",
            ])
        mount(view)
        XCTAssertTrue(view.hasDiffView)
        let diff = try! XCTUnwrap(view.renderedDiff)
        XCTAssertTrue(diff.isNewFile, "Empty old_string renders the new-file (no '+' chrome) diff.")
        XCTAssertEqual(diff.newString, "import Foundation\n")
    }

    // MARK: - Write → Create (new file) vs Overwrite (real FS read)

    func testWriteCreateRendersCreateSubtitleAndNewFileDiff() {
        let path = tempDir.appendingPathComponent("Created.swift").path
        let view = makeBodyView(
            tool: "Write",
            input: [
                "file_path": path,
                "content": "print(\"hi\")\n",
            ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Create \("Created.swift")"),
            "A missing target file renders the 'Create <basename>' subtitle.")
        let diff = try! XCTUnwrap(view.renderedDiff)
        XCTAssertTrue(diff.isNewFile, "No existing file → new-file diff (oldString nil).")
        XCTAssertNil(diff.oldString)
        XCTAssertEqual(diff.newString, "print(\"hi\")\n")
    }

    func testWriteOverwriteReadsExistingContentAtBuildTime() throws {
        let path = tempDir.appendingPathComponent("Existing.txt").path
        let old = "line one\nline two\n"
        try old.write(toFile: path, atomically: true, encoding: .utf8)

        let view = makeBodyView(
            tool: "Write",
            input: [
                "file_path": path,
                "content": "line one\nLINE TWO\n",
            ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Overwrite \("Existing.txt")"),
            "An existing target file renders the 'Overwrite <basename>' subtitle.")
        // The synchronous FS read happened at build time and the existing
        // content rendered through the real diff surface.
        let diff = try! XCTUnwrap(view.renderedDiff)
        XCTAssertFalse(diff.isNewFile)
        XCTAssertEqual(diff.oldString, old, "The existing file content was read at build time.")
        XCTAssertEqual(diff.newString, "line one\nLINE TWO\n")
    }

    // MARK: - Fallback arm (no file_path / no diff)

    func testMissingFilePathRendersFallbackHintNotDiff() {
        let view = makeBodyView(
            tool: "Edit", input: ["old_string": "a", "new_string": "b"])
        mount(view)
        XCTAssertFalse(view.hasDiffView, "No file_path → no diff arm.")
        XCTAssertNil(view.renderedSubtitle, "No basename → the subtitle row is omitted.")
        XCTAssertTrue(view.hasFallbackHint, "The nil-diff fallback hint is mounted instead.")
        XCTAssertEqual(
            view.renderedFallbackText,
            String(localized: "Path missing — open the transcript to inspect"),
            "The fallback hint renders the localized secondary-text string.")
    }

    func testCamelCaseFilePathStillResolvesSubtitle() {
        // Pre-v2 builds ship camelCase `filePath`.
        let view = makeBodyView(
            tool: "Edit",
            input: [
                "filePath": tempDir.appendingPathComponent("Sample.txt").path,
                "old_string": "a",
                "new_string": "b",
            ])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Edit \("Sample.txt")"),
            "camelCase filePath is accepted (parity with the data layer).")
        XCTAssertTrue(view.hasDiffView)
    }

    // MARK: - Tall diff caps at 240 (decision buttons stay reachable)

    func testTallWriteDiffClampsToCap() {
        let path = tempDir.appendingPathComponent("Tall.swift").path
        let body = (0..<80).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let view = makeBodyView(
            tool: "Write", input: ["file_path": path, "content": body])
        mount(view)
        let height = try! XCTUnwrap(view.diffResolvedHeight)
        XCTAssertEqual(
            height, PermissionFileWriteCardBodyView.diffMaxHeight, accuracy: 0.5,
            "A long diff clamps to exactly the 240pt cap so the decision buttons stay on-screen.")
    }

    // MARK: - Sizing (no width leak — regime-B parity, plan R1)

    func testPublishesNoIntrinsicWidth() {
        let view = makeBodyView(
            tool: "Edit",
            input: [
                "file_path": tempDir.appendingPathComponent("X.swift").path,
                "old_string": "a", "new_string": "b",
            ])
        XCTAssertEqual(
            view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body publishes noIntrinsicMetric width so it can't leak a min-width to the host (R1).")
    }
}
