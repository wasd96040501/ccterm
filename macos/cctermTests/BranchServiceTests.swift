import XCTest

@testable import ccterm

/// `BranchService` over real repositories in temp directories: what a folder's
/// repository has, and the git step of each `Checkout`.
final class BranchServiceTests: XCTestCase {
    private var repo: GitRepoFixture!
    private let service = BranchService()

    override func setUpWithError() throws {
        repo = try GitRepoFixture()
    }

    override func tearDown() {
        repo.remove()
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func repository(at folder: URL) async throws -> RepositoryState {
        let state = await service.repository(at: folder)
        return try XCTUnwrap(state, "no repository at \(folder.path)")
    }

    // MARK: - repository(at:)

    func testAFolderInNoRepositoryHasNone() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let state = await service.repository(at: plain)
        XCTAssertNil(state)
    }

    func testARepositoryReportsItsBranchAndBranches() async throws {
        try repo.git("branch", "feature")
        try repo.git("branch", "fix-gutter")
        let state = try await repository(at: repo.url)
        XCTAssertEqual(resolved(state.root), resolved(repo.url))
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(Set(state.localBranches), ["main", "feature", "fix-gutter"])
        XCTAssertTrue(state.remoteBranches.isEmpty)
        XCTAssertFalse(state.hasUncommittedChanges)
        XCTAssertTrue(state.branchesCheckedOutElsewhere.isEmpty)
        XCTAssertNil(state.defaultBranch)
    }

    func testASubfolderFindsItsRepository() async throws {
        let sub = repo.url.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let state = try await repository(at: sub)
        XCTAssertEqual(resolved(state.root), resolved(repo.url))
    }

    func testADetachedHeadHasNoBranch() async throws {
        try repo.git("checkout", "-q", "--detach")
        let state = try await repository(at: repo.url)
        XCTAssertNil(state.branch)
    }

    func testTrackedChangesAreUncommittedWorkAndUntrackedFilesAreNot() async throws {
        try "new".write(to: repo.url.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        var state = try await repository(at: repo.url)
        XCTAssertFalse(state.hasUncommittedChanges)
        try "changed".write(to: repo.url.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        state = try await repository(at: repo.url)
        XCTAssertTrue(state.hasUncommittedChanges)
    }

    func testABranchInAnotherWorktreeIsCheckedOutElsewhere() async throws {
        try repo.git("branch", "feature")
        let other = repo.url.deletingLastPathComponent().appendingPathComponent("other")
        try repo.git("worktree", "add", "-q", other.path, "feature")
        let state = try await repository(at: repo.url)
        XCTAssertEqual(state.branchesCheckedOutElsewhere, ["feature"])
        let fromOther = try await repository(at: other)
        XCTAssertEqual(fromOther.branch, "feature")
        XCTAssertEqual(fromOther.branchesCheckedOutElsewhere, ["main"])
    }

    func testRemoteBranchesWithoutALocalTwinAndTheDefaultBranch() async throws {
        let bare = repo.url.deletingLastPathComponent().appendingPathComponent("origin.git")
        try repo.git("clone", "-q", "--bare", repo.url.path, bare.path)
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "-q", "origin", "main")
        try repo.git("push", "-q", "origin", "main:release/1.4")
        try repo.git("fetch", "-q", "origin")
        try repo.git("remote", "set-head", "origin", "main")
        let state = try await repository(at: repo.url)
        XCTAssertEqual(state.remoteBranches, ["origin/release/1.4"], "origin/main has its local twin")
        XCTAssertEqual(state.defaultBranch, "main")
    }

    // MARK: - prepare

    func testInPlaceOnTheCheckedOutBranchChangesNothing() async throws {
        let prepared = try await service.prepare(.inPlace(switchTo: nil), in: repo.url, name: "x")
        XCTAssertEqual(
            prepared,
            PreparedWorkspace(
                workingDirectory: repo.url, worktreeName: nil, worktreeBaseRef: nil, sessionDirectory: repo.url))
    }

    func testInPlaceSwitchesBeforeTheCLIStarts() async throws {
        try repo.git("branch", "feature")
        _ = try await service.prepare(.inPlace(switchTo: "feature"), in: repo.url, name: "x")
        let state = try await repository(at: repo.url)
        XCTAssertEqual(state.branch, "feature")
    }

    func testASwitchGitRefusesThrowsGitsWords() async throws {
        do {
            _ = try await service.prepare(.inPlace(switchTo: "nonexistent"), in: repo.url, name: "x")
            XCTFail("expected a refusal")
        } catch let refusal as GitRefusal {
            XCTAssertFalse(refusal.message.isEmpty)
        }
    }

    func testAWorktreeFromTheCheckedOutBranchIsTheCLIsOwnWithBaseRefHead() async throws {
        let prepared = try await service.prepare(.worktree(base: .head), in: repo.url, name: "quiet-otter")
        XCTAssertEqual(prepared.worktreeName, "quiet-otter")
        XCTAssertEqual(prepared.worktreeBaseRef, "head")
        XCTAssertEqual(prepared.workingDirectory, repo.url)
        XCTAssertTrue(prepared.sessionDirectory.path.hasSuffix("/.claude/worktrees/quiet-otter"))
    }

    func testAWorktreeFromOriginsDefaultNeedsNoBaseRef() async throws {
        let prepared = try await service.prepare(.worktree(base: .defaultBranch), in: repo.url, name: "quiet-otter")
        XCTAssertEqual(prepared.worktreeName, "quiet-otter")
        XCTAssertNil(prepared.worktreeBaseRef)
    }

    func testAWorktreeFromAnotherBranchIsMadeHereAndTheCLIRunsInIt() async throws {
        try repo.git("branch", "feature")
        let prepared = try await service.prepare(.worktree(base: .branch("feature")), in: repo.url, name: "quiet-otter")
        XCTAssertNil(prepared.worktreeName, "the CLI is not asked to make it")
        XCTAssertEqual(prepared.workingDirectory, prepared.sessionDirectory)
        XCTAssertTrue(prepared.workingDirectory.path.hasSuffix("/.claude/worktrees/quiet-otter"))
        let worktree = try await repository(at: prepared.workingDirectory)
        XCTAssertEqual(worktree.branch, "worktree-quiet-otter")
    }

    func testAPullRequestIsTheCLIsOwnNamedPrN() async throws {
        let prepared = try await service.prepare(.pullRequest(327), in: repo.url, name: "ignored")
        XCTAssertEqual(prepared.worktreeName, "#327")
        XCTAssertTrue(prepared.sessionDirectory.path.hasSuffix("/.claude/worktrees/pr-327"))
    }

    func testAWorktreeOutsideARepositoryIsRefused() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        do {
            _ = try await service.prepare(.worktree(base: .head), in: plain, name: "x")
            XCTFail("expected a refusal")
        } catch let refusal as GitRefusal {
            XCTAssertEqual(refusal.message, String(localized: "Not a Git repository"))
        }
    }

    // MARK: - Names

    func testAWorktreeNameIsAdjectiveAnimalLikeTheCLIs() {
        for _ in 0..<20 {
            let name = BranchService.makeWorktreeName()
            XCTAssertNotNil(name.range(of: #"^[a-z]+-[a-z]+$"#, options: .regularExpression), name)
        }
    }
}
