import XCTest

@testable import ccterm

/// End-to-end check that the production `SessionManager2.archive` /
/// `unarchive` defaults (which call into real `Worktree.remove` /
/// `Worktree.restore` via git) actually tear down and rebuild the
/// worktree directory on disk.
///
/// Each test stands up a self-contained temp git repo + a real ccterm
/// worktree under `.claude/worktrees/`, then exercises the side-effect
/// helpers `SessionManager2` wires by default. We invoke the helpers
/// **synchronously** (rather than going through the full
/// `manager.archive(sid)` codepath which dispatches to a background
/// queue) so the test can assert on disk state immediately — same git
/// commands are issued, just on the test thread.
final class SessionManager2ArchiveWorktreeTests: XCTestCase {

    private var rootDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-archive-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rootDir = dir
    }

    override func tearDown() async throws {
        if let dir = rootDir {
            try? FileManager.default.removeItem(at: dir)
        }
        rootDir = nil
    }

    // MARK: - Core round trip

    /// Archive a worktree-backed session → the worktree dir is removed
    /// from disk; unarchive → `git worktree add` recreates it on the
    /// same branch. The record's persisted `worktreeBranch` is what
    /// restore keys off, so this also confirms the field flows through.
    func testArchiveRemovesWorktreeAndUnarchiveRestores() throws {
        let (baseRepo, worktree) = try provisionWorktree()
        let record = makeWorktreeRecord(at: worktree)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.path),
            "Provision must leave the worktree dir on disk before archive")

        SessionManager2.invokeWorktreeArchiveSync(for: record)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: worktree.path),
            "Archive must remove the worktree dir")

        SessionManager2.invokeWorktreeRestoreSync(for: record)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.path),
            "Unarchive must rebuild the worktree dir")

        // Verify the rebuilt dir is actually a git worktree pointing at
        // the same branch — not just an empty dir.
        let head = try runGit(in: worktree, "rev-parse", "--abbrev-ref", "HEAD")
        XCTAssertEqual(head, worktree.lastPathComponent, "Restored worktree must check out the saved branch")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: baseRepo.appendingPathComponent("hello.txt").path) == false
                || FileManager.default.fileExists(atPath: worktree.appendingPathComponent("hello.txt").path),
            "Restored worktree shares files with the base repo via the branch checkout")
    }

    /// Side effect closures are no-ops when the record is missing the
    /// fields they need (cwd / originPath / worktreeBranch) — we don't
    /// crash, we don't fabricate paths, we just log and return.
    func testWorktreeSideEffectsAreNoOpOnMissingFields() {
        let partial = SessionRecord(
            sessionId: UUID().uuidString,
            title: "Partial",
            cwd: nil,  // missing
            isWorktree: true,
            originPath: nil,  // missing
            worktreeBranch: nil  // missing
        )

        // Must not throw, must not crash.
        SessionManager2.invokeWorktreeArchiveSync(for: partial)
        SessionManager2.invokeWorktreeRestoreSync(for: partial)
    }

    // MARK: - Provisioning

    /// Build a git repo at `<root>/repo` with one tracked commit, then
    /// `git worktree add` a ccterm-style worktree under
    /// `<root>/repo/.claude/worktrees/<name>`. Returns the base repo and
    /// the worktree path.
    private func provisionWorktree() throws -> (baseRepo: URL, worktree: URL) {
        let root = try requireRoot()
        let baseRepo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: baseRepo, withIntermediateDirectories: true)

        try runGit(in: baseRepo, "init", "-q", "--initial-branch=main")
        try runGit(in: baseRepo, "config", "user.email", "test@example.com")
        try runGit(in: baseRepo, "config", "user.name", "test")
        try "hi\n".write(
            to: baseRepo.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8)
        try runGit(in: baseRepo, "add", "hello.txt")
        try runGit(in: baseRepo, "commit", "-q", "-m", "initial")

        // ccterm-style worktree path. We choose the name + path
        // ourselves so the test fixture is deterministic; the
        // production `Worktree.create` would pick a random
        // `<adj>-<sci>-<hex6>` name, but our archive / restore helpers
        // operate against whatever name is in the record.
        let name = "eager-curie-abc123"
        let worktreesParent = baseRepo.appendingPathComponent(".claude/worktrees")
        try FileManager.default.createDirectory(at: worktreesParent, withIntermediateDirectories: true)
        let worktreePath = worktreesParent.appendingPathComponent(name)

        try runGit(
            in: baseRepo,
            "worktree", "add", "-b", name, worktreePath.path)

        return (baseRepo, worktreePath)
    }

    private func makeWorktreeRecord(at worktree: URL) -> SessionRecord {
        let name = worktree.lastPathComponent
        let baseRepo = worktree.deletingLastPathComponent()  // .claude/worktrees
            .deletingLastPathComponent()  // .claude
            .deletingLastPathComponent()  // repo
        return SessionRecord(
            sessionId: UUID().uuidString,
            title: "Worktree session",
            cwd: worktree.path,
            isWorktree: true,
            originPath: baseRepo.path,
            worktreeBranch: name
        )
    }

    private func requireRoot() throws -> URL {
        guard let root = rootDir else {
            throw XCTSkip("rootDir not set up")
        }
        return root
    }

    @discardableResult
    private func runGit(in dir: URL, _ args: String...) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "GitHelper",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(out)"])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
