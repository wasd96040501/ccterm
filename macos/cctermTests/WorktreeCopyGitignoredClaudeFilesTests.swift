import XCTest

@testable import ccterm

/// Covers `Worktree.copyGitignoredClaudeFiles` — specifically the
/// `.claude/worktrees/**` exclusion that keeps us from recursively copying
/// every old ccterm-provisioned worktree into a brand-new one.
///
/// All tests build a self-contained temp git repo per case (own UUID dir,
/// torn down in `tearDown`) so we're parallel-safe and never touch the
/// developer's real `.claude/`.
final class WorktreeCopyGitignoredClaudeFilesTests: XCTestCase {

    private var rootDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-wt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rootDir = dir
    }

    override func tearDown() async throws {
        if let dir = rootDir {
            try? FileManager.default.removeItem(at: dir)
        }
        rootDir = nil
    }

    // MARK: - Core scenarios

    /// Bare scenario: a gitignored file at `.claude/settings.local.json`
    /// must be copied; nothing else exists. Establishes that the function
    /// works at all for the intended use case before we test the exclusion.
    func testCopiesPlainGitignoredClaudeFile() throws {
        let source = try makeSourceRepo(gitignore: ".claude/\n")
        let worktreeDest = try makeWorktreeDest()

        try writeFile(under: source, "/.claude/settings.local.json", contents: "{}")

        Worktree.copyGitignoredClaudeFiles(source: source.path, worktree: worktreeDest.path)

        XCTAssertTrue(
            fileExists(worktreeDest.appendingPathComponent(".claude/settings.local.json")),
            "settings.local.json must be copied into the worktree")
    }

    /// Core regression: when `<source>/.claude/worktrees/<old>/...` contains
    /// thousands of files (the typical post-N-worktrees situation), the
    /// copy must NOT recurse into them. Without the exclusion, this is
    /// quadratic + path-length-blowup; with it, only files OUTSIDE
    /// `.claude/worktrees/` are touched.
    func testSkipsClaudeWorktreesSubtree() throws {
        let source = try makeSourceRepo(gitignore: ".claude/\n")
        let worktreeDest = try makeWorktreeDest()

        // Things we DO want copied:
        try writeFile(under: source, "/.claude/settings.local.json", contents: "{}")
        try writeFile(under: source, "/.claude/memory/note.md", contents: "stuff")

        // Things we MUST NOT copy — three different shapes of "stuff inside
        // an existing ccterm-provisioned worktree":
        try writeFile(
            under: source, "/.claude/worktrees/eager-antonelli-0f4247/README.md",
            contents: "old-worktree readme")
        try writeFile(
            under: source,
            "/.claude/worktrees/eager-antonelli-0f4247/macos/ccterm/Sample.swift",
            contents: "old-worktree source")
        try writeFile(
            under: source,
            "/.claude/worktrees/jolly-pare-d40302/build/Debug/Some.o",
            contents: "old build product")

        Worktree.copyGitignoredClaudeFiles(source: source.path, worktree: worktreeDest.path)

        // What MUST be copied:
        XCTAssertTrue(
            fileExists(worktreeDest.appendingPathComponent(".claude/settings.local.json")),
            "settings.local.json copy missing")
        XCTAssertTrue(
            fileExists(worktreeDest.appendingPathComponent(".claude/memory/note.md")),
            ".claude/memory/note.md copy missing")

        // What MUST NOT be copied:
        XCTAssertFalse(
            fileExists(worktreeDest.appendingPathComponent(".claude/worktrees")),
            ".claude/worktrees must not appear in the new worktree at all")
        XCTAssertFalse(
            fileExists(
                worktreeDest.appendingPathComponent(
                    ".claude/worktrees/eager-antonelli-0f4247/README.md")),
            "nested file inside an old worktree must not be copied")
        XCTAssertFalse(
            fileExists(
                worktreeDest.appendingPathComponent(
                    ".claude/worktrees/eager-antonelli-0f4247/macos/ccterm/Sample.swift")),
            "deeply-nested file inside an old worktree must not be copied")
        XCTAssertFalse(
            fileExists(
                worktreeDest.appendingPathComponent(
                    ".claude/worktrees/jolly-pare-d40302/build/Debug/Some.o")),
            "old-worktree build product must not be copied")
    }

    /// Edge case: `.claude/worktrees` is the ONLY gitignored thing under
    /// `.claude`. After filtering, the function should be a no-op — no
    /// crash, no partial dir creation in the destination.
    func testWhenOnlyWorktreesAreIgnoredDoesNothing() throws {
        let source = try makeSourceRepo(gitignore: ".claude/worktrees/\n")
        let worktreeDest = try makeWorktreeDest()

        try writeFile(
            under: source, "/.claude/worktrees/adoring-benz-b7353f/some-file.txt",
            contents: "leftover")
        // Commit a tracked .claude file so the `.claude` dir exists in the
        // checkout (gating: `copyGitignoredClaudeFiles` early-returns if
        // `<source>/.claude` is missing).
        try writeFile(under: source, "/.claude/CLAUDE.md", contents: "tracked guide")
        try runGit(in: source, "add", ".claude/CLAUDE.md")
        try runGit(in: source, "commit", "-m", "tracked claude guide")

        Worktree.copyGitignoredClaudeFiles(source: source.path, worktree: worktreeDest.path)

        XCTAssertFalse(
            fileExists(worktreeDest.appendingPathComponent(".claude/worktrees")),
            "worktrees subtree must not be copied")
        // The function should not have created a stray `.claude` dir in
        // the destination just to host an empty filter result.
        XCTAssertFalse(
            fileExists(worktreeDest.appendingPathComponent(".claude")),
            "no .claude dir should appear in the destination when nothing to copy")
    }

    /// A gitignored file whose RELATIVE path happens to start with the
    /// literal string `.claude/worktrees` BUT isn't actually under the
    /// `.claude/worktrees/` directory must still be copied. Guards against
    /// a sloppy `hasPrefix(".claude/worktrees")` filter that would over-eat
    /// (e.g. `.claude/worktrees-readme.md`).
    func testDoesNotOverFilterSimilarlyNamedSibling() throws {
        let source = try makeSourceRepo(gitignore: ".claude/\n")
        let worktreeDest = try makeWorktreeDest()

        try writeFile(
            under: source, "/.claude/worktrees-readme.md",
            contents: "documentation about worktrees")

        Worktree.copyGitignoredClaudeFiles(source: source.path, worktree: worktreeDest.path)

        XCTAssertTrue(
            fileExists(worktreeDest.appendingPathComponent(".claude/worktrees-readme.md")),
            ".claude/worktrees-readme.md must still be copied — it's NOT under .claude/worktrees/")
    }

    // MARK: - Fixture helpers

    /// Build a freshly-`git init`-ed repo with the given .gitignore content
    /// (no commits unless the test makes one). Configures local user.email
    /// / user.name so any subsequent `git commit` works without inheriting
    /// the developer's global config.
    private func makeSourceRepo(gitignore: String) throws -> URL {
        let dir = try requireRoot().appendingPathComponent("source-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try runGit(in: dir, "init", "-q")
        try runGit(in: dir, "config", "user.email", "test@example.com")
        try runGit(in: dir, "config", "user.name", "test")

        let gi = dir.appendingPathComponent(".gitignore")
        try gitignore.write(to: gi, atomically: true, encoding: .utf8)
        return dir
    }

    /// An empty directory standing in for the freshly-created destination
    /// worktree. `Worktree.copyGitignoredClaudeFiles` only needs a writable
    /// dir at this path — it doesn't care that it isn't a real worktree.
    private func makeWorktreeDest() throws -> URL {
        let dir = try requireRoot().appendingPathComponent("dest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func requireRoot() throws -> URL {
        guard let root = rootDir else {
            throw XCTSkip("rootDir not set up")
        }
        return root
    }

    /// Write a UTF-8 string to `base/relative`, creating intermediate dirs.
    /// `relative` may start with `/` for readability — it's stripped.
    private func writeFile(under base: URL, _ relative: String, contents: String) throws {
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        let target = base.appendingPathComponent(trimmed)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    private func runGit(in dir: URL, _ args: String...) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let stderr =
                String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitHelper", code: Int(proc.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(args.joined(separator: " ")) failed: \(stderr)"
                ])
        }
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
