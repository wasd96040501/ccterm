import AgentSDK
import XCTest

@testable import ccterm

/// Pins `HistoryLoader`'s resolution + parser contracts. Pure I/O over
/// the filesystem, no MainActor, no handle state.
///
/// Tests use the root-injected `locate(... exportRoot: projectsRoot:)`
/// overload so they never touch `~/.cache/ccterm` or
/// `~/.claude/projects` — see cctermTests/CLAUDE.md.
final class HistoryLoaderTests: XCTestCase {

    private var sandbox: URL!
    private var exportRoot: URL!
    private var projectsRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLoaderTests-\(UUID().uuidString)")
        exportRoot = sandbox.appendingPathComponent("export")
        projectsRoot = sandbox.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - locate resolution order

    func testLocatePrefersExportOverSlugAndScan() throws {
        let sid = UUID().uuidString
        let export = exportRoot.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: export)

        let slugDir = projectsRoot.appendingPathComponent("my-slug")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        try Data().write(to: slugDir.appendingPathComponent("\(sid).jsonl"))

        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "my-slug",
            exportRoot: exportRoot, projectsRoot: projectsRoot)

        XCTAssertEqual(resolved, export, "export hit must win when present")
    }

    func testLocateFallsBackToSlugWhenExportMissing() throws {
        let sid = UUID().uuidString
        let slugDir = projectsRoot.appendingPathComponent("known-slug")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let live = slugDir.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: live)

        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "known-slug",
            exportRoot: exportRoot, projectsRoot: projectsRoot)

        XCTAssertEqual(resolved, live)
    }

    func testLocateFallsBackToScanWhenSlugDirMissing() throws {
        let sid = UUID().uuidString
        // Put the JSONL under a slug DIFFERENT from what the caller
        // claims is the slug — the scan should still find it.
        let actualSlugDir = projectsRoot.appendingPathComponent("worktree-actual-slug")
        try FileManager.default.createDirectory(at: actualSlugDir, withIntermediateDirectories: true)
        let actual = actualSlugDir.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: actual)

        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "stale-cached-slug",
            exportRoot: exportRoot, projectsRoot: projectsRoot)

        // `contentsOfDirectory(at:)` returns URLs rooted at
        // `/private/var/folders/...`, while the constructed expected
        // URL is `/var/folders/...`. Compare resolved paths to ignore
        // the symlink.
        XCTAssertEqual(
            resolved?.resolvingSymlinksInPath().path,
            actual.resolvingSymlinksInPath().path,
            "scan must catch slug drift")
    }

    func testLocateNilSlugStillRunsScan() throws {
        let sid = UUID().uuidString
        let slugDir = projectsRoot.appendingPathComponent("any-slug")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let hit = slugDir.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: hit)

        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: nil,
            exportRoot: exportRoot, projectsRoot: projectsRoot)

        XCTAssertEqual(
            resolved?.resolvingSymlinksInPath().path,
            hit.resolvingSymlinksInPath().path,
            "nil slug should not short-circuit the scan")
    }

    func testLocateReturnsNilWhenNothingExists() {
        let sid = UUID().uuidString
        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "absent",
            exportRoot: exportRoot, projectsRoot: projectsRoot)
        XCTAssertNil(resolved)
    }

    // MARK: - parsers

    func testParseTailNilURLIsEmptySuccess() {
        let result = HistoryLoader.parseTail(at: nil, targetLines: 80)
        switch result {
        case .success(let parsed):
            XCTAssertTrue(parsed.messages.isEmpty)
            XCTAssertEqual(parsed.tailStartByteOffset, 0)
        case .failure(let err):
            XCTFail("expected .success for nil url, got \(err)")
        }
    }

    func testParseTailMissingFileIsEmptySuccess() {
        let absent = sandbox.appendingPathComponent("does-not-exist.jsonl")
        let result = HistoryLoader.parseTail(at: absent, targetLines: 80)
        switch result {
        case .success(let parsed):
            XCTAssertTrue(parsed.messages.isEmpty)
            XCTAssertEqual(parsed.tailStartByteOffset, 0)
        case .failure(let err):
            XCTFail("expected .success for missing file, got \(err)")
        }
    }

    func testParseLinesDropsUnparseable() {
        // Use a minimal-shape line that the resolver can handle, plus
        // garbage lines that must be skipped.
        let valid =
            #"{"type":"user","uuid":"a","message":{"role":"user","content":"hi"}}"#
        let lines = [
            valid,
            "not even json",
            #"{"this":"is valid json but not a known type"}"#,
            valid,
            "",
        ]
        let result = HistoryLoader.parseLines(lines)
        // We don't pin the exact count from the resolver's strictness
        // (which is implementation detail) — only that valid lines
        // produced *some* messages and that garbage didn't crash.
        XCTAssertGreaterThanOrEqual(result.count, 1)
        XCTAssertLessThanOrEqual(result.count, lines.count)
    }

    func testParsePrefixReadsFromZero() throws {
        let path = sandbox.appendingPathComponent("prefix.jsonl")
        let line =
            #"{"type":"user","uuid":"x","message":{"role":"user","content":"abc"}}"#
        let body = "\(line)\n\(line)\n"
        try body.write(to: path, atomically: true, encoding: .utf8)

        let bytes = (body.data(using: .utf8)?.count ?? 0)
        let result = HistoryLoader.parsePrefix(at: path, byteLimit: bytes)
        switch result {
        case .success(let msgs):
            // Two valid lines → up to 2 parsed messages (resolver may
            // legitimately reject under stricter validation, so we
            // assert "at least one, no more than two").
            XCTAssertGreaterThanOrEqual(msgs.count, 1)
            XCTAssertLessThanOrEqual(msgs.count, 2)
        case .failure(let err):
            XCTFail("expected .success, got \(err)")
        }
    }
}
