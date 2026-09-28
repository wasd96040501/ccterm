import AgentSDK
import XCTest

@testable import ccterm

/// Pins `HistoryLoader`'s resolution + parser contracts. Pure I/O over
/// the filesystem, no MainActor, no handle state.
///
/// Tests use the root-injected `locate(... projectsRoot:)` overload so
/// they never touch `~/.claude/projects` — see cctermTests/CLAUDE.md.
final class HistoryLoaderTests: XCTestCase {

    private var sandbox: URL!
    private var projectsRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLoaderTests-\(UUID().uuidString)")
        projectsRoot = sandbox.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - locate resolution order

    func testLocatePrefersSlugOverScan() throws {
        let sid = UUID().uuidString
        let slugDir = projectsRoot.appendingPathComponent("my-slug")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let live = slugDir.appendingPathComponent("\(sid).jsonl")
        try Data().write(to: live)

        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "my-slug",
            projectsRoot: projectsRoot)

        XCTAssertEqual(resolved, live, "slug hit must win when present")
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
            projectsRoot: projectsRoot)

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
            projectsRoot: projectsRoot)

        XCTAssertEqual(
            resolved?.resolvingSymlinksInPath().path,
            hit.resolvingSymlinksInPath().path,
            "nil slug should not short-circuit the scan")
    }

    func testLocateReturnsNilWhenNothingExists() {
        let sid = UUID().uuidString
        let resolved = HistoryLoader.locate(
            sessionId: sid, slug: "absent",
            projectsRoot: projectsRoot)
        XCTAssertNil(resolved)
    }

}
