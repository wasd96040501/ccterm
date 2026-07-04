import AppKit

/// Detail child mounted for `MainSelection.session(_)` — renders a real
/// `Transcript2Controller`-backed transcript for a session, and reserves
/// space at the bottom for the input bar (rendered as a placeholder view
/// in this refactor; the SwiftUI `InputBarView2` migration lands in a
/// follow-up PR).
///
/// This is the AppKit-skeleton stand-in for `ChatSessionViewController`:
/// the transcript mounting mechanism (build → settle → bind → scroll-to-
/// tail, plus per-attach sinks) is delegated verbatim to
/// `TranscriptSwapCoordinator`; the SwiftUI-hosted scrims, resting bar,
/// and permission-card floats that the old chat VC layered around the
/// transcript are omitted here — they come back later as AppKit VCs.
///
/// Attach ordering follows the same "settle before present" contract the
/// old router honoured (root CLAUDE.md § macOS runloop tick model and
/// NativeTranscript2/CLAUDE.md § 2.19): `present(sessionId:)` must run
/// against a framed `view`, so the coordinator can typeset each block at
/// exactly one width. When the caller lands the id before `viewDidLayout`
/// has settled the frame (initial mount), the id is parked in
/// `pendingSessionId` and the attach runs on the first framed layout.
@MainActor
final class HistorySessionViewController: NSViewController, DetailContainerChild {
    /// Detail-scope dependency bag threaded through from
    /// `DetailFlowCoordinator`. `sessionManager` + `syntaxEngine` are
    /// consumed by the swap coordinator; `selectionStore` /
    /// `recentProjects` / `inputDraftStore` are wired here for the
    /// upcoming AppKit input-bar migration and land in follow-up PRs.
    let detailContext: DetailContext

    /// Bottom-anchored placeholder occupying the space the SwiftUI input
    /// bar (`InputBarView2`) will fill when it lands as AppKit. Sized to
    /// roughly match the resting bar's height so the transcript's viewport
    /// above matches the shape of the finished product visually.
    private let inputBarPlaceholder = NSView()

    /// Guard for `present(sessionId:)` before `view` has a real frame.
    /// The initial `present` call from `DetailFlowCoordinator.route(to:)`
    /// may arrive before `viewDidLayout` settles the mounted-child's
    /// frame; parking here and draining on the first framed `viewDidLayout`
    /// keeps the §2.19 single-width invariant intact.
    private var pendingSessionId: String?

    /// Whether the first attach has run against a framed view.
    /// `false` until `viewDidLayout` (or a `present(sessionId:)` on an
    /// already-framed view) drives the first `attachSession`; once true,
    /// subsequent `present` calls animate the crossfade the way a
    /// session→session swap should feel.
    private var didInitialAttach = false

    /// Owns the transcript-swap state machine (build / bind / anchor /
    /// crossfade / tear-down + the per-attach turn-usage + `isRunning`
    /// sinks). Lazy so it captures `view` after `loadView()` has run —
    /// `TranscriptSwapCoordinator` holds `container` `unowned`, and its
    /// lifetime is bounded by this VC's, so that's safe.
    private lazy var swapCoordinator: TranscriptSwapCoordinator = {
        TranscriptSwapCoordinator(
            container: view,
            context: detailContext,
            insertScroll: { [weak self] scroll in
                guard let self else { return }
                // Insert the transcript scroll BELOW the bottom input-bar
                // placeholder so the placeholder's rounded rect visually
                // floats above the transcript. When the AppKit input bar
                // lands in a follow-up PR it will replace this placeholder
                // and inherit its z-order.
                self.view.addSubview(
                    scroll, positioned: .below, relativeTo: self.inputBarPlaceholder)
            },
            onFirstScreenReady: { attachStart, sessionId in
                let ms = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
                appLog(
                    .info, "HistorySessionViewController",
                    "[firstScreen] sidebar→first view=\(String(format: "%.1f", ms))ms "
                        + "session=\(sessionId.prefix(8))…")
            }
        )
    }()

    init(detailContext: DetailContext) {
        self.detailContext = detailContext
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // The container's `NSVisualEffectView` paints the vibrancy backdrop
        // behind us; we're a plain transparent view that the transcript
        // scroll and input-bar placeholder pin into.
        let host = NSView()
        view = host

        inputBarPlaceholder.wantsLayer = true
        inputBarPlaceholder.layer?.cornerRadius = 12
        inputBarPlaceholder.layer?.backgroundColor =
            NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        inputBarPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(inputBarPlaceholder)

        let label = NSTextField(
            labelWithString: String(
                localized: "Input bar not yet migrated from SwiftUI"))
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        inputBarPlaceholder.addSubview(label)

        NSLayoutConstraint.activate([
            inputBarPlaceholder.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: 16),
            inputBarPlaceholder.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -16),
            inputBarPlaceholder.bottomAnchor.constraint(
                equalTo: host.bottomAnchor, constant: -16),
            inputBarPlaceholder.heightAnchor.constraint(equalToConstant: 68),

            label.centerXAnchor.constraint(equalTo: inputBarPlaceholder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: inputBarPlaceholder.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: inputBarPlaceholder.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: inputBarPlaceholder.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Drain a parked session id the moment the container settles our
        // frame — matches the old `DetailRouterViewController`'s
        // "first-framed viewDidLayout" trigger.
        guard !didInitialAttach,
            let sid = pendingSessionId,
            view.bounds.width > 0,
            view.bounds.height > 0
        else { return }
        didInitialAttach = true
        pendingSessionId = nil
        swapCoordinator.attachSession(sid, animated: false)
    }

    // MARK: - Imperative presentation (driven by the coordinator)

    /// Attach `sessionId`'s transcript. The coordinator calls this
    /// **after** it mounts + settles the child, so the attach runs
    /// against a real frame in the same source phase as the caller's
    /// event. When the view isn't framed yet (initial mount before
    /// `viewDidLayout` runs), the id parks in `pendingSessionId` and the
    /// attach rides the first framed `viewDidLayout`.
    func present(sessionId: String) {
        if view.bounds.width > 0, view.bounds.height > 0 {
            let wasFirstAttach = !didInitialAttach
            swapCoordinator.attachSession(sessionId, animated: !wasFirstAttach)
            didInitialAttach = true
            pendingSessionId = nil
        } else {
            pendingSessionId = sessionId
            // Left `didInitialAttach = false` so `viewDidLayout`'s
            // first-attach path runs when the frame lands.
        }
    }

    /// `DetailContainerChild` — the container calls this immediately
    /// before removing us on a cross-kind swap. Tear the transcript down
    /// deterministically so the scroll view, sheet presenter, and
    /// `isRunning` task release here rather than whenever ARC gets around
    /// to freeing the VC. Idempotent; safe to call repeatedly.
    func prepareForRemoval() {
        pendingSessionId = nil
        swapCoordinator.tearDownTranscript()
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 (matches every other `@MainActor` class in the
    /// codebase). The swap coordinator cancels its own `runningObservation`
    /// in its own `nonisolated deinit`, so this VC keeps no `Task` of its
    /// own and the body is empty.
    nonisolated deinit {}
}
