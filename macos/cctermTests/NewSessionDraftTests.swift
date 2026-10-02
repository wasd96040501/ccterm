import AgentSDK
import XCTest

@testable import ccterm

/// What one choice in the New view does to the others, and the launch Send
/// makes of them (design 08 *The New view*).
final class NewSessionDraftTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/me/dev/ccterm")
    private let other = URL(fileURLWithPath: "/Users/me/dev/ghostty")

    private let settings = SessionSettings(
        model: .default(on: UUID()), effort: nil, permissionMode: .default, fastMode: false)

    /// The design's first folder: on `main`, a branch another worktree has,
    /// a remote branch, a remote default.
    private func repository(dirty: Bool = false) -> RepositoryState {
        RepositoryState(
            root: folder, branch: "main",
            localBranches: ["main", "live-session-design", "fix-gutter-overflow"],
            remoteBranches: ["origin/release/1.4", "origin/sidebar-icons"],
            branchesCheckedOutElsewhere: ["live-session-design"],
            hasUncommittedChanges: dirty, defaultBranch: "main")
    }

    private func draft() -> NewSessionDraft {
        NewSessionDraft(folder: folder, settings: settings)
    }

    // MARK: Folder

    func testAnotherFolderResetsTheBranchAndWorktree() {
        var draft = draft()
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository())
        draft.toggleWorktree(in: repository())
        XCTAssertTrue(draft.usesWorktree)

        draft.choose(folder: other)

        XCTAssertEqual(draft.folder, other)
        XCTAssertNil(draft.branch)
        XCTAssertFalse(draft.usesWorktree)
    }

    func testTheSameFolderAgainKeepsTheChoices() {
        var draft = draft()
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository())
        draft.choose(folder: folder)
        XCTAssertEqual(draft.branch, .named("fix-gutter-overflow"))
    }

    // MARK: Branch

    func testTheCheckedOutBranchIsTheDrafts_nil() {
        var draft = draft()
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository())
        draft.choose(branch: .named("main"), in: repository())
        XCTAssertNil(draft.branch)
    }

    func testAPullRequestTurnsWorktreeOn() {
        var draft = draft()
        draft.choose(branch: .pullRequest(327), in: repository())
        XCTAssertEqual(draft.branch, .pullRequest(327))
        XCTAssertTrue(draft.usesWorktree)
    }

    func testInPlaceABranchGitWouldRefuseIsIgnored() {
        var draft = draft()
        draft.choose(branch: .named("live-session-design"), in: repository())
        XCTAssertNil(draft.branch, "checked out in another worktree")

        var dirty = self.draft()
        dirty.choose(branch: .named("fix-gutter-overflow"), in: repository(dirty: true))
        XCTAssertNil(dirty.branch, "uncommitted work would be carried along")
    }

    func testWithAWorktreeEveryBranchCanBeChosen() {
        var draft = draft()
        draft.toggleWorktree(in: repository(dirty: true))
        draft.choose(branch: .named("live-session-design"), in: repository(dirty: true))
        XCTAssertEqual(draft.branch, .named("live-session-design"))
    }

    // MARK: Worktree

    func testWorktreeOffReturnsABranchThatCannotBeHadInPlace() {
        var draft = draft()
        draft.toggleWorktree(in: repository())
        draft.choose(branch: .named("live-session-design"), in: repository())
        draft.toggleWorktree(in: repository())

        XCTAssertFalse(draft.usesWorktree)
        XCTAssertNil(draft.branch)
    }

    func testWorktreeOffReturnsAPullRequest() {
        var draft = draft()
        draft.choose(branch: .pullRequest(327), in: repository())
        draft.toggleWorktree(in: repository())

        XCTAssertFalse(draft.usesWorktree)
        XCTAssertNil(draft.branch)
    }

    func testWorktreeOffKeepsABranchThatCanBeHadInPlace() {
        var draft = draft()
        draft.toggleWorktree(in: repository())
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository())
        draft.toggleWorktree(in: repository())

        XCTAssertEqual(draft.branch, .named("fix-gutter-overflow"))
    }

    func testWorktreeOffWithUncommittedWorkReturnsAnotherBranch() {
        var draft = draft()
        draft.toggleWorktree(in: repository(dirty: true))
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository(dirty: true))
        draft.toggleWorktree(in: repository(dirty: true))

        XCTAssertNil(draft.branch)
    }

    // MARK: Launch

    func testWithoutAFolderThereIsNoLaunch() {
        XCTAssertNil(NewSessionDraft(folder: nil, settings: settings).launch(in: nil))
    }

    func testANonRepositoryFolderLaunchesInPlace() {
        XCTAssertEqual(draft().launch(in: nil)?.checkout, .inPlace(switchTo: nil))
    }

    func testInPlaceOnTheCheckedOutBranch() {
        let launch = draft().launch(in: repository())
        XCTAssertEqual(launch?.folder, folder)
        XCTAssertEqual(launch?.checkout, .inPlace(switchTo: nil))
        XCTAssertEqual(launch?.settings, settings)
    }

    func testInPlaceOnAnotherBranchSwitches() {
        var draft = draft()
        draft.choose(branch: .named("fix-gutter-overflow"), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .inPlace(switchTo: "fix-gutter-overflow"))
    }

    func testInPlaceOnARemoteBranchSwitchesToItsLocalName() {
        var draft = draft()
        draft.choose(branch: .named("origin/release/1.4"), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .inPlace(switchTo: "release/1.4"))
    }

    func testAWorktreeFromTheCheckedOutBranchIsHead() {
        var draft = draft()
        draft.toggleWorktree(in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .worktree(base: .head))
    }

    func testAWorktreeFromTheCheckedOutBranchChosenExplicitlyIsHead() {
        var draft = draft()
        draft.toggleWorktree(in: repository())
        draft.choose(branch: .named("main"), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .worktree(base: .head))
    }

    func testAWorktreeFromOriginsDefaultIsTheDefaultBranch() {
        var state = repository()
        state.branch = "fix-gutter-overflow"
        var draft = draft()
        draft.toggleWorktree(in: state)
        draft.choose(branch: .named("main"), in: state)
        XCTAssertEqual(draft.launch(in: state)?.checkout, .worktree(base: .defaultBranch))
    }

    func testAWorktreeFromAnotherBranchNamesIt() {
        var draft = draft()
        draft.toggleWorktree(in: repository())
        draft.choose(branch: .named("live-session-design"), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .worktree(base: .branch("live-session-design")))

        draft.choose(branch: .named("origin/release/1.4"), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .worktree(base: .branch("origin/release/1.4")))
    }

    func testAPullRequestLaunchesItsOwnCheckout() {
        var draft = draft()
        draft.choose(branch: .pullRequest(327), in: repository())
        XCTAssertEqual(draft.launch(in: repository())?.checkout, .pullRequest(327))
    }

    func testAPullRequestWithoutARepositoryLaunchesInPlace() {
        var draft = draft()
        draft.choose(branch: .pullRequest(327), in: repository())
        XCTAssertEqual(draft.launch(in: nil)?.checkout, .inPlace(switchTo: nil))
    }

    func testTheSettingsGoWithTheLaunch() {
        var draft = draft()
        draft.settings.fastMode = true
        XCTAssertEqual(draft.launch(in: repository())?.settings.fastMode, true)
    }
}
