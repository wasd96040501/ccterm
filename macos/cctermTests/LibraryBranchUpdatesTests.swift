import AgentSDK
import XCTest

@testable import ccterm

/// `LibraryStore.branchUpdates(ofTranscriptAt:)`: a session's branch from the
/// directory its transcript says it ran in, live, and what the transcript
/// recorded once that directory is no repository.
@MainActor
final class LibraryBranchUpdatesTests: XCTestCase {
    typealias Rows = SessionDirectoryFixture

    private var repo: GitRepoFixture!
    private var fixture: SessionDirectoryFixture!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        continueAfterFailure = false
        repo = try GitRepoFixture()
        fixture = try SessionDirectoryFixture()
        library = LibraryStore(directory: fixture.directory)
    }

    override func tearDownWithError() throws {
        repo.remove()
        fixture.remove()
    }

    /// Run in a folder inside the repository, the session is on the
    /// repository's branch — and on whatever a checkout makes it.
    func testFollowsTheBranchOfTheFolderTheSessionRanIn() async throws {
        let transcript = try write(cwd: repo.url.appendingPathComponent("Sources").path, recorded: "old")
        let branches = BranchRecorder(library.branchUpdates(ofTranscriptAt: transcript))
        defer { branches.stop() }

        await branches.wait(for: "main")
        try repo.git("checkout", "-q", "-b", "feature")
        await branches.wait(for: "feature")
        XCTAssertFalse(branches.values.contains("old"), "the recorded branch showed over the live one")
    }

    func testASessionInAWorktreeIsOnTheWorktreesBranch() async throws {
        let worktree = repo.url.deletingLastPathComponent().appendingPathComponent("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree.path)
        let transcript = try write(cwd: worktree.path, recorded: "main")
        let branches = BranchRecorder(library.branchUpdates(ofTranscriptAt: transcript))
        defer { branches.stop() }

        await branches.wait(for: "wt-branch")
    }

    /// The folder is gone — a worktree removed — so the branch is the one the
    /// transcript last recorded, and there is nothing to follow.
    func testWithoutARepositoryItIsTheRecordedBranchOnce() async throws {
        let transcript = try write(cwd: "/nonexistent/wt", recorded: "gone-branch")
        let branches = BranchRecorder(library.branchUpdates(ofTranscriptAt: transcript))

        await branches.waitForEnd()
        XCTAssertEqual(branches.values, ["gone-branch"])
    }

    /// The CLI records a detached HEAD as "HEAD": no branch.
    func testARecordedDetachedHeadIsNoBranch() async throws {
        let transcript = try write(cwd: "/nonexistent/wt", recorded: "HEAD")
        let branches = BranchRecorder(library.branchUpdates(ofTranscriptAt: transcript))

        await branches.waitForEnd()
        XCTAssertEqual(branches.values, [nil])
    }

    func testATranscriptThatCantBeReadIsNoBranch() async throws {
        let branches = BranchRecorder(library.branchUpdates(ofTranscriptAt: fixture.url("-x/missing.jsonl")))

        await branches.waitForEnd()
        XCTAssertEqual(branches.values, [nil])
    }

    /// A transcript of a session run in `cwd`, on `recorded` as the CLI saw it.
    private func write(cwd: String, recorded: String) throws -> URL {
        let prompt = Rows.row([
            "type": "user", "uuid": "u", "parentUuid": NSNull(), "sessionId": "s", "cwd": cwd,
            "gitBranch": recorded, "message": ["role": "user", "content": "hi"],
        ])
        try fixture.write("-x/s.jsonl", [prompt])
        return fixture.url("-x/s.jsonl")
    }
}
