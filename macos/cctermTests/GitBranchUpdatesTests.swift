import XCTest

@testable import ccterm

/// `GitUtils.currentBranchUpdates(at:)` against real repositories: the branch
/// now, then whatever a checkout at the command line makes it.
@MainActor
final class GitBranchUpdatesTests: XCTestCase {
    private var repo: GitRepoFixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        repo = try GitRepoFixture()
    }

    override func tearDownWithError() throws {
        repo.remove()
    }

    func testYieldsTheBranchAndThenEachCheckout() async throws {
        let branches = BranchRecorder(GitUtils.currentBranchUpdates(at: repo.url.path))
        defer { branches.stop() }

        await branches.wait(for: "main")
        try repo.git("checkout", "-q", "-b", "feature")
        await branches.wait(for: "feature")
        try repo.git("checkout", "-q", "main")
        await branches.wait(for: "main")
    }

    /// A worktree's HEAD is its own, found through the `gitdir` its `.git` names.
    func testFollowsAWorktreesOwnBranch() async throws {
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree.path)
        let branches = BranchRecorder(GitUtils.currentBranchUpdates(at: worktree.path))
        defer { branches.stop() }

        await branches.wait(for: "wt-branch")
        try repo.git("-C", worktree.path, "checkout", "-q", "-b", "wt-next")
        await branches.wait(for: "wt-next")
    }

    func testAFolderThatIsNoRepositoryYieldsNilAndEnds() async throws {
        let plain = repo.url.deletingLastPathComponent().appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        var values: [String?] = []
        for await branch in GitUtils.currentBranchUpdates(at: plain.path) { values.append(branch) }
        XCTAssertEqual(values, [nil])
    }

    /// A repository starts where its `.git` is, however deep the folder asked
    /// about; a worktree's checkout is one of its own.
    func testTheRepositoryRootIsTheNearestFolderWithGit() throws {
        let deep = repo.url.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree.path)

        XCTAssertEqual(GitUtils.repositoryRoot(containing: deep.path), repo.url.standardizedFileURL.path)
        XCTAssertEqual(GitUtils.repositoryRoot(containing: worktree.path), worktree.standardizedFileURL.path)
        XCTAssertNil(GitUtils.repositoryRoot(containing: repo.url.deletingLastPathComponent().path))
    }
}
