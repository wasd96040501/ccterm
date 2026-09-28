import XCTest

@testable import ccterm

/// `GitService.branchUpdates(at:)` against real repositories: the branch of
/// the repository holding a folder, now and after each checkout at the
/// command line, and no stream at all for a folder in none.
@MainActor
final class GitServiceTests: XCTestCase {
    private let git = GitService()
    private var repo: GitRepoFixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        repo = try GitRepoFixture()
    }

    override func tearDownWithError() throws {
        repo.remove()
    }

    func testYieldsTheBranchAndThenEachCheckout() async throws {
        let branches = BranchRecorder(try await updates(at: repo.url.path))
        defer { branches.stop() }

        await branches.wait(for: "main")
        try repo.git("checkout", "-q", "-b", "feature")
        await branches.wait(for: "feature")
        try repo.git("checkout", "-q", "main")
        await branches.wait(for: "main")
    }

    /// A folder deep inside the repository is on the repository's branch.
    func testAFolderInsideTheRepositoryIsOnItsBranch() async throws {
        let deep = repo.url.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let branches = BranchRecorder(try await updates(at: deep.path))
        defer { branches.stop() }

        await branches.wait(for: "main")
    }

    /// A worktree's HEAD is its own, found through the `gitdir` its `.git` names.
    func testFollowsAWorktreesOwnBranch() async throws {
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree.path)
        let branches = BranchRecorder(try await updates(at: worktree.path))
        defer { branches.stop() }

        await branches.wait(for: "wt-branch")
        try repo.git("-C", worktree.path, "checkout", "-q", "-b", "wt-next")
        await branches.wait(for: "wt-next")
    }

    func testAFolderInNoRepositoryHasNothingToFollow() async throws {
        let plain = repo.url.deletingLastPathComponent().appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let none = await git.branchUpdates(at: plain.path)
        XCTAssertNil(none)
        let gone = await git.branchUpdates(at: "/nonexistent/wt")
        XCTAssertNil(gone)
    }

    private func updates(at path: String) async throws -> AsyncStream<String?> {
        let stream = await git.branchUpdates(at: path)
        return try XCTUnwrap(stream, "\(path) is in no repository")
    }
}
