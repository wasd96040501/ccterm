import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate logic / measurement tests for the AppKit `.sedEdit` permission-card
/// body (`PermissionSedEditCardBody.swift`, `InputBarControls/AppKit/`). NOT a
/// snapshot — runs on the unfiltered `make test-unit` suite.
///
/// These drive the REAL production surface (plan §9 — no test-only seam, no
/// re-implementation): the registered `PermissionSedEditCardBodyBuilder`
/// `makeBody`, the `PermissionSedEditCardData` per-kind getters, and the
/// resulting `PermissionSedEditCardBodyView`'s arranged subviews. Each test
/// asserts the parsed fields actually render (subtitle, diff arm, nil-arm
/// fallback + literal command) against the real objects.
@MainActor
final class PermissionSedEditBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Data getters (verbatim parity with the SwiftUI body)

    func testDataDiffBlockShowsSubstitution() throws {
        let url = try writeTempFile(contents: "hello world\n")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let data = makeData(command: "sed -i 's/hello/HELLO/' \(url.path)")
        let diff = try XCTUnwrap(data.diffBlock)
        XCTAssertEqual(diff.filePath, url.path)
        XCTAssertEqual(diff.oldString, "hello world\n")
        XCTAssertEqual(diff.newString, "HELLO world\n")
    }

    func testDataGlobalFlagReplacesAllOccurrences() throws {
        let url = try writeTempFile(contents: "foo foo foo")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let data = makeData(command: "sed -i 's/foo/bar/g' \(url.path)")
        XCTAssertEqual(data.diffBlock?.newString, "bar bar bar")
    }

    func testDataSubtitleUsesBasename() throws {
        let url = try writeTempFile(contents: "")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let data = makeData(command: "sed -i 's/x/y/' \(url.path)")
        XCTAssertEqual(
            data.subtitle, String(localized: "Edit \(url.lastPathComponent)"))
    }

    func testDataMissingFileProducesNilDiffButParsedInfo() {
        let data = makeData(
            command: "sed -i 's/x/y/' /tmp/ccterm-sed-not-here-\(UUID()).txt")
        XCTAssertNotNil(data.info, "the command parses…")
        XCTAssertNil(data.diffBlock, "…but the file is unreadable, so no diff")
    }

    func testDataUnparseableCommandKeepsLiteralCommand() {
        // Piped sed isn't a file edit — info is nil, the literal command
        // survives for the fallback arm.
        let raw = "sed 's/x/y/' a.txt | tee b.txt"
        let data = makeData(command: raw)
        XCTAssertNil(data.info)
        XCTAssertNil(data.diffBlock)
        XCTAssertEqual(data.command, raw)
    }

    // MARK: - Body rendering (the real builder → real view)

    func testBuilderRendersDiffArmWhenSubstitutionPreviews() throws {
        let url = try writeTempFile(contents: "alpha beta\n")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let body = try makeRenderedBody(
            command: "sed -i 's/alpha/ALPHA/' \(url.path)")

        // Diff arm present, fallback / command absent.
        let diff = try XCTUnwrap(body.diffView, "diff arm should render")
        XCTAssertEqual(diff.diff.newString, "ALPHA beta\n")
        XCTAssertNil(body.fallbackLabel)
        XCTAssertNil(body.commandLabel)

        // Subtitle renders the basename.
        let subtitle = try XCTUnwrap(body.subtitleLabel)
        XCTAssertEqual(
            subtitle.stringValue, String(localized: "Edit \(url.lastPathComponent)"))
        // The diff cap is the verbatim 240pt.
        XCTAssertEqual(diff.maxHeight, PermissionSedEditCardData.diffMaxHeight)
        XCTAssertEqual(PermissionSedEditCardData.diffMaxHeight, 240, accuracy: 0.001)
    }

    func testBuilderRendersFallbackAndLiteralCommandWhenUnparseable() throws {
        // A piped command never previews → fallback text + literal command.
        let raw = "sed 's/x/y/' a.txt | tee b.txt"
        let body = try makeRenderedBody(command: raw)

        XCTAssertNil(body.diffView, "no diff arm when the substitution can't preview")
        XCTAssertNil(body.subtitleLabel, "no basename ⇒ no subtitle")

        let fallback = try XCTUnwrap(body.fallbackLabel)
        XCTAssertEqual(
            fallback.stringValue, String(localized: "Could not preview sed substitution"))

        // SedEdit's unique affordance: the literal command renders below the
        // fallback so the user still sees what the agent asked to run.
        let command = try XCTUnwrap(body.commandLabel)
        XCTAssertEqual(command.stringValue, raw)
        XCTAssertTrue(command.isSelectable, "command is ⌘C-selectable (.textSelection)")
        XCTAssertEqual(command.maximumNumberOfLines, 4, "lineLimit(4)")
        XCTAssertEqual(command.lineBreakMode, .byTruncatingTail, "truncationMode(.tail)")
    }

    func testBuilderRendersFallbackWithCommandWhenFileMissing() throws {
        // Parseable command, missing file: nil diff arm, fallback + the literal
        // (parseable) command both render.
        let raw = "sed -i 's/x/y/' /tmp/ccterm-sed-missing-\(UUID()).txt"
        let body = try makeRenderedBody(command: raw)

        XCTAssertNil(body.diffView)
        XCTAssertNotNil(body.fallbackLabel)
        let command = try XCTUnwrap(body.commandLabel)
        XCTAssertEqual(command.stringValue, raw)
    }

    func testBuilderRendersNoCommandLabelWhenCommandEmpty() throws {
        // Empty command ⇒ nil diff, fallback present, but NO command label
        // (mirrors the SwiftUI `if let command` guard).
        let body = try makeRenderedBody(command: "")
        XCTAssertNil(body.diffView)
        XCTAssertNotNil(body.fallbackLabel)
        XCTAssertNil(body.commandLabel)
    }

    /// The body view publishes `noIntrinsicMetric` on both axes so it can never
    /// leak a min-width up into the full-pane card host and collapse the window
    /// (plan R1).
    func testBodyPublishesNoIntrinsicMetric() throws {
        let body = try makeRenderedBody(command: "sed 's/x/y/' a | b")
        XCTAssertEqual(body.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(body.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    // MARK: - Helpers

    private func makeData(command: String) -> PermissionSedEditCardData {
        PermissionSedEditCardData(request: makeRequest(command: command))
    }

    /// Drive the REAL registered builder (`makeBody`) and downcast to the
    /// concrete view to read its arranged subviews — no stub, no re-impl.
    private func makeRenderedBody(command: String) throws -> PermissionSedEditCardBodyView {
        let builder = PermissionSedEditCardBodyBuilder()
        let view = builder.makeBody(request: makeRequest(command: command), engine: nil)
        return try XCTUnwrap(
            view as? PermissionSedEditCardBodyView,
            "the .sedEdit builder must produce a PermissionSedEditCardBodyView")
    }

    private func makeRequest(command: String) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "sed-\(UUID().uuidString)",
            toolName: "Bash",
            input: ["command": command])
    }

    /// Per-test temp file under `temporaryDirectory` (per
    /// `cctermTests/CLAUDE.md` rule #2), cleaned up via `addTeardownBlock`.
    private func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sed-body-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
