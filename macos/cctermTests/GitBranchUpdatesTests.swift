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
        let branches = Branches(following: repo.url.path)
        defer { branches.stop() }

        try await branches.wait(for: "main")
        try repo.git("checkout", "-q", "-b", "feature")
        try await branches.wait(for: "feature")
        try repo.git("checkout", "-q", "main")
        try await branches.wait(for: "main")
    }

    /// A worktree's HEAD is its own, found through the `gitdir` its `.git` names.
    func testFollowsAWorktreesOwnBranch() async throws {
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree.path)
        let branches = Branches(following: worktree.path)
        defer { branches.stop() }

        try await branches.wait(for: "wt-branch")
        try repo.git("-C", worktree.path, "checkout", "-q", "-b", "wt-next")
        try await branches.wait(for: "wt-next")
    }

    func testAFolderThatIsNoRepositoryYieldsNilAndEnds() async throws {
        let plain = repo.url.deletingLastPathComponent().appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        var values: [String?] = []
        for await branch in GitUtils.currentBranchUpdates(at: plain.path) { values.append(branch) }
        XCTAssertEqual(values, [nil])
    }
}

/// A stream followed on the main actor: what it has yielded, and a wait for
/// the value it yields next.
@MainActor
private final class Branches {
    private(set) var values: [String?] = []
    private var task: Task<Void, Never>?
    private var awaited: (branch: String, expectation: XCTestExpectation)?

    init(following path: String) {
        task = Task { [weak self] in
            for await branch in GitUtils.currentBranchUpdates(at: path) { self?.receive(branch) }
        }
    }

    func stop() { task?.cancel() }

    private func receive(_ branch: String?) {
        values.append(branch)
        if let awaited, awaited.branch == branch { awaited.expectation.fulfill() }
    }

    /// Returns once the latest value is `branch`.
    func wait(for branch: String, timeout: TimeInterval = 5) async throws {
        guard values.last != branch else { return }
        let expectation = XCTestExpectation(description: "branch becomes \(branch); saw \(values)")
        awaited = (branch, expectation)
        defer { awaited = nil }
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never became \(branch); saw \(values)")
    }
}
