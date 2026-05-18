import XCTest

@testable import ccterm

/// `HistoryLoader.scanForSession(_:under:)` is the slug-mismatch safety
/// net for `historyJSONLURL`. The slug-based lookup remains the fast
/// path; this scanner kicks in when the persisted cwd's sanitized slug
/// doesn't match what the CLI actually wrote (canonicalize / realpath
/// drift, future CLI slug-algorithm changes, etc).
///
/// Layout under `~/.claude/projects/` is exactly one level deep:
///   `~/.claude/projects/<slug>/<sessionId>.jsonl`.
/// The scanner exploits that — a single `contentsOfDirectory` over the
/// top level, then one `fileExists` probe per subdir. No recursion, no
/// JSONL bytes read.
final class HistoryJSONLScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Happy path: a session's JSONL lives in some arbitrary slug
    /// directory (here the slug deliberately doesn't match what
    /// `sanitizePath` would have produced for the cwd — that's the
    /// whole point). The scanner finds it anyway.
    func testFindsJSONLInAnySlugSubdir() throws {
        let sid = UUID().uuidString.lowercased()
        // Slug here is deliberately "wrong" — doesn't match any cwd's
        // sanitizePath output. The scanner doesn't care.
        let slugDir = root.appendingPathComponent("some-arbitrary-slug-name")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let jsonl = slugDir.appendingPathComponent("\(sid).jsonl")
        try "".write(to: jsonl, atomically: true, encoding: .utf8)

        let hit = HistoryLoader.scanForSession(sid, under: root)
        XCTAssertEqual(hit?.standardizedFileURL, jsonl.standardizedFileURL)
    }

    /// Worktree-style slug regression: even with the **correct**
    /// double-dash slug for `.claude/worktrees/`, the scanner still
    /// hits. Pins down "we tolerate slugs we don't know how to
    /// reproduce" — the scanner is content-driven, not slug-shape-
    /// driven.
    func testFindsJSONLInWorktreeShapedSlug() throws {
        let sid = UUID().uuidString.lowercased()
        let slugDir = root.appendingPathComponent(
            "-Users-x-code-repo--claude-worktrees-musing-gould-f88134")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let jsonl = slugDir.appendingPathComponent("\(sid).jsonl")
        try "".write(to: jsonl, atomically: true, encoding: .utf8)

        let hit = HistoryLoader.scanForSession(sid, under: root)
        XCTAssertEqual(hit?.standardizedFileURL, jsonl.standardizedFileURL)
    }

    /// No matching file under any subdir → nil.
    func testReturnsNilWhenSessionAbsent() throws {
        let unrelated = root.appendingPathComponent("some-slug")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "".write(
            to: unrelated.appendingPathComponent("\(UUID().uuidString).jsonl"),
            atomically: true,
            encoding: .utf8)

        XCTAssertNil(
            HistoryLoader.scanForSession(UUID().uuidString.lowercased(), under: root))
    }

    /// Skips entries that aren't directories (any stray file at the
    /// projects root). The scanner is a directory iterator, not a
    /// generic find — files at the top level are ignored.
    func testSkipsNonDirectoryEntries() throws {
        let sid = UUID().uuidString.lowercased()
        try "stray".write(
            to: root.appendingPathComponent("not-a-directory.jsonl"),
            atomically: true,
            encoding: .utf8)
        let slugDir = root.appendingPathComponent("real-slug")
        try FileManager.default.createDirectory(at: slugDir, withIntermediateDirectories: true)
        let jsonl = slugDir.appendingPathComponent("\(sid).jsonl")
        try "".write(to: jsonl, atomically: true, encoding: .utf8)

        let hit = HistoryLoader.scanForSession(sid, under: root)
        XCTAssertEqual(hit?.standardizedFileURL, jsonl.standardizedFileURL)
    }

    /// Multiple slug dirs, only one has the session — find the right
    /// one without false-positives from siblings holding other
    /// sessions.
    func testFindsAcrossManySiblingSlugs() throws {
        let target = UUID().uuidString.lowercased()
        for i in 0..<5 {
            let dir = root.appendingPathComponent("slug-\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Each sibling has a UNRELATED session, so a naive "first
            // jsonl wins" impl would fail this test.
            try "".write(
                to: dir.appendingPathComponent("\(UUID().uuidString).jsonl"),
                atomically: true,
                encoding: .utf8)
        }
        let hitDir = root.appendingPathComponent("slug-2")
        let jsonl = hitDir.appendingPathComponent("\(target).jsonl")
        try "".write(to: jsonl, atomically: true, encoding: .utf8)

        let hit = HistoryLoader.scanForSession(target, under: root)
        XCTAssertEqual(hit?.standardizedFileURL, jsonl.standardizedFileURL)
    }

    /// Non-existent root → nil, no crash. The CLI directory may not
    /// exist on a fresh install.
    func testReturnsNilWhenRootMissing() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertNil(HistoryLoader.scanForSession(UUID().uuidString, under: missing))
    }
}
