import AppKit

/// Detail child mounted for a non-draft `MainSelection.session(_)`.
/// A thin container: it hosts a `TranscriptViewController` (the outline
/// transcript) as a child VC and reserves space at the bottom for the
/// input bar (a placeholder view in this refactor; the SwiftUI
/// `InputBarView2` migration lands in a follow-up PR).
///
/// It no longer touches `Session` / `SessionRuntime` / `SessionManager`
/// or the old `TranscriptSwapCoordinator` — history is read one-shot
/// through the injected `TranscriptHistoryService` inside the store the
/// transcript VC owns (SPEC §6.5). The `.history` route in
/// `DetailFlowCoordinator` is unchanged.
///
/// Attach ordering follows the same "settle before present" contract the
/// transcript needs: `present(sessionId:)` must run against a framed
/// `view` so the outline typesets each row at one width. When the id
/// arrives before `viewDidLayout` has settled the frame (initial mount),
/// it parks in `pendingSessionId` and the attach runs on the first
/// framed layout.
@MainActor
final class HistorySessionViewController: NSViewController, DetailContainerChild {
    /// The outline transcript, mounted via containment.
    private let transcriptViewController: TranscriptViewController

    /// Bottom-anchored placeholder occupying the space the SwiftUI input
    /// bar (`InputBarView2`) will fill when it lands as AppKit.
    private let inputBarPlaceholder = NSView()

    /// Guard for `present(sessionId:)` before `view` has a real frame.
    private var pendingSessionId: String?

    /// Whether the first attach has run against a framed view.
    private var didInitialAttach = false

    init(historySource: TranscriptHistoryService.Type) {
        let store = TranscriptStore(historySource: historySource)
        self.transcriptViewController = TranscriptViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let host = NSView()
        view = host

        // Mount the transcript VC as a child, filling the pane. Its scroll
        // view's own content insets reserve the top/bottom bands, so the
        // input-bar placeholder floats on top of the transcript's viewport.
        addChild(transcriptViewController)
        let transcript = transcriptViewController.view
        transcript.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(transcript)

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
            transcript.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: host.topAnchor),
            transcript.bottomAnchor.constraint(equalTo: host.bottomAnchor),

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
        guard !didInitialAttach,
            let sid = pendingSessionId,
            view.bounds.width > 0,
            view.bounds.height > 0
        else { return }
        didInitialAttach = true
        pendingSessionId = nil
        transcriptViewController.present(sessionId: sid)
    }

    // MARK: - Imperative presentation (driven by the coordinator)

    /// Attach `sessionId`'s transcript. Runs immediately when the view is
    /// framed; otherwise parks the id and attaches on the first framed
    /// `viewDidLayout`.
    func present(sessionId: String) {
        if view.bounds.width > 0, view.bounds.height > 0 {
            transcriptViewController.present(sessionId: sessionId)
            didInitialAttach = true
            pendingSessionId = nil
        } else {
            pendingSessionId = sessionId
        }
    }

    /// `DetailContainerChild` — called immediately before the container
    /// removes us on a cross-kind swap. The transcript's store holds no
    /// live subscriptions / timers (one-shot load), so there is nothing
    /// to tear down beyond dropping a parked id.
    func prepareForRemoval() {
        pendingSessionId = nil
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26 (matches every other `@MainActor` class here).
    nonisolated deinit {}
}
