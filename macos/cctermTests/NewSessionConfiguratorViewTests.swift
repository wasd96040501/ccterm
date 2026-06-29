import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for the AppKit `NewSessionConfiguratorViewController`
/// (migration plan §4.6). Drives the PRODUCTION VC + a real `Session.draft`
/// (via `SessionManager(InMemorySessionRepository)`), a scratch
/// `RecentProjectsStore(defaults: UserDefaults(suiteName: UUID()))`, real temp
/// folders + git repos, and the production `InputBarController` — asserting on
/// observable draft / recents / table state. No test-only production seams.
@MainActor
final class NewSessionConfiguratorViewTests: XCTestCase {

    private var rootDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncs-vc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDir { try? FileManager.default.removeItem(at: rootDir) }
    }

    // MARK: - Fixture

    private struct Fixture {
        let vc: NewSessionConfiguratorViewController
        let controller: InputBarController
        let manager: SessionManager
        let repo: InMemorySessionRepository
        let recents: RecentProjectsStore
        let session: Session
        let draftId: String
        let resumed: ResumeRecorder
    }

    private final class ResumeRecorder { var ids: [String] = [] }

    private func makeFixture(
        submitEnabledProvider: ((Session) -> Bool)? = nil
    ) -> Fixture {
        let repo = InMemorySessionRepository()
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let suite = "ncs-vc-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentProjectsStore(defaults: defaults)

        let draftDir = rootDir.appendingPathComponent("drafts-\(UUID().uuidString)")
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        let barSuite = "ncs-vc-bar-\(UUID().uuidString)"
        let barDefaults = UserDefaults(suiteName: barSuite)!
        addTeardownBlock { barDefaults.removePersistentDomain(forName: barSuite) }

        let draftId = UUID().uuidString.lowercased()
        let session = manager.prepareDraftSession(draftId)

        let controller = InputBarController(
            sessionManager: manager,
            inputDraftStore: inputDraftStore,
            userDefaults: barDefaults,
            notificationCenter: NotificationCenter(),
            submitEnabledProvider: submitEnabledProvider ?? { $0.cwd != nil },
            onSubmit: { _, _ in })

        let recorder = ResumeRecorder()
        let vc = NewSessionConfiguratorViewController(
            sessionManager: manager,
            recents: recents,
            inputBarController: controller,
            draftSessionId: draftId,
            onResumeSession: { recorder.ids.append($0) })

        return Fixture(
            vc: vc, controller: controller, manager: manager, repo: repo, recents: recents,
            session: session, draftId: draftId, resumed: recorder)
    }

    /// Mount the VC's view offscreen so `viewDidLoad` runs + the tables/bar get
    /// a real frame. Returns the window so the caller can keep it alive.
    @discardableResult
    private func mount(_ fx: Fixture, size: CGSize = CGSize(width: 1000, height: 700)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        fx.vc.loadViewIfNeeded()
        fx.vc.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = fx.vc
        window.ccterm_orderFrontForTesting()
        fx.vc.view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - Git repo helper

    @discardableResult
    private func makeGitRepo(name: String, branches: [String]) throws -> URL {
        precondition(!branches.isEmpty)
        let dir = rootDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(in: dir, "init", "-q", "--initial-branch=\(branches[0])")
        try runGit(in: dir, "config", "user.email", "test@example.com")
        try runGit(in: dir, "config", "user.name", "test")
        try runGit(in: dir, "config", "commit.gpgsign", "false")
        let seed = dir.appendingPathComponent("seed.txt")
        try "seed".write(to: seed, atomically: true, encoding: .utf8)
        try runGit(in: dir, "add", "seed.txt")
        try runGit(in: dir, "commit", "-q", "-m", "initial")
        for branch in branches.dropFirst() { try runGit(in: dir, "branch", branch) }
        return dir
    }

    private func makePlainFolder(_ name: String) throws -> URL {
        let dir = rootDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "NCSVCTests", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Folder selection writes cwd + originPath as a PAIR (MAJOR)

    func testSelectFolderWritesCwdAndOriginPathPair() throws {
        let fx = makeFixture()
        mount(fx)
        let folder = try makePlainFolder("proj-a")

        fx.vc.selectFolder(folder.path)

        XCTAssertEqual(fx.session.cwd, folder.path, "setCwd must run")
        XCTAssertEqual(
            fx.session.originPath, folder.path,
            "setOriginPath must run alongside setCwd (the load-bearing pair)")
    }

    func testSelectFolderNilClearsCwdAndOriginPath() throws {
        let fx = makeFixture()
        mount(fx)
        let folder = try makePlainFolder("proj-clear")
        fx.vc.selectFolder(folder.path)
        XCTAssertEqual(fx.session.cwd, folder.path)

        fx.vc.selectFolder(nil)
        XCTAssertNil(fx.session.cwd, "clearing folder zeroes cwd")
        XCTAssertNil(fx.session.originPath, "clearing folder zeroes originPath")
    }

    // MARK: - Worktree menu mapping

    func testWorktreeMenuMapping() throws {
        let fx = makeFixture()
        mount(fx)
        let repo = try makeGitRepo(name: "wt-repo", branches: ["main"])
        fx.vc.selectFolder(repo.path)

        fx.vc.setWorktree(true)
        XCTAssertTrue(fx.session.isWorktree, "New Worktree → setWorktree(true)")

        fx.vc.setWorktree(false)
        XCTAssertFalse(fx.session.isWorktree, "Local → setWorktree(false)")
    }

    // MARK: - Branch select (drive BranchPickerViewController.onSelect)

    func testBranchSelectWritesSourceBranch() throws {
        let fx = makeFixture()
        mount(fx)

        var selected: String?
        let picker = BranchPickerViewController(
            branches: ["main", "develop"], currentBranch: "main", remoteMainBranch: nil,
            currentBranchStatus: nil,
            onSelect: { branch in
                selected = branch
                fx.vc.setSourceBranch(branch)
            })
        picker.loadViewIfNeeded()
        // Drive the REAL selection path: select the "develop" branch row by index
        // via `selectRowIndexes`, which fires the production
        // `tableViewSelectionDidChange` delegate (no test-only seam), then
        // `confirm()` is already real surface. The row index comes from the same
        // production `BranchPickerModel.rows` ordering the picker renders.
        let model = BranchPickerModel(
            branches: ["main", "develop"], currentBranch: "main", remoteMainBranch: nil,
            currentBranchStatus: nil)
        let developRow = try XCTUnwrap(
            model.rows.firstIndex { $0.branch?.branch == "develop" },
            "develop must render as a selectable row")
        XCTAssertEqual(
            picker.tableView.numberOfRows, model.rows.count,
            "picker table renders the production model rows verbatim")
        picker.tableView.selectRowIndexes(
            IndexSet(integer: developRow), byExtendingSelection: false)
        picker.confirm()

        XCTAssertEqual(selected, "develop")
        XCTAssertEqual(fx.session.sourceBranch, "develop", "branch pick writes draft.setSourceBranch")
    }

    // MARK: - applyProbeBindings reconcile (git vs non-git vs missing)

    func testApplyProbeBindingsGitRepo() throws {
        let fx = makeFixture()
        mount(fx)
        let repo = try makeGitRepo(name: "git-bind", branches: ["main", "feature/x"])

        fx.vc.selectFolder(repo.path)

        XCTAssertEqual(
            fx.session.sourceBranch, "main",
            "git repo: sourceBranch falls to currentBranch on reset")
        // useWorktree = recents.useWorktree(for:) ?? false → no saved pref → false.
        XCTAssertFalse(fx.session.isWorktree)
    }

    func testApplyProbeBindingsNonGitZeroesBoth() throws {
        let fx = makeFixture()
        mount(fx)
        let plain = try makePlainFolder("non-git")
        // Pre-set a stale branch/worktree to prove the non-git arm zeroes them.
        fx.session.draft?.setSourceBranch("stale")
        fx.session.draft?.setWorktree(true)

        fx.vc.selectFolder(plain.path)

        XCTAssertNil(fx.session.sourceBranch, "non-git: sourceBranch zeroed")
        XCTAssertFalse(fx.session.isWorktree, "non-git: useWorktree zeroed")
    }

    func testApplyProbeBindingsMissingFolderRemovesFromRecents() throws {
        let fx = makeFixture()
        mount(fx)
        let folder = try makePlainFolder("vanishing")
        fx.recents.add(folder.path)
        fx.vc.selectFolder(folder.path)
        XCTAssertEqual(fx.session.cwd, folder.path)

        // Delete on disk, then re-run the folder-change driver.
        try FileManager.default.removeItem(at: folder)
        fx.vc.applyFolderChange(resetOverride: true)

        XCTAssertFalse(
            fx.recents.entries.contains { $0.path == folder.path },
            "missing folder is pruned from recents")
        XCTAssertNil(fx.session.cwd, "missing folder clears cwd")
    }

    // MARK: - Stale-branch reconcile after loadHeavy

    func testStaleBranchReconcileAfterLoadHeavy() async throws {
        let fx = makeFixture()
        mount(fx)
        let repo = try makeGitRepo(name: "stale-repo", branches: ["main", "develop"])

        // Seed a deleted ref BEFORE the folder change so resetOverride=false keeps
        // it through the synchronous applyProbeBindings; the post-loadHeavy
        // reconcile then drops it. (selectFolder uses resetOverride:true, so drive
        // the driver directly with resetOverride:false to model a restored draft.)
        fx.session.draft?.setCwd(repo.path)
        fx.session.draft?.setOriginPath(repo.path)
        fx.session.draft?.setSourceBranch("deleted-branch")
        fx.vc.applyFolderChange(resetOverride: false)

        // After loadHeavy lands, branches = [main, develop] which doesn't contain
        // "deleted-branch" → falls back to probe.currentBranch ("main").
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in fx.session.sourceBranch == "main" },
            object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(fx.session.sourceBranch, "main")
    }

    // MARK: - Recents reactive refresh

    func testRecentsReactiveRefreshOnAdd() async throws {
        let fx = makeFixture()
        mount(fx)
        let before = fx.vc.recentsTableView.numberOfRows

        let folder = try makePlainFolder("reactive-add")
        fx.recents.add(folder.path)

        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                fx.vc.recentsTableView.numberOfRows == before + 1
            }, object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(fx.vc.recentsTableView.numberOfRows, before + 1)
    }

    func testRecentSessionsReactiveRefreshOnSave() async throws {
        let fx = makeFixture()
        mount(fx)
        let folder = try makePlainFolder("rec-sessions")
        fx.vc.selectFolder(folder.path)
        XCTAssertEqual(fx.vc.recentSessionsTableView.numberOfRows, 0)

        // Save a created record rooted at the picked folder + refresh the
        // manager's records; the records observation must reload the
        // Recent-Sessions table (drive the real repo + manager, no test seam).
        let record = SessionRecord(
            sessionId: UUID().uuidString.lowercased(), title: "Hello", cwd: folder.path,
            originPath: folder.path, status: .created)
        fx.repo.save(record)
        fx.manager.refreshRecords()

        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                fx.vc.recentSessionsTableView.numberOfRows == 1
            }, object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(fx.vc.recentSessionsTableView.numberOfRows, 1)
    }

    // MARK: - submitEnabled reactivity (drive the real InputBarController)

    func testSubmitEnabledTracksCwd() async throws {
        let fx = makeFixture(submitEnabledProvider: { $0.cwd != nil })
        mount(fx)
        // The configurator's viewDidLoad already rebound the embedded bar against
        // the compose draft (cwd == nil) so its cwd-observation is armed; assert
        // the starting state then flip cwd and let the observation re-fire.
        fx.controller.barView.textView.insertText(
            "hello", replacementRange: fx.controller.barView.textView.selectedRange())
        XCTAssertFalse(fx.controller.canSend, "cwd == nil → cannot send even with text")

        let folder = try makePlainFolder("submit-enabled")
        fx.vc.selectFolder(folder.path)
        // The bar's withObservationTracking over session.cwd re-fires async
        // (beforeWaiting) → updateSubmitEnabled. Wait on canSend via a predicate
        // rather than a fixed spin.
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in fx.controller.canSend }, object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(fx.controller.canSend, "setCwd enables send")
    }

    // MARK: - remove-from-recents side effect

    func testRemoveCurrentFolderFromRecentsClearsCwd() throws {
        let fx = makeFixture()
        mount(fx)
        let folder = try makePlainFolder("remove-me")
        fx.recents.add(folder.path)
        fx.vc.selectFolder(folder.path)
        XCTAssertEqual(fx.session.cwd, folder.path)

        fx.vc.removeFromRecents(folder.path)

        XCTAssertFalse(
            fx.recents.entries.contains { $0.path == folder.path },
            "removed path no longer in recents")
        XCTAssertNil(fx.session.cwd, "removing the current folder clears cwd to nil")
    }

    // MARK: - compactRelative boundaries (pure-fn)

    func testCompactRelativeBoundaries() {
        let now = Date()
        func rel(_ secondsAgo: TimeInterval) -> String {
            NewSessionConfiguratorViewController.compactRelative(
                from: now.addingTimeInterval(-secondsAgo), now: now)
        }
        // "now" is localized (`String(localized: "now")`) — compare against the
        // resolved string so the test is locale-independent. The "Nm/Nh/Nd/>7d"
        // forms are plain interpolation, not localized.
        XCTAssertEqual(rel(30), String(localized: "now"))
        XCTAssertEqual(rel(59 * 60), "59m")
        XCTAssertEqual(rel(23 * 3600), "23h")
        XCTAssertEqual(rel(6 * 86_400), "6d")
        XCTAssertEqual(rel(8 * 86_400), ">7d")
    }

    // MARK: - No-collapse guard (card root publishes bounded fittingSize)

    func testCardRootPublishesZeroIntrinsicSize() throws {
        let fx = makeFixture()
        mount(fx)
        // The card surface root overrides intrinsicContentSize = .zero so its
        // @required min-size band never leaks up into the 4-edge-pinned compose
        // root and collapses the window (plan R1).
        XCTAssertEqual(fx.vc.view.intrinsicContentSize, .zero)
    }

    // MARK: - Meta-row visibility ↔ divider anchor (non-git dead-gap fix)

    func testMetaRowHiddenCollapsesDividerGapForNonGitFolder() throws {
        let fx = makeFixture()
        mount(fx)
        // A non-git folder has no currentBranch → the meta row is hidden, and the
        // divider must re-anchor to the subtitle so the hidden row's slot
        // collapses (no ~24pt dead gap above the divider).
        let plain = try makePlainFolder("non-git-divider")
        fx.vc.selectFolder(plain.path)

        XCTAssertTrue(fx.vc.metaRow.isHidden, "non-git folder hides the meta row")
        XCTAssertEqual(fx.vc.dividerTopFromSubtitle?.isActive, true)
        XCTAssertEqual(fx.vc.dividerTopFromMeta?.isActive, false)
    }

    func testMetaRowVisibleAnchorsDividerToMetaForGitFolder() throws {
        let fx = makeFixture()
        mount(fx)
        // A git repo with a current branch shows the meta row → the divider
        // anchors to metaRow.bottom (so the pills sit between subtitle + divider).
        let repo = try makeGitRepo(name: "git-divider", branches: ["main"])
        fx.vc.selectFolder(repo.path)

        XCTAssertFalse(fx.vc.metaRow.isHidden, "git folder shows the meta row")
        XCTAssertEqual(fx.vc.dividerTopFromMeta?.isActive, true)
        XCTAssertEqual(fx.vc.dividerTopFromSubtitle?.isActive, false)
    }

    // MARK: - Meta-row pill chrome (capsule control parity)

    func testMetaPillsAreCapsuleControls() throws {
        let fx = makeFixture()
        mount(fx)
        // The worktree + branch pills are CapsulePillButtons (stroke + hover/press
        // fill + 6/4 inset) — the AppKit equivalent of SwiftUI HoverCapsuleStyle +
        // the static Capsule strokeBorder. Assert the meta row arranges exactly
        // those two capsule controls (a bare NSButton would read as plain
        // icon+text with no button affordance).
        let pills = fx.vc.metaRow.arrangedSubviews.compactMap { $0 as? CapsulePillButton }
        XCTAssertEqual(pills.count, 2, "meta row hosts the worktree + branch capsule pills")
        XCTAssertTrue(pills.contains(fx.vc.worktreeButton))
        XCTAssertTrue(pills.contains(fx.vc.branchButton))
    }

    // MARK: - BranchPickerModel filter math (ported verbatim, :22-41)

    func testBranchPickerModelSectioning() {
        let model = BranchPickerModel(
            branches: ["main", "develop", "feature/x"],
            currentBranch: "main",
            remoteMainBranch: "origin/main",
            currentBranchStatus: "Clean")
        // rows interleave section headers exactly where the SwiftUI
        // `branchListSection` emitted them:
        //   header(Current Branch), branch(main), header(Remote Main),
        //   branch(origin/main), header(Branches (2)), branch(develop),
        //   branch(feature/x).
        let rows = model.rows
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[0], .header(String(localized: "Current Branch")))
        XCTAssertEqual(rows[1].branch?.branch, "main")
        XCTAssertTrue(rows[1].branch?.isCurrent == true)
        XCTAssertEqual(rows[1].branch?.subtitle, "Clean")
        XCTAssertEqual(rows[2], .header(String(localized: "Remote Main")))
        XCTAssertEqual(rows[3].branch?.branch, "origin/main")
        XCTAssertFalse(rows[3].branch?.isCurrent == true)
        // The "Branches (N)" count reflects the filtered-other branch count.
        // Resolve the header via the SAME interpolated key production uses
        // (`Branches (%lld)`) so the assertion is locale-independent — a literal
        // "Branches (2)" would hit a different, untranslated catalog key.
        let otherCount = 2
        XCTAssertEqual(rows[4], .header(String(localized: "Branches (\(otherCount))")))
        XCTAssertEqual(Set(rows[5...].compactMap { $0.branch?.branch }), Set(["develop", "feature/x"]))
        // Only branch rows are selectable; headers carry no payload.
        XCTAssertEqual(model.branchRows.count, 4)
        XCTAssertEqual(rows.filter { $0.isHeader }.count, 3)
    }

    func testBranchPickerModelFilterAndEmptyState() {
        var model = BranchPickerModel(
            branches: ["main", "develop"], currentBranch: "main", remoteMainBranch: nil,
            currentBranchStatus: nil)
        model.searchText = "dev"
        XCTAssertEqual(model.filteredBranches, ["develop"])
        XCTAssertNil(model.filteredCurrentBranch, "main filtered out → no current section")
        XCTAssertFalse(model.showsEmptyState, "matching query → not empty")

        model.searchText = "zzz"
        XCTAssertTrue(model.showsEmptyState, "non-empty query, zero matches → empty state")

        model.searchText = ""
        XCTAssertFalse(model.showsEmptyState, "empty query never shows the No-Matches state")
    }

    // MARK: - DotGridLayout geometry (lifted computable logic)

    func testDotGridLayoutCenters() {
        let layout = DotGridLayout(pitch: 28, dotDiameter: 2.0, opacity: 0.20)
        // First center at pitch/2 = 14; dots march while center < size on each axis.
        let rects = layout.dotRects(in: CGSize(width: 60, height: 60))
        // x centers: 14, 42 (< 60); 70 excluded. Same for y → 2x2 = 4 dots.
        XCTAssertEqual(rects.count, 4)
        // First dot rect: center (14,14), radius 1 → origin (13,13), 2x2.
        XCTAssertEqual(rects[0], CGRect(x: 13, y: 13, width: 2, height: 2))
    }

    func testDotGridLayoutZeroSizeIsEmpty() {
        let layout = DotGridLayout()
        XCTAssertTrue(layout.dotRects(in: .zero).isEmpty)
    }
}
