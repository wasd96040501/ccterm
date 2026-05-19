import AgentSDK
import Foundation
import XCTest

@testable import ccterm

/// Logic tests for the sedEdit body's DiffBlock derivation. The
/// parser has its own suite; here we only verify the wiring: the
/// body reads the file, runs the substitution through the parser,
/// and packages an old/new DiffBlock for `DiffView`.
final class PermissionSedEditCardBodyTests: XCTestCase {

    func testDiffBlockShowsSubstitution() throws {
        let url = try writeTempFile(contents: "hello world\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let body = makeBody(
            command: "sed -i 's/hello/HELLO/' \(url.path)")
        let diff = body.diffBlock
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.filePath, url.path)
        XCTAssertEqual(diff?.oldString, "hello world\n")
        XCTAssertEqual(diff?.newString, "HELLO world\n")
    }

    func testGlobalFlagReplacesAllOccurrences() throws {
        let url = try writeTempFile(contents: "foo foo foo")
        defer { try? FileManager.default.removeItem(at: url) }

        let body = makeBody(command: "sed -i 's/foo/bar/g' \(url.path)")
        XCTAssertEqual(body.diffBlock?.newString, "bar bar bar")
    }

    func testFileMissingProducesNilDiff() {
        let body = makeBody(command: "sed -i 's/x/y/' /tmp/definitely-not-here-\(UUID()).txt")
        XCTAssertNotNil(body.info)
        XCTAssertNil(body.diffBlock)
    }

    func testUnparseableCommandProducesNilInfo() {
        // Piped sed isn't a file edit — info is nil and the body
        // falls back to showing the literal command. Pin that here
        // so dispatching here from `kind(for:)` stays safe.
        let body = makeBody(command: "sed 's/x/y/' a.txt | tee b.txt")
        XCTAssertNil(body.info)
        XCTAssertNil(body.diffBlock)
        XCTAssertEqual(body.command, "sed 's/x/y/' a.txt | tee b.txt")
    }

    func testSubtitleUsesBasename() throws {
        let url = try writeTempFile(contents: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = makeBody(command: "sed -i 's/x/y/' \(url.path)")
        XCTAssertEqual(
            body.subtitle,
            String(localized: "Edit \(url.lastPathComponent)"))
    }

    // MARK: - Helpers

    private func makeBody(command: String) -> PermissionSedEditCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "sed-\(UUID().uuidString)",
            toolName: "Bash",
            input: ["command": command])
        return PermissionSedEditCardBody(request: req)
    }

    /// Per-test temp file written to a unique path under
    /// `temporaryDirectory` (per `cctermTests/CLAUDE.md` rule #2).
    /// The teardown block removes it so parallel test classes don't
    /// trip over each other.
    private func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sed-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
