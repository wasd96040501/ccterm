import AppKit

@testable import ccterm

/// Factory entry points that assemble **real** production view trees with
/// in-memory, parallel-safe dependencies. Each returns a mounted
/// `AppKitStage`; the associated session ids / model live on the returned
/// `Fixture` so a test can drive selection and look up sessions.
extension AppKitStage {

    /// Everything a factory builds, beyond the mounted stage: the real
    /// `MainSelectionModel`, `SessionManager`, and the session ids seeded
    /// into it (index-aligned with the `sessions` array passed in).
    @MainActor
    struct Fixture {
        let stage: AppKitStage
        let model: MainSelectionModel
        let sessionManager: SessionManager
        /// In creation order. `sessionIds[i]` is the i-th `SessionSpec`.
        let sessionIds: [String]

        func teardown() { stage.teardown() }
    }

    /// Declarative seed for one session: its sidebar title + the transcript
    /// blocks already in its controller. Defaults to a paragraph-heavy
    /// transcript so geometry / scroll tests have real rows to measure.
    @MainActor
    struct SessionSpec {
        var title: String
        var blocks: [Block]

        init(title: String = "Session", blocks: [Block]? = nil) {
            self.title = title
            self.blocks = blocks ?? SessionSpec.paragraphBlocks(count: 60)
        }

        /// N paragraph blocks of real wrapping text — enough rows to fill a
        /// `defaultWindowSize` viewport and exercise scroll / tail anchoring.
        static func paragraphBlocks(count: Int) -> [Block] {
            (0..<count).map { i in
                Block(
                    id: UUID(),
                    kind: .paragraph(inlines: [
                        .text(
                            "line \(i): the rain in spain falls mainly on the plain, "
                                + "and the quick brown fox jumps over the lazy dog.")
                    ]))
            }
        }
    }

    // MARK: - Shared session seeding

    /// Build a parallel-safe `SessionManager` over an
    /// `InMemorySessionRepository`, seed one record + transcript per spec,
    /// and return it alongside the created ids and the cleanup hooks
    /// (temp draft dir, UserDefaults suite) the caller must register.
    private static func makeSeededManager(
        _ specs: [SessionSpec]
    ) -> (manager: SessionManager, ids: [String]) {
        let repo = InMemorySessionRepository()
        var ids: [String] = []
        for (i, spec) in specs.enumerated() {
            let sid = UUID().uuidString
            ids.append(sid)
            repo.save(
                SessionRecord(
                    sessionId: sid, title: spec.title,
                    cwd: "/tmp/ccterm-stage-s\(i)", status: .created))
        }
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })
        for (i, sid) in ids.enumerated() {
            manager.session(sid)?.controller.apply(.append(specs[i].blocks))
        }
        return (manager, ids)
    }

    /// In-memory, per-stage `DetailContext` dependencies + the cleanups
    /// that dispose their on-disk / UserDefaults artifacts.
    private static func makeIsolatedDeps() -> (
        recentProjects: RecentProjectsStore,
        inputDraftStore: InputDraftStore,
        groupOrder: SidebarSessionGroupOrderStore,
        syntaxEngine: SyntaxHighlightEngine,
        cleanups: [() -> Void]
    ) {
        let suite = "ccterm-stage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-stage-\(UUID().uuidString)", isDirectory: true)
        let cleanups: [() -> Void] = [
            { defaults.removePersistentDomain(forName: suite) },
            { try? FileManager.default.removeItem(at: draftDir) },
        ]
        return (
            RecentProjectsStore(defaults: defaults),
            InputDraftStore(directory: draftDir, debounceInterval: 0.05),
            SidebarSessionGroupOrderStore(defaults: defaults),
            SyntaxHighlightEngine(),
            cleanups
        )
    }

    // MARK: - Detail-router-only factory

    /// Mount a real `DetailRouterViewController` (no sidebar) over a seeded
    /// `SessionManager`. The lightest factory that still exercises the real
    /// router swap / chat VC / transcript. `initialIndex` is set on the
    /// model **before** mount so `viewDidLoad` attaches it synchronously
    /// (the router's observation arms only after the VC loads — see
    /// `DetailRouterViewController`).
    static func detailRouter(
        sessions: [SessionSpec],
        initialIndex: Int? = nil,
        size: CGSize = defaultWindowSize
    ) -> Fixture {
        let (manager, ids) = makeSeededManager(sessions)
        let deps = makeIsolatedDeps()

        let model = MainSelectionModel()
        model.selection = initialIndex.map { .session(ids[$0]) } ?? .none

        let router = DetailRouterViewController(
            context: DetailContext(
                model: model,
                sessionManager: manager,
                recentProjects: deps.recentProjects,
                inputDraftStore: deps.inputDraftStore,
                syntaxEngine: deps.syntaxEngine),
            notifications: NotificationService(activation: AppActivationTracker()))

        let stage = mount(router, size: size, cleanups: deps.cleanups)
        return Fixture(stage: stage, model: model, sessionManager: manager, sessionIds: ids)
    }

    // MARK: - Full main-split factory

    /// Mount the real `MainSplitViewController` — real `SidebarViewController`
    /// + real `DetailRouterViewController` + real `SessionManager` — built
    /// through a dependency-injected `AppState` so the production assembly
    /// path runs verbatim, only with in-memory stores. This is the factory
    /// for sidebar ↔ transcript linkage tests.
    static func mainSplit(
        sessions: [SessionSpec],
        initialIndex: Int? = nil,
        size: CGSize = defaultWindowSize
    ) -> Fixture {
        let (manager, ids) = makeSeededManager(sessions)
        let deps = makeIsolatedDeps()

        let appState = AppState(
            sessionManager: manager,
            syntaxEngine: deps.syntaxEngine,
            recentProjects: deps.recentProjects,
            inputDraftStore: deps.inputDraftStore,
            sidebarGroupOrder: deps.groupOrder,
            // Headless: skip the JSCore syntax load + installed-apps disk
            // scan — no test observes either, and both add startup cost.
            eagerlyLoadSyntaxEngine: false,
            probeOpenInApps: false)

        let model = MainSelectionModel()
        model.selection = initialIndex.map { .session(ids[$0]) } ?? .none

        let split = MainSplitViewController(model: model, appState: appState)
        let stage = mount(split, size: size, cleanups: deps.cleanups)
        return Fixture(stage: stage, model: model, sessionManager: manager, sessionIds: ids)
    }

    // MARK: - Mounted-VC accessors

    /// The mounted `MainSplitViewController`, or nil if this stage was built
    /// by a different factory.
    var mainSplit: MainSplitViewController? {
        rootViewController as? MainSplitViewController
    }

    /// The mounted `DetailRouterViewController` — the `detailRouter` factory's
    /// root, or the split's trailing item for a `mainSplit` stage.
    var router: DetailRouterViewController? {
        if let r = rootViewController as? DetailRouterViewController { return r }
        return mainSplit?.detailRouter
    }

    /// Width of the sidebar pane (the leading split item's view), in the
    /// split's coordinate space. Nil unless this is a `mainSplit` stage.
    /// Use it so a transcript-region assertion needn't hard-code the
    /// sidebar's autosaved thickness.
    var sidebarWidth: CGFloat? {
        guard let split = mainSplit, let first = split.splitViewItems.first else { return nil }
        return first.viewController.view.frame.width
    }

    /// Width of the detail pane (the trailing split item's view). Nil unless
    /// this is a `mainSplit` stage. This — not the window width — is the
    /// space the transcript / resting bar actually lay out in.
    var detailPaneWidth: CGFloat? {
        guard let split = mainSplit, split.splitViewItems.count >= 2 else { return nil }
        return split.splitViewItems[1].viewController.view.frame.width
    }
}
