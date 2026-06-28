import AgentSDK
import AppKit
import Observation
import XCTest

@testable import ccterm

/// CI-gate logic/measurement tests (NOT a `*SnapshotTests` file → runs on the
/// default suite as the merge gate) for the AppKit chrome row + 5 pickers
/// (migration plan §4.2, §9). Every test drives the REAL controllers — builds a
/// real `ChromeRowView`, calls the production `rebind(session:textView:)`, flips
/// real `session.tasks` / `todos` / `availableModels` / `contextUsage` through
/// the public surface (the runtime `receive` path / `internal(set)`
/// `availableModels` / `requestContextUsage`), and asserts on the controllers'
/// observable state (the band height, arranged-subview `isHidden`, the trigger
/// labels, the `EffortDefaultStore` keys, the `FakeCLIClient.contextUsageCalls`
/// count, the restored `firstResponder`).
///
/// No stubs, no test-only production seams: the controllers' injectable
/// `EffortDefaultStore(defaults:)` / `NewSessionDefaultsStore(defaults:)`
/// (fresh in-memory suites) are the allowed seam; the default init + production
/// behavior are unchanged.
@MainActor
final class ChromeRowViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        resolver = Message2Resolver()
    }

    /// A single resolver reused across the task/todo feeds in one test method —
    /// production wires one `Message2Resolver` per session, and the
    /// `tool_use_result` envelope only resolves to its typed `.TaskCreate` /
    /// `.Bash` variant once the resolver has seen the matching assistant
    /// `tool_use`. A fresh resolver per message would leave the result as
    /// `.unknown` and the todo/task trackers would bail.
    private var resolver: Message2Resolver!

    // MARK: - Runloop pump

    private func settle(iterations: Int = 10) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(20))
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    // MARK: - Fixtures

    /// A fresh in-memory effort store + new-session-defaults store on unique
    /// suites so the `.ultracode` / seed tests are parallel-safe.
    private func makeStores() -> (EffortDefaultStore, NewSessionDefaultsStore, UserDefaults, UserDefaults) {
        let effortSuite = "ccterm-chrome-effort-\(UUID().uuidString)"
        let defaultsSuite = "ccterm-chrome-defaults-\(UUID().uuidString)"
        let effortDefaults = UserDefaults(suiteName: effortSuite)!
        let newSessionDefaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock {
            effortDefaults.removePersistentDomain(forName: effortSuite)
            newSessionDefaults.removePersistentDomain(forName: defaultsSuite)
        }
        return (
            EffortDefaultStore(defaults: effortDefaults),
            NewSessionDefaultsStore(defaults: newSessionDefaults),
            effortDefaults, newSessionDefaults
        )
    }

    /// An active-phase Session whose runtime catalog we can flip
    /// empty→populated through the `internal(set)` `availableModels` setter (the
    /// same surface `InputBarSnapshotTests` uses).
    private func makeActiveSession() -> (ccterm.Session, SessionRuntime) {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })
        let session = Session(runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })
        return (session, runtime)
    }

    private func makeDraftSession() -> ccterm.Session {
        Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() })
    }

    private static func model(
        value: String, effortLevels: [String]? = nil, supportsAuto: Bool = false,
        supportsEffort: Bool = false
    ) -> ModelInfo {
        var dict: [String: Any] = [
            "value": value,
            "displayName": value,
            "description": "\(value) description",
            "supportsAutoMode": supportsAuto,
            "supportsEffort": supportsEffort,
        ]
        if let effortLevels { dict["supportedEffortLevels"] = effortLevels }
        return try! ModelInfo(json: dict)
    }

    /// Mount a chrome row in an offscreen window so the pickers get a window
    /// (firstResponder + popover show need one).
    private func mount(_ row: ChromeRowView, width: CGFloat = 600) -> NSWindow {
        let size = CGSize(width: width, height: 120)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -36),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - Height-invariant + isHidden on tasks/todos (§4.2-10)

    func testBandHeightInvariantAcrossVisibilityToggles() async throws {
        let (session, runtime) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()
        row.layoutSubtreeIfNeeded()
        let baselineHeight = row.fittingSize.height
        XCTAssertEqual(
            baselineHeight, ChromeRowView.rowHeight, accuracy: 0.5,
            "Chrome row band height must be the fixed 22pt.")

        // Initially: tasks/todos empty → BgTask + Todo hidden. ModelEffort is
        // visible because `ModelStore.withExtendedModels([])` is never empty (the
        // built-in 1M-context models), matching production. ContextRing +
        // Permission are always visible.
        XCTAssertTrue(row.backgroundTaskPicker.triggerHiddenForTest, "BgTask hidden when no tasks.")
        XCTAssertTrue(row.todoPicker.triggerHiddenForTest, "Todo hidden when no todos.")
        XCTAssertFalse(
            row.permissionPicker.button.isHidden, "Permission picker is always visible.")
        XCTAssertFalse(
            row.contextRingPicker.button.isHidden, "Context ring is always visible.")

        // Populate the per-session catalog → still visible; band height unchanged.
        runtime.availableModels = [Self.model(value: "default")]
        await settle()
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(
            row.modelEffortPicker.triggerHiddenForTest,
            "ModelEffort visible once the catalog populates.")
        XCTAssertEqual(
            row.fittingSize.height, baselineHeight, accuracy: 0.5,
            "Populating the model catalog must not change the band height.")

        // Add a background task through the real runtime.receive path → BgTask
        // shows; band height unchanged.
        feedRunningTask(into: runtime, taskId: "bg1", toolUseId: "tu1", command: "sleep 5")
        await settle()
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(
            row.backgroundTaskPicker.triggerHiddenForTest,
            "BgTask visible once a task lands.")
        XCTAssertEqual(
            row.fittingSize.height, baselineHeight, accuracy: 0.5,
            "Showing the BgTask button must not change the band height (§4.2-10).")

        // Add a todo through the real runtime.receive path → Todo shows; band
        // height unchanged.
        feedTodo(into: runtime, taskId: "1", subject: "Write tests")
        await settle()
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(
            row.todoPicker.triggerHiddenForTest, "Todo visible once a todo lands.")
        XCTAssertEqual(
            row.fittingSize.height, baselineHeight, accuracy: 0.5,
            "Showing the Todo button must not change the band height (§4.2-10).")
    }

    // MARK: - Backfill-once (§4.2-2, R9)

    func testModelBackfillsExactlyOnce() async throws {
        let (effortStore, newSessionDefaults, _, _) = makeStores()
        let (session, runtime) = makeActiveSession()
        // Seed the per-session catalog so backfill picks a deterministic model
        // (otherwise the built-in extended-context fallback would).
        runtime.availableModels = [
            Self.model(value: "default", effortLevels: ["high", "xhigh"], supportsEffort: true),
            Self.model(value: "sonnet"),
        ]
        let modelEffort = ModelEffortPickerController(
            effortStore: effortStore, defaultsStore: newSessionDefaults)
        let row = ChromeRowView(modelEffortPicker: modelEffort)
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }

        // Track every model transition so a double-apply is observable.
        var modelTransitions: [String?] = []
        observeModel(session) { modelTransitions.append($0) }

        // rebind runs the one-shot backfill (the catalog is already populated →
        // `session.model == nil` → backfill applies the first entry once).
        row.rebind(session: session, textView: nil)
        await settle()
        XCTAssertEqual(session.model, "default", "Backfill picks the first catalog entry.")
        XCTAssertEqual(session.effort, .xhigh, "Backfill resolves + applies the default effort once.")
        let appliedOnce = modelTransitions.filter { $0 == "default" }.count
        XCTAssertEqual(appliedOnce, 1, "Backfill must apply the model exactly once (no double-apply).")

        // Flip the catalog → the catalog-arrival observation fires, but the
        // backfill guard (`session.model == nil`) is now false → no re-apply.
        let modelBefore = session.model
        runtime.availableModels = [
            Self.model(value: "default", effortLevels: ["high", "xhigh"], supportsEffort: true),
            Self.model(value: "haiku"),
        ]
        await settle()
        XCTAssertEqual(session.model, modelBefore, "A second catalog change must not re-backfill.")
        XCTAssertEqual(
            modelTransitions.filter { $0 == "default" }.count, 1,
            "Still applied exactly once after a second catalog change (idempotent guard).")
    }

    // MARK: - Seed-once (§4.2-2)

    func testPermissionSeedsFromDefaultsOnSupportsAutoTransition() async throws {
        // Drive the seed transition for a DRAFT session: the draft's activeModel
        // resolves via the picker's injected `modelStore` (the production
        // fallback for a draft with no runtime catalog). We inject a FRESH,
        // isolated `ModelStore()` rather than mutating the process-wide
        // `.shared` singleton — keeping the test parallel-safe both across
        // classes AND across the sequentially-run methods in this class.
        let (_, newSessionDefaults, _, _) = makeStores()
        newSessionDefaults.setPermissionMode(.auto)

        let session = makeDraftSession()
        // Set the draft's model so activeModel can resolve once the catalog
        // (the injected modelStore) arrives.
        session.setModel("seed-auto-model")

        let modelStore = ModelStore()
        let permission = PermissionModePickerController(
            defaultsStore: newSessionDefaults, modelStore: modelStore)
        let row = ChromeRowView(permissionPicker: permission)
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        // Before the catalog arrives, activeModel is nil → supportsAuto false →
        // .auto is NOT seeded (it'd be hidden anyway).
        XCTAssertEqual(
            session.permissionMode, .default,
            "With no supportsAuto model, .auto must not be seeded yet.")

        // Flip supportsAuto false→true: populate the injected modelStore with a
        // model whose value matches session.model and supportsAutoMode == true.
        modelStore.update([
            Self.model(value: "seed-auto-model", supportsAuto: true)
        ])
        await settle()

        XCTAssertEqual(
            session.permissionMode, .auto,
            "On the supportsAuto false→true transition with a saved .auto default, "
                + "the seed must fire (§4.2-2).")

        // Idempotent: a further catalog change does not re-seed / flip the mode.
        modelStore.update([
            Self.model(value: "seed-auto-model", supportsAuto: true),
            Self.model(value: "another"),
        ])
        await settle()
        XCTAssertEqual(
            session.permissionMode, .auto, "Seed is idempotent — re-checks its guard post-write.")
    }

    // MARK: - .ultracode skip-persist (§4.2-7)

    func testUltracodeNotPersistedButHighIs() async throws {
        let (effortStore, _, effortDefaults, _) = makeStores()
        let (session, runtime) = makeActiveSession()
        let modelEffort = ModelEffortPickerController(effortStore: effortStore)
        let row = ChromeRowView(modelEffortPicker: modelEffort)
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        // A model with xhigh → activeEffortLevels appends .ultracode.
        runtime.availableModels = [
            Self.model(
                value: "ultra-model", effortLevels: ["low", "high", "xhigh"], supportsEffort: true)
        ]
        session.setModel("ultra-model")
        row.rebind(session: session, textView: nil)
        await settle()

        // Select .ultracode through the real entry point → session.effort set,
        // but NO key written to EffortDefaultStore (the skip-persist guard).
        modelEffort.selectEffort(.ultracode)
        XCTAssertEqual(session.effort, .ultracode, "Selecting .ultracode sets session.effort.")
        XCTAssertNil(
            effortDefaults.string(forKey: "effortFor:ultra-model"),
            "Selecting .ultracode must NOT persist to EffortDefaultStore (§4.2-7).")

        // Select .high → the key IS written.
        modelEffort.selectEffort(.high)
        XCTAssertEqual(session.effort, .high)
        XCTAssertEqual(
            effortDefaults.string(forKey: "effortFor:ultra-model"), "high",
            "Selecting a non-ultracode effort persists to EffortDefaultStore.")
    }

    // MARK: - requestContextUsage once-per-open (§4.2-8)

    func testRequestContextUsageOncePerOpen() async throws {
        let fake = FakeCLIClient()
        let session = try await ChromeRowTestSupport.makeActivatedSession(client: fake, test: self)

        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        // Bind/rebind must NOT request context usage (only viewWillAppear does).
        XCTAssertEqual(
            fake.contextUsageCalls.count, 0,
            "rebind must not request context usage (§4.2-8 — only the open popover does).")

        // Drive the breakdown content VC's viewWillAppear (the production seam).
        let vc1 = ContextBreakdownContentViewController(session: session)
        vc1.loadViewIfNeeded()
        vc1.viewWillAppear()
        XCTAssertEqual(
            fake.contextUsageCalls.count, 1,
            "Opening the breakdown popover fires requestContextUsage exactly once.")
        // Re-firing viewWillAppear on the SAME VC must not double-request (the
        // per-open `didRequest` guard).
        vc1.viewWillAppear()
        XCTAssertEqual(
            fake.contextUsageCalls.count, 1,
            "A redundant viewWillAppear on the same open must not re-request (didRequest guard).")
        vc1.viewWillDisappear()

        // Complete the first in-flight request so the next request isn't
        // coalesced into it (the runtime dedups concurrent in-flight requests).
        let usage = try ContextUsage(json: ["rawMaxTokens": 200_000, "totalTokens": 1000])
        fake.completeContextUsage(.usage(usage))
        // The cache flips `isFetchingContextUsage` false on a future @MainActor
        // tick; wait for it so the re-open dispatches a fresh CLI call.
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { !session.isFetchingContextUsage }
            },
            object: nil)
        await fulfillment(of: [settled], timeout: 3)

        // A re-open (fresh VC) fires again.
        let vc2 = ContextBreakdownContentViewController(session: session)
        vc2.loadViewIfNeeded()
        vc2.viewWillAppear()
        XCTAssertEqual(
            fake.contextUsageCalls.count, 1,
            "Re-opening dispatches a fresh CLI request (the prior one already drained).")
    }

    // MARK: - firstResponder restore across popover open/close (§4.2-1, R13)

    func testFirstResponderRestoredAcrossPopover() async throws {
        let (session, _) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        // A stub first responder standing in for the input bar. Use a custom
        // first-responder NSView (not an NSTextField — a field hands key focus to
        // its field-editor NSTextView, so `window.firstResponder` would be the
        // editor, not the field).
        let stub = FirstResponderStubView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(stub)
        window.makeFirstResponder(stub)
        XCTAssertEqual(window.firstResponder, stub, "Precondition: stub view is first responder.")

        row.rebind(session: session, textView: nil)
        await settle()

        let picker = row.permissionPicker
        picker.show()
        await settle()
        XCTAssertTrue(picker.isPopoverShown, "Popover should be shown after show().")
        XCTAssertNotNil(
            picker.capturedFirstResponderForTest,
            "The first responder should be captured before the popover steals key-window.")

        // Simulate the transient close → popoverDidClose restores the responder.
        picker.toggle()
        await settle()
        XCTAssertFalse(picker.isPopoverShown, "Popover should close on toggle.")
        XCTAssertEqual(
            window.firstResponder, stub,
            "The saved first responder must be restored on popoverDidClose (R13).")
    }

    // MARK: - BackgroundTask label + group order (§4.2 list)

    func testBackgroundTaskLabelAndGroupOrder() async throws {
        let (session, runtime) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        XCTAssertTrue(row.backgroundTaskPicker.triggerHiddenForTest, "Hidden with no tasks.")

        // One running task → "1 running".
        feedRunningTask(into: runtime, taskId: "r1", toolUseId: "tu_r1", command: "sleep 9")
        await settle()
        XCTAssertFalse(row.backgroundTaskPicker.triggerHiddenForTest, "Shown once a task lands.")
        XCTAssertEqual(
            row.backgroundTaskPicker.triggerLabelForTest, "1 running",
            "Label reads 'N running' while a task runs.")

        // Complete it → "1 completed".
        completeTask(into: runtime, taskId: "r1", toolUseId: "tu_r1")
        await settle()
        XCTAssertEqual(
            row.backgroundTaskPicker.triggerLabelForTest, "1 completed",
            "Label reads 'N completed' once every task is terminal.")

        // Grouping: a running + two completed → Running group first, Completed
        // group sorted by (endedAt ?? startedAt) desc.
        let now = Date()
        let tasks = [
            BackgroundTask(
                id: "run", toolUseId: nil, description: nil, taskType: nil, command: nil,
                outputFile: nil, startedAt: now, endedAt: nil, status: .running, summary: nil),
            BackgroundTask(
                id: "old", toolUseId: nil, description: nil, taskType: nil, command: nil,
                outputFile: nil, startedAt: now.addingTimeInterval(-100),
                endedAt: now.addingTimeInterval(-90), status: .completed, summary: nil),
            BackgroundTask(
                id: "new", toolUseId: nil, description: nil, taskType: nil, command: nil,
                outputFile: nil, startedAt: now.addingTimeInterval(-50),
                endedAt: now.addingTimeInterval(-10), status: .completed, summary: nil),
        ]
        let groups = BackgroundTaskListContentViewController.group(tasks: tasks)
        XCTAssertEqual(groups.map(\.id), ["running", "completed"], "Running group precedes Completed.")
        XCTAssertEqual(groups[0].tasks.map(\.id), ["run"])
        XCTAssertEqual(
            groups[1].tasks.map(\.id), ["new", "old"],
            "Completed group sorts by (endedAt ?? startedAt) desc.")
    }

    // MARK: - Detail sheet window-level + teardown (§4.2-5, R5)

    func testDetailSheetWindowLevelAndTeardown() async throws {
        let (session, runtime) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()
        // Give the task a real spool file so the detail sheet's stream opens it.
        let spool = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-chrome-spool-\(UUID().uuidString).output")
        try "hello output\n".write(to: spool, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: spool) }
        feedRunningTask(
            into: runtime, taskId: "sheet1", toolUseId: "tu_s1", command: "sleep 30",
            outputFile: spool.path)
        await settle()
        XCTAssertEqual(
            session.tasks.first(where: { $0.id == "sheet1" })?.outputFile, spool.path,
            "Precondition: the task carries its spool path.")

        // Drive the row-select closure (the production seam). The sheet presents
        // on the window (window.attachedSheet non-nil after the async hop).
        row.backgroundTaskPicker.openDetailForTest(taskId: "sheet1")
        let presented = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.attachedSheet != nil },
            object: nil)
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertNotNil(window.attachedSheet, "The detail sheet must present at the window level (§4.2-5).")
        XCTAssertTrue(
            row.backgroundTaskPicker.detailPresenter.isPresenting,
            "The owned presenter tracks the live sheet.")
        let sheetVC = try XCTUnwrap(row.backgroundTaskPicker.detailPresenter.contentVC)
        XCTAssertTrue(sheetVC.streamStartedForTest, "The detail sheet re-reads the live task + tails output.")

        // Teardown (InputBarController.prepareForRemoval → chromeRow.teardown)
        // dismisses the sheet — no orphan stream/sheet.
        row.teardown()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.attachedSheet == nil },
            object: nil)
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertNil(window.attachedSheet, "Teardown must dismiss the detail sheet (R5).")
        XCTAssertFalse(
            row.backgroundTaskPicker.detailPresenter.isPresenting,
            "The presenter must release after teardown (no orphan).")
    }

    // MARK: - rebind cancels prior observation/timers (§4.2-9)

    func testRebindCancelsPriorSessionObservation() async throws {
        let (sessionA, runtimeA) = makeActiveSession()
        let (sessionB, runtimeB) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: sessionA, textView: nil)
        await settle()
        row.layoutSubtreeIfNeeded()
        let heightBefore = row.fittingSize.height

        // Rebind to B.
        row.rebind(session: sessionB, textView: nil)
        await settle()
        row.layoutSubtreeIfNeeded()
        let heightAfter = row.fittingSize.height
        XCTAssertEqual(
            heightBefore, heightAfter, accuracy: 0.5,
            "Rebind must keep the band height invariant (attachSession bar-invariance).")

        // A stale update on session A must NOT drive the row (it's bound to B now):
        // feeding A a task should NOT show the BgTask button.
        feedRunningTask(into: runtimeA, taskId: "stale", toolUseId: "tu_stale", command: "sleep 1")
        await settle()
        XCTAssertTrue(
            row.backgroundTaskPicker.triggerHiddenForTest,
            "A stale A-session task must not drive the row after rebind to B.")

        // Feeding B a task DOES show it (the live session drives updates).
        feedRunningTask(into: runtimeB, taskId: "live", toolUseId: "tu_live", command: "sleep 1")
        await settle()
        XCTAssertFalse(
            row.backgroundTaskPicker.triggerHiddenForTest,
            "The newly-bound B session drives the row.")
    }

    // MARK: - Labels-are-literal-English (extends InputBarLabelsTests)

    func testChromeSectionHeadersAreLiteralEnglish() async throws {
        // The section headers rendered by the AppKit content VCs are the
        // un-localized CLI vocabulary. Assert the literals the pickers emit.
        let (effortStore, newSessionDefaults, _, _) = makeStores()
        let (session, runtime) = makeActiveSession()
        runtime.availableModels = [
            Self.model(value: "default", effortLevels: ["high", "xhigh"], supportsEffort: true)
        ]
        session.setModel("default")
        let permission = PermissionModePickerController(defaultsStore: newSessionDefaults)
        let modelEffort = ModelEffortPickerController(
            effortStore: effortStore, defaultsStore: newSessionDefaults)
        let row = ChromeRowView(permissionPicker: permission, modelEffortPicker: modelEffort)
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        // Permission popover: section header "Mode".
        let permissionVC = permission.makePopoverContentViewController()
        permissionVC.loadViewIfNeeded()
        XCTAssertTrue(
            Self.containsHeader(permissionVC.view, title: "Mode"),
            "Permission popover renders the literal 'Mode' header.")

        // ModelEffort popover: "Models" / "Effort" / "Fast mode".
        let modelVC = modelEffort.makePopoverContentViewController()
        modelVC.loadViewIfNeeded()
        XCTAssertTrue(Self.containsHeader(modelVC.view, title: "Models"), "literal 'Models'.")
        XCTAssertTrue(Self.containsHeader(modelVC.view, title: "Effort"), "literal 'Effort'.")
        XCTAssertTrue(Self.containsHeader(modelVC.view, title: "Fast mode"), "literal 'Fast mode'.")
    }

    // MARK: - Permission trigger tint + label parity

    func testPermissionTriggerLabelTracksMode() async throws {
        let (_, newSessionDefaults, _, _) = makeStores()
        let session = makeDraftSession()
        let permission = PermissionModePickerController(defaultsStore: newSessionDefaults)
        let row = ChromeRowView(permissionPicker: permission)
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()
        XCTAssertEqual(
            permission.triggerTitleForTest, "Ask", "Default mode shows the 'Ask' short title.")

        permission.selectMode(.plan)
        await settle()
        XCTAssertEqual(
            permission.triggerTitleForTest, "Plan", "Selecting Plan shows the 'Plan' short title.")
        XCTAssertEqual(session.permissionMode, .plan, "Selecting a mode writes it through the façade.")
    }

    // MARK: - ContextRing trigger is the BARE ring (no pill surface) — parity fix

    func testContextRingTriggerHasNoPillSurface() async throws {
        // The SwiftUI ContextRingButton is a bare `Button { ProgressRingView }
        // .buttonStyle(.plain)` — no `.barSurface`, no hover fill, no padding.
        // The AppKit trigger must reproduce that: showsSurface == false, no hover
        // overlay (resolvedHoverOpacity == -1 sentinel), and an intrinsic width
        // of exactly the 22pt ring (NO 2×8 horizontal padding the surface adds).
        let (session, _) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        let ringButton = row.contextRingPicker.button
        XCTAssertFalse(
            ringButton.showsSurface,
            "The ContextRing trigger must be surface-less (bare ring, no pill).")
        XCTAssertEqual(
            ringButton.resolvedHoverOpacity, -1,
            "A surface-less ContextRing trigger has no hover overlay (the -1 sentinel).")
        XCTAssertEqual(
            ringButton.intrinsicContentSize.width, 22, accuracy: 0.5,
            "The bare ring footprint is exactly 22pt — no 2×8 surface padding.")

        // Contrast: a chrome button that DOES show its surface adds 2×8 padding.
        let permissionButton = row.permissionPicker.button
        XCTAssertTrue(permissionButton.showsSurface, "Other pickers keep the pill surface.")
        XCTAssertGreaterThanOrEqual(
            permissionButton.resolvedHoverOpacity, 0,
            "A surfaced chrome button has a live hover overlay (>= 0).")
    }

    // MARK: - firstResponder restore is NOT clobbered across an A→B rebind (R13)

    func testFirstResponderNotClobberedByRebindWhilePopoverOpen() async throws {
        let (sessionA, _) = makeActiveSession()
        let (sessionB, _) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        // Two distinct stand-in responders: one focused before the popover opens
        // (the A-session bar), and the one the rebind to B would install.
        let responderA = FirstResponderStubView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let responderB = FirstResponderStubView(frame: NSRect(x: 0, y: 24, width: 100, height: 22))
        window.contentView?.addSubview(responderA)
        window.contentView?.addSubview(responderB)

        row.rebind(session: sessionA, textView: nil)
        await settle()
        window.makeFirstResponder(responderA)
        XCTAssertEqual(window.firstResponder, responderA, "Precondition: A's responder is focused.")

        // Open a picker (captures responderA + session A identity).
        let picker = row.permissionPicker
        picker.show()
        await settle()
        XCTAssertTrue(picker.isPopoverShown, "Popover open.")
        XCTAssertNotNil(picker.capturedFirstResponderForTest, "Responder captured before show().")

        // Rebind to B while the popover is open — this is the racing path. The
        // rebind closes the popover and synchronously clears the saved responder,
        // then B installs its own focus.
        row.rebind(session: sessionB, textView: nil)
        window.makeFirstResponder(responderB)
        await settle()

        // The late popoverDidClose (if any) must NOT have restored responderA over
        // the freshly-focused B responder.
        XCTAssertEqual(
            window.firstResponder, responderB,
            "A rebind-triggered popover close must not clobber B's responder with A's (R13).")
        XCTAssertNil(
            picker.capturedFirstResponderForTest,
            "The saved responder is cleared synchronously on rebind.")
    }

    // MARK: - Detail sheet content parity (displayKind / Live / summary / timestamps)

    func testDetailSheetRendersFullContent() async throws {
        let (session, runtime) = makeActiveSession()
        let row = ChromeRowView()
        let window = mount(row)
        defer {
            window.contentView = nil
            window.close()
        }
        row.rebind(session: session, textView: nil)
        await settle()

        let spool = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-detail-content-\(UUID().uuidString).output")
        try "first line\nsecond line\n".write(to: spool, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: spool) }
        // A running task with a spool path → Live pill + output basename render.
        feedRunningTask(
            into: runtime, taskId: "detail1", toolUseId: "tu_d1", command: "sleep 30",
            outputFile: spool.path)
        await settle()

        // Build + drive the detail VC directly (the real production VC).
        let vc = BackgroundTaskDetailSheetViewController(
            taskId: "detail1", session: session, onDismiss: {})
        vc.loadViewIfNeeded()
        vc.viewWillAppear()
        await settle()

        // displayKind chip: task_type "local_bash" → "bash".
        XCTAssertTrue(
            Self.containsLabel(vc.view, text: "bash"),
            "Detail sheet renders the displayKind chip ('bash' for local_bash).")
        // Live pill: visible while running with a bound stream.
        XCTAssertTrue(vc.liveVisibleForTest, "The Live pill shows while running with a stream.")
        // Output-file basename + tooltip.
        XCTAssertEqual(
            vc.outputFileLabelForTest, spool.lastPathComponent,
            "Detail sheet shows the output-file basename.")
        // Started timestamp line is populated; Ended is hidden while running.
        // (Locale-independent: the "Started" label is localized, so assert the
        // line is non-empty and carries a time digit rather than an English
        // prefix.)
        XCTAssertFalse(
            vc.startedLineForTest.isEmpty, "Started timestamp line is rendered.")
        XCTAssertTrue(
            vc.startedLineForTest.contains(where: \.isNumber),
            "Started timestamp line carries a time value.")
        XCTAssertTrue(vc.endedHiddenForTest, "Ended line is hidden while the task runs.")
        XCTAssertFalse(vc.summaryVisibleForTest, "No Result section while running.")
        vc.viewWillDisappear()

        // Complete the task with a summary → Result section + Ended + no Live.
        completeTask(into: runtime, taskId: "detail1", toolUseId: "tu_d1")
        await settle()
        let vc2 = BackgroundTaskDetailSheetViewController(
            taskId: "detail1", session: session, onDismiss: {})
        vc2.loadViewIfNeeded()
        vc2.viewWillAppear()
        await settle()
        XCTAssertTrue(
            vc2.summaryVisibleForTest, "A terminal task with a summary renders the Result section.")
        XCTAssertFalse(vc2.liveVisibleForTest, "The Live pill hides once the task is terminal.")
        XCTAssertFalse(vc2.endedHiddenForTest, "The Ended timestamp line shows for a terminal task.")
        vc2.viewWillDisappear()
    }

    // MARK: - Helpers — find a literal header in the VC tree

    private static func containsLabel(_ view: NSView, text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text { return true }
        for sub in view.subviews where containsLabel(sub, text: text) { return true }
        return false
    }

    private static func containsHeader(_ view: NSView, title: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == title { return true }
        for sub in view.subviews where containsHeader(sub, title: title) { return true }
        return false
    }

    private func observeModel(_ session: ccterm.Session, _ onChange: @escaping (String?) -> Void) {
        withObservationTracking {
            _ = session.model
        } onChange: { [weak session] in
            DispatchQueue.main.async {
                guard let session else { return }
                onChange(session.model)
                self.observeModel(session, onChange)
            }
        }
    }

    // MARK: - Helpers — drive the real runtime.receive task/todo path

    private func resolve(_ dict: [String: Any]) -> Message2 {
        try! resolver.resolve(dict)
    }

    private func feedRunningTask(
        into runtime: SessionRuntime, taskId: String, toolUseId: String, command: String,
        outputFile: String? = nil
    ) {
        runtime.receive(
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m", "type": "message", "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use", "id": toolUseId, "name": "Bash",
                            "input": ["command": command, "run_in_background": true],
                        ]
                    ],
                ],
            ]))
        runtime.receive(
            resolve([
                "type": "system", "subtype": "task_started", "uuid": UUID().uuidString,
                "session_id": "s", "task_id": taskId, "tool_use_id": toolUseId,
                "description": "", "task_type": "local_bash",
            ]))
        if let outputFile {
            // The bash tool_result carries the spool path
            // ("Output is being written to: <path>.") + the backgroundTaskId,
            // which `TaskTracker.rememberOutputFileFromBashResult` parses.
            runtime.receive(
                resolve([
                    "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                    "message": [
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result", "tool_use_id": toolUseId,
                                "content":
                                    "Command running in background with ID: \(taskId). "
                                    + "Output is being written to: \(outputFile). "
                                    + "You will be notified when it completes.",
                            ]
                        ],
                    ],
                    "tool_use_result": [
                        "stdout": "", "stderr": "", "interrupted": false, "isImage": false,
                        "noOutputExpected": false, "backgroundTaskId": taskId,
                    ],
                ]))
        }
    }

    private func completeTask(into runtime: SessionRuntime, taskId: String, toolUseId: String) {
        runtime.receive(
            resolve([
                "type": "system", "subtype": "task_notification", "uuid": UUID().uuidString,
                "session_id": "s", "task_id": taskId, "tool_use_id": toolUseId,
                "status": "completed", "output_file": "/tmp/out.txt",
                "summary": "done",
            ]))
    }

    private func feedTodo(into runtime: SessionRuntime, taskId: String, subject: String) {
        // TaskCreate tool_use + its tool_result echoing task.id.
        runtime.receive(
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m", "type": "message", "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use", "id": "tc_\(taskId)", "name": "TaskCreate",
                            "input": ["subject": subject, "activeForm": "Working"],
                        ]
                    ],
                ],
            ]))
        runtime.receive(
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": "tc_\(taskId)",
                            "content": "Created task",
                        ]
                    ],
                ],
                "tool_use_result": [
                    "task": ["id": taskId, "subject": subject, "status": "pending"]
                ],
            ]))
    }
}

/// Shared helper to stand up an `.active`-phase Session attached to a
/// `FakeCLIClient` (so `requestContextUsage` forwards to the fake). Mirrors
/// `ContextUsageTests.makeActivatedSession`.
@MainActor
enum ChromeRowTestSupport {
    static func makeActivatedSession(
        client fake: FakeCLIClient, test: XCTestCase
    ) async throws
        -> ccterm.Session
    {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid, title: "chrome-ctx", cwd: NSTemporaryDirectory(), status: .created)
        repo.save(record)
        let session = Session(record: record, repository: repo, cliClientFactory: { _ in fake })
        session.activate()
        let runtime = try XCTUnwrap(session.runtime)
        let attached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { runtime.cliClient != nil }
            },
            object: nil)
        await test.fulfillment(of: [attached], timeout: 5)
        return session
    }
}

/// A minimal first-responder NSView standing in for the input bar in the
/// popover firstResponder-restore test. Unlike NSTextField it owns key focus
/// directly (no field editor), so `window.firstResponder === self`.
final class FirstResponderStubView: NSView {
    override var acceptsFirstResponder: Bool { true }
    nonisolated deinit {}
}
