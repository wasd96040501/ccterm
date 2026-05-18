import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the filesystem-read body's per-tool data
/// extraction: Read picks `file_path`, Glob/Grep pick `pattern` +
/// optional `path` / `output_mode`. Tests compare against
/// `String(localized:)` because the suite runs under the system
/// locale (zh-Hans on the build box).
final class PermissionFilesystemReadCardBodyTests: XCTestCase {

    func testReadShowsFilePathAsPrimary() {
        let body = makeBody(
            toolName: "Read",
            input: ["file_path": "/repo/src/main.swift"])
        XCTAssertEqual(body.toolLabel, String(localized: "Read"))
        XCTAssertEqual(body.primary, "/repo/src/main.swift")
        XCTAssertNil(body.secondary)
    }

    func testReadAcceptsCamelCaseFilePath() {
        // Older builds emit `filePath`. Both spellings should resolve
        // — the body falls through `file_path` → `filePath` → `path`.
        let body = makeBody(
            toolName: "Read",
            input: ["filePath": "/repo/legacy.swift"])
        XCTAssertEqual(body.primary, "/repo/legacy.swift")
    }

    func testFileReadAliasUsesSameShape() {
        // The `FileRead` alias maps to the same kind upstream; the
        // body keeps the "Read" headline so the user sees the same
        // affordance regardless of which alias the CLI emitted.
        let body = makeBody(
            toolName: "FileRead",
            input: ["file_path": "/repo/a.txt"])
        XCTAssertEqual(body.toolLabel, String(localized: "Read"))
        XCTAssertEqual(body.primary, "/repo/a.txt")
    }

    func testGlobShowsPatternAsPrimary() {
        let body = makeBody(
            toolName: "Glob",
            input: ["pattern": "**/*.swift"])
        XCTAssertEqual(body.toolLabel, String(localized: "Glob"))
        XCTAssertEqual(body.primary, "**/*.swift")
        XCTAssertNil(body.secondary)
    }

    func testGlobShowsPathAsSecondary() {
        // Glob's `path` field narrows the search root — surface it
        // below the pattern so the user can see exactly what gets
        // walked.
        let body = makeBody(
            toolName: "Glob",
            input: ["pattern": "**/*.ts", "path": "src/"])
        XCTAssertEqual(body.primary, "**/*.ts")
        // Interpolated form so the catalog key resolves to "path: %@"
        // and the system locale's translation is applied — bare
        // String(localized: "path: src/") would look up an absent
        // literal key and fall back to English on a zh-Hans box.
        let srcPath = "src/"
        XCTAssertEqual(body.secondary, String(localized: "path: \(srcPath)"))
    }

    func testGrepShowsPatternAndPath() {
        let body = makeBody(
            toolName: "Grep",
            input: ["pattern": "TODO", "path": "src/"])
        XCTAssertEqual(body.toolLabel, String(localized: "Grep"))
        XCTAssertEqual(body.primary, "TODO")
        let srcPath = "src/"
        XCTAssertEqual(body.secondary, String(localized: "path: \(srcPath)"))
    }

    func testGrepCombinesPathAndOutputMode() {
        // When both `path` and `output_mode` are present, the
        // secondary line joins them with " · " — same separator the
        // notebook body uses for cell metadata, keeps the surface
        // consistent.
        let body = makeBody(
            toolName: "Grep",
            input: [
                "pattern": "fn ",
                "path": "src/",
                "output_mode": "files_with_matches",
            ])
        let srcPath = "src/"
        let modeVal = "files_with_matches"
        let path = String(localized: "path: \(srcPath)")
        let mode = String(localized: "mode: \(modeVal)")
        XCTAssertEqual(body.secondary, "\(path) · \(mode)")
    }

    func testEmptyFieldsAreTreatedAsNil() {
        // Upstream tolerates missing/empty fields — the body should
        // collapse the row instead of rendering an "—" placeholder
        // since the headline alone already conveys the action.
        let body = makeBody(
            toolName: "Read", input: ["file_path": ""])
        XCTAssertNil(body.primary)
        XCTAssertNil(body.secondary)
    }

    func testIconForEachTool() {
        XCTAssertEqual(makeBody(toolName: "Read", input: [:]).iconName, "doc.text")
        XCTAssertEqual(makeBody(toolName: "Glob", input: [:]).iconName, "doc.text.magnifyingglass")
        XCTAssertEqual(makeBody(toolName: "Grep", input: [:]).iconName, "text.magnifyingglass")
    }

    // MARK: - Helpers

    private func makeBody(
        toolName: String, input: [String: Any]
    )
        -> PermissionFilesystemReadCardBody
    {
        let req = PermissionRequest.makePreview(
            requestId: "fs-\(UUID().uuidString)",
            toolName: toolName,
            input: input)
        return PermissionFilesystemReadCardBody(request: req)
    }
}
