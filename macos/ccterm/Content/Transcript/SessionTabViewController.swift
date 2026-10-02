import AgentSDK
import AppKit
import Combine

/// A session's own tab — or a New tab, which becomes one at Send (design 08:
/// *before the first prompt it's a form, after it's a conversation*).
///
/// A container of three children: the New view (`NewSessionViewController`,
/// while a draft), the transcript (`TranscriptViewController`, once there is
/// a session) and the composer (`ComposerViewController`, always — one
/// instance, which moves). As a draft the composer sits in the New view's
/// `composerGuide`; on a session it floats 16 pt above the tab's bottom edge,
/// 720 pt at most, and the transcript scrolls under it (`bottomInset`).
///
/// It is the only one in the tab that talks to the stores: it follows the
/// session once (`SessionStore.states(at:)`) and hands each state to the
/// transcript and, worded as a `ComposerModel`, to the composer; it turns the
/// composer's intents into the draft's changes or the store's verbs.
///
/// **Send in a New tab** hands over in this order, so nothing jumps:
/// 1. `sessions.start(launch, prompt:)` — the URL at once, the CLI launching;
///    the field's words stay, dimmed.
/// 2. `newSession.rise` (600 ms; at once under Reduce Motion).
/// 3. The composer's frame is captured in window coordinates.
/// 4. `tabDelegate.transcriptTab(self, didStartSessionAt:)` — the coordinator
///    re-identifies the tab (or moves this controller from the empty area into
///    the first tab) synchronously, and updates the window's title and the
///    sidebar itself: the active controller is the same object, so the editor
///    area reports no activation.
/// 5. The New view goes; the transcript comes, showing the held prompt; the
///    composer moves to the bottom; `view.layoutSubtreeIfNeeded()`.
/// 6. The composer glides from the captured frame to its place (0.3 s,
///    ease-out; Reduce Motion: a cross-fade).
///
/// **Stop while Starting** a session this tab just started takes the held
/// prompt back (`cancelLaunch`), returns to the draft with the words in the
/// field, and tells the coordinator (`transcriptTabDidReturnToDraft`).
@MainActor
final class SessionTabViewController: NSViewController {
    /// What a tab opens as.
    enum Start {
        /// A New tab: the folder to start in (`nil`: none known) and the words
        /// carried from a New tab closed before.
        case draft(folder: URL?, text: String)
        /// A session's tab.
        case session(URL)
    }

    weak var tabDelegate: TranscriptTabDelegate?

    /// The session this tab shows; `nil` while a draft.
    private(set) var transcriptURL: URL?

    private let context: TranscriptTab.Context
    private let composer = ComposerViewController()
    private var transcript: TranscriptViewController?
    private var newSession: NewSessionViewController?
    private var draft: NewSessionDraft?
    private var followTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var catalog = ModelCatalog()
    private var preferences = LaunchPreferences()
    private var state: SessionState?

    init(_ start: Start, title: String, context: TranscriptTab.Context) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        self.title = title
        switch start {
        case .draft(let folder, let text):
            // TODO(fill E): settings from context.defaults; the New view; `text` into the field.
            _ = (folder, text)
        case .session(let url):
            transcriptURL = url
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.delegate = self
        context.catalog.sink { [weak self] in self?.catalog = $0 }.store(in: &subscriptions)
        context.preferences.sink { [weak self] in self?.preferences = $0 }.store(in: &subscriptions)
        if let transcriptURL { showSession(at: transcriptURL) }
    }

    /// Whether this is a New tab no one has typed in or chosen anything in —
    /// ⌘T selects it instead of adding another.
    var isUntouchedDraft: Bool {
        // TODO(fill E): no text, no command token, no choice made.
        transcriptURL == nil && composer.text.isEmpty
    }

    /// A New tab's words, kept by the window when it closes for the next New
    /// tab; `nil` for a session's tab.
    var draftText: String? {
        transcriptURL == nil ? composer.text : nil
    }

    /// Stops following. The editor area calls it before the tab leaves the tree.
    func prepareForRemoval() {
        followTask?.cancel()
        followTask = nil
        subscriptions = []
        transcript?.prepareForRemoval()
    }

    /// Brings `itemID` back into view in the transcript, and flashes it.
    func reveal(_ itemID: String, select: Bool) {
        transcript?.reveal(itemID, select: select)
    }

    // MARK: - The session

    /// Mounts the transcript and the composer under it and follows the
    /// session.
    // TODO(fill E): the floating card, `bottomInset`, the composer model.
    private func showSession(at url: URL) {
        let transcript = TranscriptViewController(fileURL: url, title: title ?? "", sessions: context.sessions)
        transcript.tabDelegate = tabDelegate
        transcript.delegate = self
        self.transcript = transcript
        addChild(transcript)
        addChild(composer)
        for child in [transcript.view, composer.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.topAnchor.constraint(equalTo: transcript.view.bottomAnchor),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let states = context.sessions.states(at: url)
        followTask = Task { [weak self] in
            do {
                for try await state in states {
                    guard let self, !Task.isCancelled else { return }
                    self.state = state
                    transcript.show(state)
                    configureComposer()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                transcript.showUnreadable()
            }
        }
    }

    private func configureComposer() {
        guard let state else { return }
        // TODO(fill E): the settings at rest come from the transcript; a session
        // with none yet uses the defaults.
        let settings =
            state.settings
            ?? SessionSettings(
                model: .default(on: UUID()), effort: nil, permissionMode: .default, fastMode: false)
        composer.configure(
            with: ComposerModel(
                ComposerModel.Input(
                    context: .session(
                        phase: state.phase, isWaitingForYou: !state.requests.isEmpty, isWaitingRequestVisible: true),
                    settings: settings, pendingModel: state.pendingModel, pendingFastMode: state.pendingFastMode,
                    catalog: catalog, allowsBypassPermissions: preferences.allowsBypassPermissions,
                    contextUsage: state.contextUsage, refusal: state.refusal, commands: state.commands)))
    }
}

extension SessionTabViewController: ComposerViewControllerDelegate {
    func composerViewController(_ composerViewController: ComposerViewController, didSubmit text: String) {
        guard let transcriptURL else {
            // TODO(fill E): Send in a New tab — the handover above.
            return
        }
        context.sessions.send(text, to: transcriptURL)
    }

    func composerViewControllerDidRequestStop(_ composerViewController: ComposerViewController) {
        guard let transcriptURL else { return }
        // TODO(fill E): while starting, `cancelLaunch` and the words back (and,
        // for a session started here, back to the draft).
        context.sessions.interrupt(at: transcriptURL)
    }

    func composerViewController(
        _ composerViewController: ComposerViewController, didChoose change: SessionSettings.Change
    ) {
        // TODO(fill E): a draft applies it (`SessionSettings.applying`) and saves
        // the defaults; a session asks `timing(of:)` — `.restart` confirms with
        // an NSAlert sheet first (design 08 *Another account restarts*) — then
        // `sessions.update`.
    }

    func composerViewControllerDidRequestRestart(_ composerViewController: ComposerViewController) {
        guard let transcriptURL else { return }
        context.sessions.restart(at: transcriptURL)
    }

    func composerViewControllerDidRequestLog(_ composerViewController: ComposerViewController) {
        // TODO(fill E): the failure's log beside, as a monospaced document.
    }

    func composerViewControllerDidRequestWaitingRequest(_ composerViewController: ComposerViewController) {
        transcript?.revealWaitingRequest()
    }

    func composerViewControllerDidRequestContextUsage(_ composerViewController: ComposerViewController) {
        // TODO(fill E): `/context` beside.
    }

    func composerViewControllerDidChangeText(_ composerViewController: ComposerViewController) {
        newSession?.setHintsVisible(composerViewController.text.isEmpty)
    }
}

extension SessionTabViewController: TranscriptViewControllerDelegate {
    func transcriptViewController(
        _ transcriptViewController: TranscriptViewController, didChangeWaitingRequestVisibility isVisible: Bool
    ) {
        // TODO(fill E): into the composer model.
    }

    func transcriptViewControllerDidRequestComposer(_ transcriptViewController: TranscriptViewController) {
        composer.focus()
    }
}

extension SessionTabViewController: NewSessionViewControllerDelegate {
    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL) {
        // TODO(fill E)
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranch branch: NewSessionDraft.Branch
    ) {
        // TODO(fill E)
    }

    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController) {
        // TODO(fill E)
    }
}
