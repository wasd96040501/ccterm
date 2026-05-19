import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the file-write body: subtitle resolution
/// (Edit / Create / Overwrite) and the `DiffBlock` it would hand to
/// `DiffView`. The view itself is rendered in the snapshot suite —
/// here we pin the pure data extraction across the four input
/// shapes the upstream CLI emits for Edit and Write.
final class PermissionFileWriteCardBodyTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermFW-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Edit

    func testEditProducesSnippetDiffBlock() {
        let req = makeRequest(
            toolName: "Edit",
            input: [
                "file_path": tempDir.appendingPathComponent("Greeter.swift").path,
                "old_string": "let x = 1",
                "new_string": "let x = 2",
            ])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileEdit)

        XCTAssertEqual(body.basename, "Greeter.swift")
        XCTAssertEqual(body.subtitle, String(localized: "Edit \("Greeter.swift")"))
        let diff = try! XCTUnwrap(body.diffBlock)
        XCTAssertEqual(diff.oldString, "let x = 1")
        XCTAssertEqual(diff.newString, "let x = 2")
        XCTAssertFalse(diff.isNewFile)
    }

    func testEditWithEmptyOldStringIsTreatedAsNewFile() {
        // The upstream CLI uses an empty `old_string` to mean "write
        // these lines to a new file as the first content". DiffView
        // suppresses `+` chrome in that mode so the result reads as
        // a line-numbered code view, not "a diff that's all additions".
        let req = makeRequest(
            toolName: "Edit",
            input: [
                "file_path": tempDir.appendingPathComponent("New.swift").path,
                "old_string": "",
                "new_string": "import Foundation\n",
            ])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileEdit)
        let diff = try! XCTUnwrap(body.diffBlock)
        XCTAssertTrue(diff.isNewFile)
        XCTAssertEqual(diff.newString, "import Foundation\n")
    }

    func testEditAcceptsCamelCaseFilePath() {
        // Pre-v2 builds sometimes ship camelCase.
        let req = makeRequest(
            toolName: "Edit",
            input: [
                "filePath": "/tmp/Sample.txt",
                "old_string": "a",
                "new_string": "b",
            ])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileEdit)
        XCTAssertEqual(body.filePath, "/tmp/Sample.txt")
        XCTAssertEqual(body.subtitle, String(localized: "Edit \("Sample.txt")"))
    }

    func testEditWithoutFilePathYieldsNoDiff() {
        let req = makeRequest(
            toolName: "Edit",
            input: ["old_string": "a", "new_string": "b"])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileEdit)
        XCTAssertNil(body.diffBlock)
        XCTAssertNil(body.subtitle)
    }

    // MARK: - Write

    func testWriteCreateUsesNewFileMode() {
        let path = tempDir.appendingPathComponent("Created.swift").path
        let req = makeRequest(
            toolName: "Write",
            input: [
                "file_path": path,
                "content": "print(\"hi\")\n",
            ])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileWrite)

        XCTAssertFalse(body.fileExists)
        XCTAssertEqual(body.subtitle, String(localized: "Create \("Created.swift")"))
        let diff = try! XCTUnwrap(body.diffBlock)
        XCTAssertTrue(diff.isNewFile)
        XCTAssertNil(diff.oldString)
        XCTAssertEqual(diff.newString, "print(\"hi\")\n")
    }

    func testWriteOverwriteReadsExistingContent() throws {
        let path = tempDir.appendingPathComponent("Existing.txt").path
        let old = "line one\nline two\n"
        try old.write(toFile: path, atomically: true, encoding: .utf8)

        let req = makeRequest(
            toolName: "Write",
            input: [
                "file_path": path,
                "content": "line one\nLINE TWO\n",
            ])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileWrite)

        XCTAssertTrue(body.fileExists)
        XCTAssertEqual(body.subtitle, String(localized: "Overwrite \("Existing.txt")"))
        let diff = try! XCTUnwrap(body.diffBlock)
        XCTAssertFalse(diff.isNewFile)
        XCTAssertEqual(diff.oldString, old)
        XCTAssertEqual(diff.newString, "line one\nLINE TWO\n")
    }

    func testWriteWithoutFilePathYieldsNoDiff() {
        let req = makeRequest(
            toolName: "Write",
            input: ["content": "hi"])
        let body = PermissionFileWriteCardBody(request: req, kind: .fileWrite)
        XCTAssertNil(body.diffBlock)
        XCTAssertNil(body.subtitle)
    }

    // MARK: - Helpers

    private func makeRequest(toolName: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "fw-\(toolName)-\(UUID().uuidString)",
            toolName: toolName,
            input: input)
    }
}
