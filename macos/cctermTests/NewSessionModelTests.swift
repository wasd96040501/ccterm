import AgentSDK
import XCTest

@testable import ccterm

/// The words of the New view (design 08 *The New view*) and the branch
/// popover's filter, without AppKit.
final class NewSessionModelTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/me/dev/ccterm")

    private var settings: SessionSettings {
        SessionSettings(model: .default(on: UUID()), effort: nil, permissionMode: .default, fastMode: false)
    }

    private func repository(dirty: Bool = false, branch: String? = "main") -> RepositoryState {
        RepositoryState(
            root: folder, branch: branch,
            localBranches: ["main", "live-session-design", "fix-gutter-overflow"],
            remoteBranches: ["origin/release/1.4", "origin/sidebar-icons", "origin/fix-gutter-overflow"],
            branchesCheckedOutElsewhere: ["live-session-design"],
            hasUncommittedChanges: dirty, defaultBranch: "main")
    }

    private func draft(_ edit: (inout NewSessionDraft) -> Void = { _ in }) -> NewSessionDraft {
        var draft = NewSessionDraft(folder: folder, settings: settings)
        edit(&draft)
        return draft
    }

    private func model(_ draft: NewSessionDraft, dirty: Bool = false, branch: String? = "main") -> NewSessionModel {
        NewSessionModel(
            draft: draft, repository: .repository(repository(dirty: dirty, branch: branch)), recentFolders: [])
    }

    private func list(of model: NewSessionModel) throws -> NewSessionModel.BranchList {
        guard case .repository(_, _, let list) = model.branchRow else {
            XCTFail("not a repository row: \(model.branchRow)")
            throw CancellationError()
        }
        return list
    }

    // MARK: Folder

    func testTheFolderIsTheTitleAndItsPathIsUnderIt() {
        let model = model(draft())
        XCTAssertEqual(model.folderTitle, "ccterm")
        XCTAssertEqual(model.folderPath, (folder.path as NSString).abbreviatingWithTildeInPath)
        XCTAssertTrue(model.canSend)
    }

    func testWithoutAFolderTheTitleAsksForOneAndSendIsOff() {
        let model = NewSessionModel(
            draft: NewSessionDraft(folder: nil, settings: settings), repository: .loading, recentFolders: [])
        XCTAssertEqual(model.folderTitle, String(localized: "Choose Folder…"))
        XCTAssertNil(model.folderPath)
        XCTAssertFalse(model.canSend)
    }

    func testRecentFoldersAreEightAtMostAndTheDraftsIsChecked() {
        let recents = (0..<12).map { URL(fileURLWithPath: "/Users/me/dev/p\($0)") }
        let draft = NewSessionDraft(folder: recents[2], settings: settings)
        let model = NewSessionModel(draft: draft, repository: .loading, recentFolders: recents)

        XCTAssertEqual(model.recentFolders.map(\.title), (0..<8).map { "p\($0)" })
        XCTAssertEqual(model.recentFolders.filter(\.isChosen).map(\.title), ["p2"])
    }

    // MARK: Branch row

    func testAFolderThatIsNotARepositoryHasNoRow() {
        let model = NewSessionModel(draft: draft(), repository: .notARepository, recentFolders: [])
        XCTAssertEqual(model.branchRow, .notARepository(String(localized: "Not a git repository")))
        XCTAssertNil(model.explanation)
    }

    func testWhileTheRepositoryIsReadTheRowWaitsAndSaysNothing() {
        let model = NewSessionModel(draft: draft(), repository: .loading, recentFolders: [])
        XCTAssertEqual(model.branchRow, .loading)
        XCTAssertNil(model.explanation)
    }

    func testTheRowShowsTheCheckedOutBranchAndSaysNothingInPlace() throws {
        let model = model(draft())
        guard case .repository(let title, let usesWorktree, _) = model.branchRow else {
            return XCTFail("\(model.branchRow)")
        }
        XCTAssertEqual(title, "main")
        XCTAssertFalse(usesWorktree)
        XCTAssertNil(model.explanation)
    }

    func testADetachedHeadIsNamed() {
        let model = model(draft(), branch: nil)
        guard case .repository(let title, _, _) = model.branchRow else { return XCTFail("\(model.branchRow)") }
        XCTAssertEqual(title, String(localized: "Detached HEAD"))
    }

    // MARK: The line under the row

    func testAnotherBranchInPlaceSaysItSwitches() {
        let model = model(draft { $0.choose(branch: .named("fix-gutter-overflow"), in: repository()) })
        let name = "fix-gutter-overflow"
        XCTAssertEqual(model.explanation, String(localized: "Switches to \(name) when you send"))
    }

    func testAWorktreeSaysWhereTheNewBranchStarts() {
        let model = model(draft { $0.toggleWorktree(in: repository()) })
        let main = "main"
        XCTAssertEqual(model.explanation, String(localized: "A new branch from \(main), in a new worktree"))

        let other = self.model(
            draft {
                $0.toggleWorktree(in: repository())
                $0.choose(branch: .named("fix-gutter-overflow"), in: repository())
            })
        let name = "fix-gutter-overflow"
        XCTAssertEqual(other.explanation, String(localized: "A new branch from \(name), in a new worktree"))
    }

    func testAPullRequestSaysSo() {
        let model = model(draft { $0.choose(branch: .pullRequest(327), in: repository()) })
        let number = 327
        XCTAssertEqual(model.explanation, String(localized: "Pull request #\(number), in a new worktree"))
        guard case .repository(let title, let usesWorktree, _) = model.branchRow else {
            return XCTFail("\(model.branchRow)")
        }
        XCTAssertEqual(title, "#327")
        XCTAssertTrue(usesWorktree)
    }

    // MARK: The branch list

    func testInPlaceTheCheckedOutBranchIsMarkedAndTheOthersSaySoWhenGitWouldRefuse() throws {
        let list = try list(of: model(draft()))

        let main = try XCTUnwrap(list.local.first { $0.name == "main" })
        XCTAssertEqual(main.subtitle, String(localized: "Checked out here"))
        XCTAssertTrue(main.isEnabled)
        XCTAssertTrue(main.isChosen)

        let elsewhere = try XCTUnwrap(list.local.first { $0.name == "live-session-design" })
        XCTAssertEqual(elsewhere.subtitle, String(localized: "Checked out in another worktree"))
        XCTAssertFalse(elsewhere.isEnabled)

        let free = try XCTUnwrap(list.local.first { $0.name == "fix-gutter-overflow" })
        XCTAssertNil(free.subtitle)
        XCTAssertTrue(free.isEnabled)
        XCTAssertFalse(free.isChosen)
    }

    func testUncommittedWorkGreysEveryOtherBranchInPlace() throws {
        let list = try list(of: model(draft(), dirty: true))
        let others = (list.local + list.remote).filter { $0.name != "main" }
        XCTAssertFalse(others.isEmpty)
        for item in others where item.name != "live-session-design" {
            XCTAssertEqual(item.subtitle, String(localized: "Uncommitted changes here — use a worktree"), item.name)
            XCTAssertFalse(item.isEnabled, item.name)
        }
        XCTAssertTrue(try XCTUnwrap(list.local.first { $0.name == "main" }).isEnabled)
    }

    func testWithAWorktreeEveryBranchCanBeChosen() throws {
        let model = model(draft { $0.toggleWorktree(in: repository(dirty: true)) }, dirty: true)
        let list = try list(of: model)
        XCTAssertTrue((list.local + list.remote).allSatisfy(\.isEnabled))
        XCTAssertNil(try XCTUnwrap(list.local.first { $0.name == "live-session-design" }).subtitle)
    }

    func testARemoteBranchWithALocalTwinIsListedOnce() throws {
        let list = try list(of: model(draft()))
        XCTAssertEqual(list.remote.map(\.name), ["origin/release/1.4", "origin/sidebar-icons"])
        XCTAssertEqual(list.local.map(\.name), ["main", "live-session-design", "fix-gutter-overflow"])
    }

    func testTheChosenBranchIsMarked() throws {
        let model = model(draft { $0.choose(branch: .named("origin/release/1.4"), in: repository()) })
        let list = try list(of: model)
        XCTAssertEqual((list.local + list.remote).filter(\.isChosen).map(\.name), ["origin/release/1.4"])
    }

    // MARK: The popover's filter

    func testWithoutAQueryTheListIsLocalThenRemote() throws {
        let picker = BranchPickerModel(try list(of: model(draft())))
        let rows = picker.rows(matching: "")
        XCTAssertEqual(rows.first, .header(String(localized: "Local")))
        XCTAssertTrue(rows.contains(.header(String(localized: "Remote"))))
        XCTAssertEqual(rows.count, 2 + 3 + 2)
    }

    func testTypingFiltersByName() throws {
        let picker = BranchPickerModel(try list(of: model(draft())))
        let rows = picker.rows(matching: "GUTTER")
        guard case .branch(let item) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(item.name, "fix-gutter-overflow")
    }

    func testReturnTakesTheFirstMatchThatCanBeChosen() throws {
        let picker = BranchPickerModel(try list(of: model(draft())))
        // The first match for "s" is greyed (another worktree has it).
        XCTAssertEqual(picker.firstChoice(matching: "live"), nil)
        XCTAssertEqual(picker.firstChoice(matching: "release"), .named("origin/release/1.4"))
        XCTAssertEqual(picker.firstChoice(matching: ""), .named("main"))
    }

    func testAHashAddsThePullRequest() throws {
        let picker = BranchPickerModel(try list(of: model(draft())))
        let rows = picker.rows(matching: "#327")
        XCTAssertEqual(rows.suffix(2).first, .header(String(localized: "Pull Request")))
        XCTAssertEqual(
            rows.last,
            .pullRequest(
                number: 327, subtitle: String(localized: "Checked out in a new worktree"), isChosen: false))
        XCTAssertEqual(picker.firstChoice(matching: "#327"), .pullRequest(327))
        XCTAssertEqual(picker.firstChoice(matching: "327"), .pullRequest(327))
    }

    func testThePullRequestTheDraftChoseIsMarked() throws {
        let model = model(draft { $0.choose(branch: .pullRequest(327), in: repository()) })
        let picker = BranchPickerModel(try list(of: model))
        guard case .pullRequest(_, _, let isChosen)? = picker.rows(matching: "#327").last else {
            return XCTFail("no pull request row")
        }
        XCTAssertTrue(isChosen)
    }

    func testNothingMatchingSaysSo() throws {
        let picker = BranchPickerModel(try list(of: model(draft())))
        XCTAssertEqual(picker.rows(matching: "zzz"), [.empty(String(localized: "No Matching Branches"))])
        XCTAssertNil(picker.firstChoice(matching: "zzz"))
    }
}
