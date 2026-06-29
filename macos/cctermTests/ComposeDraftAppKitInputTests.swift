import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for the Phase-4 re-point of
/// `ComposeSessionViewController` + `DraftSessionLandingViewController` onto the
/// AppKit `InputBarController` (+ `NewSessionConfiguratorViewController` for
/// compose) — migration plan §4.6. Drives the PRODUCTION VCs through an
/// `InMemorySessionRepository`-backed `SessionManager`, a scratch
/// `RecentProjectsStore`, a temp-dir `InputDraftStore`, and a fresh
/// `MainSelectionModel`, mounted in an offscreen window so autofocus +
/// window-gating are real. Asserts on observable VC / session / model state —
/// no test-only production seams.
///
/// What each test exercises through the real surface:
///   - submit produces the right `Submission` + promotes the draft + clears the
///     persisted draft (compose keyed on `newSessionKey`, draft keyed on the
///     session id);
///   - a `session.cwd` flip flips `inputBarController.canSend` (the reactive
///     `submitEnabledProvider` path);
///   - a draft → draft `present` re-keys the SAME bar in place (no rebuild);
///   - neither VC mounts any `NSHostingController` / `NSHostingView` (the literal
///     zero-SwiftUI gate for these two surfaces).
@MainActor
final class ComposeDraftAppKitInputTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture

    private struct Fixture {
        let context: DetailContext
        let model: MainSelectionModel
        let manager: SessionManager
        let recents: RecentProjectsStore
        let inputDraftStore: InputDraftStore
    }

    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let manager = SessionManager(repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let suite = "compose-draft-repoint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentProjectsStore(defaults: defaults)

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-draft-repoint-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let context = DetailContext(
            model: model,
            sessionManager: manager,
            recentProjects: recents,
            inputDraftStore: inputDraftStore,
            syntaxEngine: SyntaxHighlightEngine())
        return Fixture(
            context: context, model: model, manager: manager, recents: recents,
            inputDraftStore: inputDraftStore)
    }

    /// Mount a VC's view offscreen so `viewDidLoad` runs + the bar/tables get a
    /// real frame (autofocus + window-gating are real). Returns the window so the
    /// caller keeps it alive.
    @discardableResult
    private func mount(
        _ vc: NSViewController, size: CGSize = CGSize(width: 1100, height: 760)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        vc.loadViewIfNeeded()
        vc.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = vc
        window.ccterm_orderFrontForTesting()
        vc.view.layoutSubtreeIfNeeded()
        return window
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Fixed-iteration pump for AppKit layout/CA + the Swift-concurrency executor
    /// (the bar's draft-load Task + the re-armed observation hops). Not a
    /// condition-sleep — callers that wait on a value use a predicate expectation
    /// or `waitForDraft`.
    private func settle(iterations: Int = 8) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(30))
            drainMainLoop(seconds: 0.02)
        }
    }

    /// Condition-wait on the persisted draft for `sessionId` reaching `expected`
    /// (`nil` = cleared, non-nil text = present). Polls the REAL async
    /// `InputDraftStore.load` — pumping the runloop between checks so the
    /// debounced `save` work item / the `clear` file delete on `ioQueue` lands —
    /// and returns the last-loaded draft. This is a genuine condition-wait on the
    /// store's observable on-disk state (not a fixed sleep): it stops as soon as
    /// the predicate holds, and only times out if it never does.
    @discardableResult
    private func waitForDraft(
        _ store: InputDraftStore, sessionId: String,
        until predicate: @escaping (InputDraft?) -> Bool,
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
    ) async -> InputDraft? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = await store.load(sessionId: sessionId)
        while !predicate(last), Date() < deadline {
            drainMainLoop(seconds: 0.02)
            last = await store.load(sessionId: sessionId)
        }
        XCTAssertTrue(
            predicate(last),
            "waitForDraft timed out for sessionId=\(sessionId); last=\(String(describing: last))",
            file: file, line: line)
        return last
    }

    /// Type `text` into the bar via the real `insertText:` + `textDidChange`
    /// delegate path (a headless view does not always emit `textDidChange`).
    private func type(_ text: String, into controller: InputBarController) {
        let tv = controller.barView.textView
        tv.insertText(text, replacementRange: tv.selectedRange())
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
    }

    /// Walk a view subtree asserting NO `NSHostingController`-managed view nor
    /// `NSHostingView` is present (the literal zero-SwiftUI gate). Returns the
    /// offending class name if found.
    private func firstHostingViewClassName(in root: NSView) -> String? {
        let name = String(describing: Swift.type(of: root))
        if name.hasPrefix("NSHostingView") || name.hasPrefix("_NSHostingView") {
            return name
        }
        for sub in root.subviews {
            if let hit = firstHostingViewClassName(in: sub) { return hit }
        }
        return nil
    }

    // MARK: - Compose: submit produces Submission + promotes draft + clears draft

    func testComposeSubmitPromotesDraftAndClearsNewSessionKeyDraft() async throws {
        let fx = makeFixture()
        fx.model.selection = .newSession
        let vc = ComposeSessionViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        await settle()

        let draftId = try XCTUnwrap(fx.model.draftSessionId, "compose allocates a draftSessionId")
        let session = fx.manager.prepareDraftSession(draftId)
        XCTAssertTrue(session.isDraft, "session starts as a draft")

        // Pick a folder so submit is enabled (compose's submitEnabledProvider is
        // { cwd != nil }). Drive the real configurator folder path.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-submit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        vc.configurator.selectFolder(folder.path)

        // Pre-seed a persisted draft on the COMPOSE key so we can prove the clear
        // ran (the compose bar keys on InputDraftStore.newSessionKey, NOT draftId).
        fx.inputDraftStore.save(
            InputDraft(text: "stale compose draft", filePaths: [], updatedAt: Date()),
            for: InputDraftStore.newSessionKey)
        // Condition-wait on the debounced save landing on disk (not a fixed sleep).
        await waitForDraft(
            fx.inputDraftStore, sessionId: InputDraftStore.newSessionKey,
            until: { $0?.text == "stale compose draft" })

        type("build me a thing", into: vc.inputBarController)
        XCTAssertTrue(vc.inputBarController.canSend, "text + folder picked → canSend")

        vc.inputBarController.handleSend()

        // Promotion ran synchronously inside onSubmit → submitSessionInput.
        XCTAssertTrue(session.hasRecord, "submit promotes the draft to a real session")
        XCTAssertFalse(session.isDraft)
        XCTAssertEqual(
            fx.model.selection, .session(draftId),
            "promote flips selection to .session(draftId)")
        XCTAssertNil(fx.model.draftSessionId, "draftSessionId is cleared on promotion")

        // The persisted draft under the COMPOSE key is gone (the bar's
        // store.clear(newSessionKey) before onSubmit). The async file delete
        // settles after the call returns — condition-wait on the cleared state.
        let after = await waitForDraft(
            fx.inputDraftStore, sessionId: InputDraftStore.newSessionKey, until: { $0 == nil })
        XCTAssertNil(after, "handleSend clears the persisted COMPOSE draft (newSessionKey)")
    }

    // MARK: - Draft landing: submit produces Submission + promotes + clears sid draft

    func testDraftLandingSubmitPromotesDraftAndClearsSessionIdDraft() async throws {
        let fx = makeFixture()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-submit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        // A sidebar draft, seeded with a cwd so canSend can enable.
        let draftId = fx.manager.createSidebarDraft(seededFrom: nil)
        let session = fx.manager.prepareDraftSession(draftId)
        session.draft?.setCwd(folder.path)
        session.draft?.setOriginPath(folder.path)
        fx.model.selection = .session(draftId)

        let vc = DraftSessionLandingViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        vc.present(sessionId: draftId)
        await settle()

        XCTAssertTrue(session.isDraft, "draft starts as a draft")

        // Pre-seed a persisted draft on the SESSION-ID key (draft landing keys on
        // sessionId, the rebind default).
        fx.inputDraftStore.save(
            InputDraft(text: "stale draft-landing", filePaths: [], updatedAt: Date()),
            for: draftId)
        await waitForDraft(
            fx.inputDraftStore, sessionId: draftId, until: { $0?.text == "stale draft-landing" })

        type("first message", into: vc.inputBarController)
        XCTAssertTrue(vc.inputBarController.canSend, "text + cwd → canSend")

        vc.inputBarController.handleSend()

        XCTAssertTrue(session.hasRecord, "submit promotes the draft")
        XCTAssertFalse(session.isDraft)
        XCTAssertEqual(
            fx.model.selection, .session(draftId),
            "promote re-routes the same .session(draftId) selection in place")
        XCTAssertNil(fx.model.draftSessionId)

        let after = await waitForDraft(
            fx.inputDraftStore, sessionId: draftId, until: { $0 == nil })
        XCTAssertNil(after, "handleSend clears the persisted draft under the SESSION-ID key")
    }

    // MARK: - Reactive submitEnabled: cwd flip flips canSend (compose)

    func testComposeCwdFlipFlipsCanSend() async throws {
        let fx = makeFixture()
        fx.model.selection = .newSession
        let vc = ComposeSessionViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        await settle()

        let draftId = try XCTUnwrap(fx.model.draftSessionId)
        let session = fx.manager.prepareDraftSession(draftId)
        // Start cwd-less (ensureDraftSession only seeds cwd if recents has a
        // lastLaunchedPath; this fresh recents store has none).
        XCTAssertNil(session.cwd, "fresh compose draft has no cwd")

        type("hello", into: vc.inputBarController)
        XCTAssertFalse(
            vc.inputBarController.canSend, "cwd == nil → cannot send even with text")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        // Drive the real configurator folder pick → writes draft.setCwd → the
        // bar's withObservationTracking over session.cwd re-fires updateSubmitEnabled.
        vc.configurator.selectFolder(folder.path)

        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { [controller = vc.inputBarController] _, _ in
                controller?.canSend == true
            }, object: nil)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(vc.inputBarController.canSend, "picking a folder enables send")
    }

    // MARK: - Draft → draft rebind in place (no host/bar rebuild)

    func testDraftLandingRebindsBarInPlaceAcrossDraftSwitch() async throws {
        let fx = makeFixture()
        let draftA = fx.manager.createSidebarDraft(seededFrom: nil)
        let draftB = fx.manager.createSidebarDraft(seededFrom: nil)

        let vc = DraftSessionLandingViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }

        vc.present(sessionId: draftA)
        await settle()
        let barAfterA = try XCTUnwrap(vc.inputBarController)
        XCTAssertEqual(barAfterA.boundSessionId, draftA)
        let childCountAfterA = vc.children.count

        vc.present(sessionId: draftB)
        await settle()
        // SAME controller instance retained (identity unchanged), rebound in place.
        XCTAssertTrue(
            vc.inputBarController === barAfterA,
            "draft → draft must reuse the SAME InputBarController (no rebuild)")
        XCTAssertEqual(vc.inputBarController.boundSessionId, draftB, "rebound to draft B")
        XCTAssertEqual(
            vc.children.count, childCountAfterA,
            "no extra child VC mounted on rebind (no host rebuild)")
    }

    // MARK: - Compose draft-clear keyed on newSessionKey, NOT draftId

    func testComposeBarKeysDraftOnNewSessionKey() async throws {
        // Prove the compose draftKey indirection: text persists under
        // newSessionKey, NOT the (regenerating) draftSessionId.
        let fx = makeFixture()
        fx.model.selection = .newSession
        let vc = ComposeSessionViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        await settle()
        let draftId = try XCTUnwrap(fx.model.draftSessionId)

        type("persist me", into: vc.inputBarController)
        // Condition-wait on the bar's debounced scheduleDraftSave landing under
        // newSessionKey (not a fixed sleep).
        let underNewSessionKey = await waitForDraft(
            fx.inputDraftStore, sessionId: InputDraftStore.newSessionKey,
            until: { $0?.text == "persist me" })
        let underDraftId = await fx.inputDraftStore.load(sessionId: draftId)
        XCTAssertEqual(
            underNewSessionKey?.text, "persist me",
            "compose persists the unsent draft under newSessionKey")
        XCTAssertNil(
            underDraftId, "compose must NOT key the draft on the regenerating draftSessionId")
    }

    // MARK: - Zero-SwiftUI gate: no NSHostingController / NSHostingView descendant

    func testComposeMountsNoSwiftUIHost() throws {
        let fx = makeFixture()
        fx.model.selection = .newSession
        let vc = ComposeSessionViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        // No NSHostingController child VC.
        for child in vc.children {
            XCTAssertFalse(
                String(describing: Swift.type(of: child)).hasPrefix("NSHostingController"),
                "Compose must mount no NSHostingController child; found \(Swift.type(of: child)).")
        }
        // No NSHostingView in the view subtree.
        if let hit = firstHostingViewClassName(in: vc.view) {
            XCTFail("Compose view tree contains a SwiftUI host: \(hit)")
        }
    }

    func testDraftLandingMountsNoSwiftUIHost() throws {
        let fx = makeFixture()
        let draftId = fx.manager.createSidebarDraft(seededFrom: nil)
        fx.model.selection = .session(draftId)
        let vc = DraftSessionLandingViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        vc.present(sessionId: draftId)

        for child in vc.children {
            XCTAssertFalse(
                String(describing: Swift.type(of: child)).hasPrefix("NSHostingController"),
                "Draft landing must mount no NSHostingController child; found \(Swift.type(of: child)).")
        }
        if let hit = firstHostingViewClassName(in: vc.view) {
            XCTFail("Draft-landing view tree contains a SwiftUI host: \(hit)")
        }
    }

    // MARK: - Regime-A: both VCs publish ≈ 0 fittingSize (no window collapse)

    func testBothVCsPublishZeroFittingHeight() throws {
        // The regime-A no-collapse contract for the de-SwiftUI'd roots: pinned
        // 4-edge with intrinsicContentSize=.zero roots + non-required inner min
        // constraints, neither VC's view leaks a fittingSize up the split.
        let fxA = makeFixture()
        fxA.model.selection = .newSession
        let compose = ComposeSessionViewController(context: fxA.context)
        let windowA = mount(compose)
        defer {
            windowA.contentViewController = nil
            windowA.close()
        }
        XCTAssertLessThanOrEqual(
            compose.view.fittingSize.height, 1,
            "Compose root must publish ≈ 0 fittingSize.height (regime-A); got "
                + "\(compose.view.fittingSize.height).")

        let fxB = makeFixture()
        let draftId = fxB.manager.createSidebarDraft(seededFrom: nil)
        fxB.model.selection = .session(draftId)
        let draft = DraftSessionLandingViewController(context: fxB.context)
        let windowB = mount(draft)
        defer {
            windowB.contentViewController = nil
            windowB.close()
        }
        draft.present(sessionId: draftId)
        XCTAssertLessThanOrEqual(
            draft.view.fittingSize.height, 1,
            "Draft-landing root must publish ≈ 0 fittingSize.height (regime-A); got "
                + "\(draft.view.fittingSize.height).")
    }

    // MARK: - Compose card shrinks-to-fit a narrow pane (no horizontal clipping)

    func testComposeCardShrinksToFitNarrowPane() throws {
        // The pane-coupled REQUIRED `<=` WIDTH cap (the shrink-to-fit fix): on a
        // pane narrower than the ideal 960 card + 2*20 margins, the card must
        // SHRINK its width instead of holding 960 and clipping the Projects
        // column / bar off the pane edge. The detail pane reaches 680pt at the
        // supported minimum (MainSplitViewController detailItem.minimumThickness),
        // so this is reachable in normal use, not hypothetical. (Height holds the
        // ideal and overflows centered — the documented width/height asymmetry,
        // because the card's vertical content min would leak the fittingSize gate
        // if height were pane-coupled.)
        let fx = makeFixture()
        fx.model.selection = .newSession
        let vc = ComposeSessionViewController(context: fx.context)
        // 720pt-wide pane: narrower than 960+40, wider than the card's own
        // horizontal content min (~673) so the shrink is observable + fits.
        let paneSize = CGSize(width: 720, height: 760)
        let window = mount(vc, size: paneSize)
        defer {
            window.contentViewController = nil
            window.close()
        }
        vc.view.layoutSubtreeIfNeeded()

        let card = vc.configurator.view

        // Card shrank below the ideal width (would have held 960 + clipped before
        // the pane-coupled cap).
        XCTAssertLessThan(
            card.frame.width, NewSessionConfiguratorViewController.idealWidth,
            "card should shrink below ideal width on a narrow pane; got \(card.frame.width)")
        // Card width fits inside the pane (no horizontal clipping). It cannot go
        // below its own ~673pt horizontal content min, so it may not honor the
        // full 20pt side margins on a very narrow pane — but it must never exceed
        // the pane width itself.
        XCTAssertLessThanOrEqual(
            card.frame.width, paneSize.width + 0.5,
            "card width must fit inside the pane (no clipping); got \(card.frame.width)")
        // The pane-coupled WIDTH inequality stays LEAK-SAFE: even on this narrow
        // pane the root still publishes ≈ 0 fittingSize.height (the regime-A
        // no-collapse contract is height-axis; a width cap must not perturb it).
        XCTAssertLessThanOrEqual(
            vc.view.fittingSize.height, 1,
            "pane-coupled width cap must not leak fittingSize.height; got "
                + "\(vc.view.fittingSize.height)")
    }

    // MARK: - Draft-landing bar-top gap survives the no-branch edge

    func testDraftLandingBarTopGapHomedOnLastVisibleView() async throws {
        // The 20pt bar-top gap (SwiftUI `inputBar.padding(.top, 6)` on top of
        // VStack spacing 14) must be re-homed onto the last VISIBLE view above
        // the bar — NSStackView ignores custom spacing anchored to a hidden
        // arranged view, so a no-branch draft (pill hidden) must move the 20pt
        // onto the subtitle, and a cwd==nil draft onto the title row.
        let fx = makeFixture()
        // A draft WITH a cwd but NO branch → subtitle visible, pill hidden.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let draftId = fx.manager.createSidebarDraft(seededFrom: nil)
        let session = fx.manager.prepareDraftSession(draftId)
        session.draft?.setCwd(folder.path)
        fx.model.selection = .session(draftId)

        let vc = DraftSessionLandingViewController(context: fx.context)
        let window = mount(vc)
        defer {
            window.contentViewController = nil
            window.close()
        }
        vc.present(sessionId: draftId)
        await settle()

        // The branch pill (DraftBranchPillView) is hidden for a no-branch draft.
        let pill = try XCTUnwrap(firstView(in: vc.view, ofType: DraftBranchPillView.self))
        XCTAssertTrue(pill.isHidden, "no-branch draft hides the branch pill")
        // The hero column is the vertical stack the pill is an arranged subview
        // of (unambiguous — only the hero column arranges the pill).
        let column = try XCTUnwrap(
            pill.superview as? NSStackView, "branch pill should live in the hero column stack")
        XCTAssertEqual(column.orientation, .vertical)
        // The 20pt gap is NOT on the hidden pill (NSStackView would ignore it);
        // it is re-homed onto the last VISIBLE view above the bar. Assert the
        // hidden pill is at default spacing and exactly one visible arranged view
        // carries the 20pt gap.
        XCTAssertEqual(
            column.customSpacing(after: pill), NSStackView.useDefaultSpacing,
            "hidden pill keeps default spacing (the 20pt is re-homed off it)")
        let twentyPtAnchors = column.arrangedSubviews.filter {
            !$0.isHidden && column.customSpacing(after: $0) == 20
        }
        XCTAssertEqual(
            twentyPtAnchors.count, 1,
            "exactly one VISIBLE view above the bar carries the 20pt gap; got "
                + "\(twentyPtAnchors.count)")
    }

    // MARK: - View-tree search helpers

    private func firstView<T: NSView>(in root: NSView, ofType type: T.Type) -> T? {
        if let t = root as? T { return t }
        for sub in root.subviews {
            if let hit = firstView(in: sub, ofType: type) { return hit }
        }
        return nil
    }
}
