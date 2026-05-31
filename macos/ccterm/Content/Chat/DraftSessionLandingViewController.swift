import AppKit
import SwiftUI

/// Full-pane child VC for a `.session(_)` selection whose `Session` is
/// still in `.draft` phase — the landing page for a `/new` / `/clear`
/// draft before its first message. `DetailRouterViewController` mounts this
/// (via the `.draftLanding` child kind) instead of `ChatSessionViewController`
/// while the session is a draft; on first send the session promotes to
/// `.active` and the router swaps in the transcript VC.
///
/// **Why its own VC (vs reusing Compose).** `ComposeSessionViewController`
/// serves the `.newSession` tab and lazily allocates `model.draftSessionId`;
/// this VC instead binds a draft id the router hands it via `present(sessionId:)`,
/// so the same VC instance can re-bind across draft → draft switches. The
/// host-sizing posture is identical to Compose and `ArchiveViewController`:
/// `NSHostingController` with `sizingOptions = []` so the SwiftUI body's
/// fitting size can't bubble up through the split and collapse the window —
/// the four-edge pin lets layout size the host from the pane.
@MainActor
final class DraftSessionLandingViewController: NSViewController, DetailRouterChild {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let notifications: NotificationService
    let searchEngine: SyntaxHighlightEngine
    let searchBus: TranscriptSearchBus
    let inputDraftStore: InputDraftStore

    /// The draft session this VC is currently bound to. Driven by the
    /// router's `present(sessionId:)`; the SwiftUI body keys its identity on
    /// this so a draft → draft switch rebuilds the hosted tree cleanly.
    private var boundSessionId: String?
    private var host: NSHostingController<AnyView>?

    init(
        model: MainSelectionModel,
        sessionManager: SessionManager,
        recentProjects: RecentProjectsStore,
        notifications: NotificationService,
        searchEngine: SyntaxHighlightEngine,
        searchBus: TranscriptSearchBus,
        inputDraftStore: InputDraftStore
    ) {
        self.model = model
        self.sessionManager = sessionManager
        self.recentProjects = recentProjects
        self.notifications = notifications
        self.searchEngine = searchEngine
        self.searchBus = searchBus
        self.inputDraftStore = inputDraftStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    /// `DetailRouterChild` — nothing per-session to tear down (the hosted
    /// SwiftUI tree releases with the VC), but conforming lets the router
    /// treat every child uniformly.
    func prepareForRemoval() {}

    /// Bind (or re-bind) the landing page to `sessionId`. Called by the
    /// router synchronously after this VC is mounted and framed, mirroring
    /// `ChatSessionViewController.present(sessionId:)`. Idempotent for the
    /// same id; a different id rebuilds the host so the new draft's metadata
    /// + input bar render.
    func present(sessionId: String?, animated: Bool = false) {
        guard let sessionId else { return }
        guard sessionId != boundSessionId else { return }
        boundSessionId = sessionId
        updateFocus(activeSessionId: sessionId)
        mountHost(sessionId: sessionId)
    }

    /// Mark the bound draft focused and defocus every other session — the
    /// same sweep `ChatSessionViewController.updateFocus` runs on attach.
    /// Without the sweep, a session the user just navigated AWAY from via
    /// `/new` would keep `isFocused == true` and so suppress its unread dot
    /// when its CLI produces output in the background. The draft itself has
    /// no unread state yet, but participating in the sweep keeps the
    /// presence model consistent across the draft → active flip.
    private func updateFocus(activeSessionId: String) {
        sessionManager.existingSession(activeSessionId)?.setFocused(true)
        for sid in sessionManager.records.map(\.sessionId) where sid != activeSessionId {
            sessionManager.existingSession(sid)?.setFocused(false)
        }
    }

    private func mountHost(sessionId: String) {
        host?.view.removeFromSuperview()
        host?.removeFromParent()

        let root = AnyView(
            DraftSessionLandingView(
                sessionId: sessionId,
                onSubmit: { [weak self] submission in
                    guard let self else { return }
                    submitSessionInput(
                        submission,
                        sessionId: sessionId,
                        sessionManager: self.sessionManager,
                        recentProjects: self.recentProjects,
                        model: self.model)
                },
                onBuiltinCommand: { [weak self] command in
                    guard let self else { return }
                    runBuiltinSlashCommand(
                        command,
                        currentSessionId: sessionId,
                        sessionManager: self.sessionManager,
                        model: self.model)
                }
            )
            .environment(sessionManager)
            .environment(recentProjects)
            .environment(inputDraftStore)
            .environment(\.syntaxEngine, searchEngine)
            .environment(searchBus)
            .environment(notifications)
        )

        let host = NSHostingController(rootView: root)
        // Fill-the-pane detail child — see `ComposeSessionViewController` /
        // `ArchiveViewController` for the full rationale. `[]` severs the
        // body's fitting-size leak into the split's `view.fittingSize` that
        // would otherwise resize / collapse the window.
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.host = host
    }
}

// MARK: - SwiftUI body

/// The draft landing page: a `DotGridBackground` backdrop with a centered
/// hero (sparkles + "Start Building <project>"), the abbreviated path, an
/// optional branch pill, and the embedded input bar — the same surface as
/// the New Session compose card minus the card chrome, folder picker, and
/// recents list. Everything is centered; the bar is a draft-style,
/// not-yet-persisted input keyed on the draft `sessionId`.
struct DraftSessionLandingView: View {
    let sessionId: String
    let onSubmit: (InputBarView2.Submission) -> Void
    let onBuiltinCommand: (BuiltinSlashCommand) -> Void

    @Environment(SessionManager.self) private var manager

    var body: some View {
        let session = manager.prepareDraftSession(sessionId)
        ZStack {
            DotGridBackground()
            VStack(spacing: 14) {
                heroRow(folderName: session.cwd.map { ($0 as NSString).lastPathComponent })
                if let cwd = session.cwd {
                    subtitle(path: cwd)
                }
                if let branch = session.sourceBranch ?? session.worktreeBranch {
                    branchPill(branch: branch, isWorktree: session.isWorktree)
                }
                inputBar
                    .padding(.top, 6)
            }
            .frame(maxWidth: ChatSessionViewController.composeMaxWidth)
            .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
            .padding(.vertical, ChatSessionViewController.detailVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: ChatSessionViewController.detailCoordSpace)
        // Full-bleed: let the dot-grid backdrop extend under the unified
        // toolbar's safe-area inset instead of starting below it.
        .ignoresSafeArea()
    }

    /// "Start Building <name>" with the project name tinted — mirrors
    /// `NewSessionConfigurator.titleRow` so the landing hero reads as the
    /// same family as the compose card, just centered and card-less.
    private func heroRow(folderName: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] + 2 }
            Text(String(localized: "Start Building"))
                .foregroundStyle(.primary)
            if let name = folderName, !name.isEmpty {
                Text(name)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.title.weight(.semibold))
    }

    private func subtitle(path: String) -> some View {
        Text(abbreviatedPath(path))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Read-only branch chip — the landing page shows the inherited branch
    /// but doesn't offer a picker (the draft's metadata is fixed at the
    /// moment `/new` / `/clear` copied it from the source session). Styled
    /// like `NewSessionConfigurator.branchPill` for visual continuity.
    private func branchPill(branch: String, isWorktree: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isWorktree ? "folder.badge.plus" : "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14, height: 14)
            Text(branch)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
    }

    private var inputBar: some View {
        InputBarChrome(
            sessionId: sessionId,
            // Per-draft key: each draft has its own unsent input. Distinct
            // from `InputDraftStore.newSessionKey` (the compose card's
            // shared key), so a draft's text never collides with compose's.
            draftKey: sessionId,
            coordSpace: ChatSessionViewController.detailCoordSpace,
            submitEnabled: manager.prepareDraftSession(sessionId).cwd != nil,
            onSubmit: onSubmit,
            onAttachRect: { _ in },
            onPillRect: { _ in },
            onBuiltinCommand: onBuiltinCommand
        )
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
