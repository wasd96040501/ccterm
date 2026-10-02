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

    weak var tabDelegate: TranscriptTabDelegate? {
        didSet { transcript?.tabDelegate = tabDelegate }
    }

    /// The session this tab shows; `nil` while a draft.
    private(set) var transcriptURL: URL?

    private let context: TranscriptTab.Context
    private let composer = ComposerViewController()
    private var transcript: TranscriptViewController?
    private var newSession: NewSessionViewController?
    private var followTask: Task<Void, Never>?
    private var repositoryTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var catalog = ModelCatalog()
    private var preferences = LaunchPreferences()
    private var state: SessionState?

    // The draft.

    /// The New tab's choices; `nil` once it is a session.
    private var draft: NewSessionDraft?
    /// What is known of the draft's folder's repository.
    private var repository: NewSessionModel.Repository = .loading
    private var recentFolders: [URL] = []
    /// Whether the reader chose anything in this New tab (the folder, the
    /// branch, Worktree, a setting): it is worth keeping, not reusing.
    private var hasChosen = false
    /// Whether the reader chose a setting, so a catalog arriving later leaves it.
    private var hasChosenSettings = false
    /// Whether the draft's settings are the saved or the CLI's own, not the
    /// stand-in: the composer says *Loading…* until they are.
    private var draftSettingsAreKnown = false
    /// The words a New tab opens with, until the field has them.
    private var carriedText: String

    // Handing over.

    /// Sending: the field dims, the New view rises; nothing more is taken.
    private var isHandingOver = false
    /// The session a Send in a New tab started, from the Send until the swap
    /// (step 4) has the tab's own `transcriptURL`: what Stop cancels during the
    /// rise, and what the rise's completion checks it still belongs to.
    private var handoverURL: URL?
    /// The draft and the first prompt of the session this tab started, so that
    /// Stop while *Starting* can take them back.
    private var startedDraft: NewSessionDraft?
    private var firstPrompt: String?
    /// Prompts the CLI returned (*Stopped before it was read*) whose words are
    /// already back in the field.
    private var takenBack: Set<String> = []
    private var isWaitingRequestVisible = true

    // The composer's two places.

    private var draftConstraints: [NSLayoutConstraint] = []
    private var sessionConstraints: [NSLayoutConstraint] = []
    private var composerBottom: NSLayoutConstraint?
    private var composerWidth: NSLayoutConstraint?

    /// How far the floating composer stands from the tab's bottom edge.
    private static let floatGap: CGFloat = 16
    /// The floating composer's width.
    private static let composerWidth: CGFloat = 720

    init(_ start: Start, title: String, context: TranscriptTab.Context) {
        self.context = context
        carriedText = ""
        super.init(nibName: nil, bundle: nil)
        self.title = title
        switch start {
        case .draft(let folder, let text):
            carriedText = text
            draft = NewSessionDraft(folder: folder, settings: Self.placeholderSettings(catalog: catalog))
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
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        context.catalog
            .sink { [weak self] in
                self?.catalog = $0
                self?.catalogDidChange()
            }
            .store(in: &subscriptions)
        context.preferences
            .sink { [weak self] in
                self?.preferences = $0
                self?.refresh()
            }
            .store(in: &subscriptions)
        context.recentFolders
            .sink { [weak self] in
                self?.recentFolders = $0
                self?.recentFoldersDidChange()
            }
            .store(in: &subscriptions)
        if draft != nil {
            mountDraft()
        } else if let transcriptURL {
            showSession(at: transcriptURL, glidingFrom: nil)
        }
    }

    /// A New tab is ready to type in whenever it comes on screen.
    override func viewDidAppear() {
        super.viewDidAppear()
        if draft != nil { composer.focus() }
    }

    /// Gives the field the focus.
    func focusComposer() {
        composer.focus()
    }

    /// The floating composer's height is what the transcript scrolls clear of.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let transcript else { return }
        transcript.bottomInset = composer.cardHeight + Self.floatGap
    }

    // MARK: - What the window asks of a tab

    /// Whether this is a New tab no one has typed in or chosen anything in —
    /// ⌘T selects it instead of adding another.
    var isUntouchedDraft: Bool {
        draft != nil && !hasChosen && !isHandingOver && composer.text.isEmpty
    }

    /// A New tab's words, kept by the window when it closes for the next New
    /// tab; `nil` for a session's tab.
    var draftText: String? {
        draft != nil ? composer.text : nil
    }

    /// The folder this tab works in: the New tab's choice, or where the session
    /// it started runs; `nil` for a session opened from disk (the library knows).
    var folder: URL? {
        draft?.folder ?? startedDraft?.folder
    }

    /// Stops following. The editor area calls it before the tab leaves the tree.
    func prepareForRemoval() {
        followTask?.cancel()
        followTask = nil
        repositoryTask?.cancel()
        repositoryTask = nil
        subscriptions = []
        transcript?.prepareForRemoval()
    }

    /// Brings `itemID` back into view in the transcript, and flashes it.
    func reveal(_ itemID: String, select: Bool) {
        transcript?.reveal(itemID, select: select)
    }

    /// ⌘.: stops what Claude is doing, or the launch in progress. Sent to nil,
    /// so the window's menu reaches it from anywhere in the tab, and the split
    /// view controller hands it on from the sidebar.
    @objc func stopResponding(_ sender: Any?) {
        guard handoverURL != nil || state?.phase.canStop == true else { return }
        composerViewControllerDidRequestStop(composer)
    }

    // MARK: - The draft

    /// The New view in its slot, the composer in it.
    private func mountDraft() {
        let newSession = NewSessionViewController()
        newSession.delegate = self
        self.newSession = newSession
        addChild(newSession)
        let content = newSession.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content, positioned: .below, relativeTo: composer.view)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The composer fills the New view's slot, which takes the composer's height.
        let guide = newSession.composerGuide
        draftConstraints = [
            composer.view.topAnchor.constraint(equalTo: guide.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            guide.heightAnchor.constraint(equalTo: composer.view.heightAnchor),
        ]
        NSLayoutConstraint.activate(draftConstraints)
        if !carriedText.isEmpty { composer.text = carriedText }
        carriedText = ""
        newSession.setHintsVisible(composer.text.isEmpty)
        if let folder = draft?.folder { loadRepository(of: folder) }
        refresh()
    }

    private func unmountDraft() {
        NSLayoutConstraint.deactivate(draftConstraints)
        draftConstraints = []
        repositoryTask?.cancel()
        repositoryTask = nil
        if let newSession {
            newSession.view.removeFromSuperview()
            newSession.removeFromParent()
        }
        newSession = nil
    }

    /// The settings a New tab shows before any are known: the CLI's own once the
    /// catalog is read, else a stand-in the composer words as *Loading…*.
    private static func placeholderSettings(catalog: ModelCatalog) -> SessionSettings {
        SessionSettings(
            model: .default(on: catalog.subscription?.id ?? Self.unknownAccount), effort: nil,
            permissionMode: .default, fastMode: false)
    }

    /// The account of the stand-in settings, before any is known.
    private static let unknownAccount = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// A catalog arriving gives a New tab nothing the reader chose over — the
    /// defaults, or the CLI's own — until they choose.
    private func catalogDidChange() {
        if draft != nil, !hasChosenSettings {
            let resolved = context.defaults.settings(catalog: catalog)
            draft?.settings = resolved ?? Self.placeholderSettings(catalog: catalog)
            draftSettingsAreKnown = resolved != nil
        }
        refresh()
    }

    private func recentFoldersDidChange() {
        // A New tab with no folder yet, and nothing chosen, starts in the most
        // recent project once the sidebar knows one.
        if var draft, draft.folder == nil, !hasChosen, let first = recentFolders.first {
            draft.choose(folder: first)
            self.draft = draft
            loadRepository(of: first)
        }
        refresh()
    }

    /// Reads the repository of `folder` off the main actor; the branch row says
    /// *loading* until it answers.
    private func loadRepository(of folder: URL) {
        repositoryTask?.cancel()
        repository = .loading
        let branches = context.branches
        repositoryTask = Task { [weak self] in
            let state = await branches.repository(at: folder)
            guard let self, !Task.isCancelled, self.draft?.folder == folder else { return }
            self.repository = state.map { .repository($0) } ?? .notARepository
            self.refresh()
        }
    }

    private var repositoryState: RepositoryState? {
        if case .repository(let state) = repository { state } else { nil }
    }

    /// Draws what changed: the New view and the composer from the draft, or the
    /// composer from the session's state.
    private func refresh() {
        guard isViewLoaded else { return }
        if let draft {
            newSession?.configure(
                with: NewSessionModel(draft: draft, repository: repository, recentFolders: recentFolders))
            composer.configure(
                with: ComposerModel(
                    ComposerModel.Input(
                        context: handoverURL == nil
                            ? .draft
                            : .session(phase: .starting, isWaitingForYou: false, isWaitingRequestVisible: true),
                        settings: draftSettingsAreKnown ? draft.settings : nil,
                        pendingModel: nil, pendingFastMode: nil, catalog: catalog,
                        allowsBypassPermissions: preferences.allowsBypassPermissions, contextUsage: nil,
                        refusal: nil, commands: commands(for: draft.settings))))
        } else {
            configureComposer()
        }
    }

    /// What `/` completes in a New tab: the account's commands the model runs on.
    private func commands(for settings: SessionSettings) -> [SlashCommand] {
        catalog.account(settings.model.account)?.commands ?? catalog.subscription?.commands ?? []
    }

    // MARK: - Send in a New tab

    /// The handover (see the type's documentation): the session starts at once,
    /// the page rises, then the tab becomes the session's.
    private func send(_ text: String, from draft: NewSessionDraft) {
        guard !isHandingOver, let launch = draft.launch(in: repositoryState) else {
            // Without a folder there is nothing to launch: the words stay.
            composer.text = text
            return
        }
        isHandingOver = true
        // 1. The URL at once; the words stay in the field, dimmed.
        let url = context.sessions.start(launch, prompt: text)
        handoverURL = url
        composer.text = text
        composer.isFieldDimmed = true
        startedDraft = draft
        firstPrompt = text
        // 2. The page rises, then 3 to 6.
        guard let newSession else {
            completeHandover(to: url)
            return
        }
        // The composer already says *Starting Claude…* with Stop to cancel.
        refresh()
        newSession.rise { [weak self] in
            self?.completeHandover(to: url)
        }
    }

    /// Stop during the rise: the launch is cancelled, the rise's completion
    /// will do nothing, and the tab stays the draft with the words in the
    /// field. The coordinator was never told, so there is nothing to undo.
    private func cancelHandover(at url: URL) {
        _ = context.sessions.cancelLaunch(at: url)
        handoverURL = nil
        isHandingOver = false
        startedDraft = nil
        firstPrompt = nil
        composer.isFieldDimmed = false
        refresh()
        composer.focus()
    }

    private func completeHandover(to url: URL) {
        guard transcriptURL == nil, handoverURL == url else { return }
        handoverURL = nil
        // 3. Where the composer is, in the window, before anything moves.
        let captured = composer.view.convert(composer.view.bounds, to: nil)
        // 4. The coordinator re-identifies the tab, before anything else changes.
        transcriptURL = url
        title = SessionTabTitle.fromPrompt(firstPrompt ?? "")
        draft = nil
        tabDelegate?.transcriptTab(self, didStartSessionAt: url)
        // 5. The New view goes, the transcript comes, the composer moves down.
        unmountDraft()
        composer.text = ""
        composer.isFieldDimmed = false
        showSession(at: url, glidingFrom: captured)
    }

    // MARK: - The session

    /// Mounts the transcript and the composer under it and follows the
    /// session. `captured`: where the composer stood in the New view, window
    /// coordinates, when this tab has just started the session — it glides from
    /// there.
    private func showSession(at url: URL, glidingFrom captured: NSRect?) {
        let transcript = TranscriptViewController(fileURL: url, title: title ?? "", sessions: context.sessions)
        transcript.tabDelegate = tabDelegate
        transcript.delegate = self
        self.transcript = transcript
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view, positioned: .below, relativeTo: composer.view)
        let bottom = composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.floatGap)
        // 720 at most, 16 from each side when the tab is narrower.
        let width = composer.view.widthAnchor.constraint(equalToConstant: Self.composerWidth)
        width.priority = .defaultHigh
        composerBottom = bottom
        composerWidth = width
        sessionConstraints = [
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottom,
            composer.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            composer.view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.composerWidth),
            composer.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * Self.floatGap),
            width,
        ]
        NSLayoutConstraint.activate(sessionConstraints)
        followSession(at: url, transcript: transcript)
        guard let captured else { return }
        view.layoutSubtreeIfNeeded()
        glide(from: captured)
    }

    /// 6. The composer glides from where it stood to its place: 0.3 s, ease-out,
    /// the position and the width as constraint constants — the card itself
    /// doesn't relayout differently as it goes. Reduce Motion: it fades in at
    /// its place.
    private func glide(from captured: NSRect) {
        let target = composer.view.convert(composer.view.bounds, to: nil)
        composer.isFieldDimmed = false
        composer.focus()
        guard let bottom = composerBottom, let width = composerWidth, captured != .zero else {
            isHandingOver = false
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            composer.view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                composer.view.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                self?.isHandingOver = false
            }
            return
        }
        // Window coordinates grow upward and the engine's constants downward.
        bottom.constant = -Self.floatGap - (captured.minY - target.minY)
        width.constant = captured.width
        view.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bottom.animator().constant = -Self.floatGap
            width.animator().constant = Self.composerWidth
        } completionHandler: { [weak self] in
            self?.isHandingOver = false
        }
    }

    private func followSession(at url: URL, transcript: TranscriptViewController) {
        let states = context.sessions.states(at: url)
        followTask = Task { [weak self] in
            do {
                for try await state in states {
                    guard let self, !Task.isCancelled else { return }
                    self.state = state
                    transcript.show(state)
                    self.applyTitle(of: state)
                    self.takeBackReturnedPrompts(of: state, at: url)
                    self.configureComposer()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                transcript.showUnreadable()
            }
        }
    }

    /// The tab's name: the CLI's once it has one, else the first prompt's line
    /// for a session started here; a session read from disk keeps its own.
    private func applyTitle(of state: SessionState) {
        let resolved = SessionTabTitle.resolved(cli: state.title, prompt: firstPrompt, fallback: title ?? "")
        if title != resolved { title = resolved }
    }

    /// A prompt the CLI took back before it read it (*Stopped before it was
    /// read*) is in the transcript nowhere: its words go back in the field and
    /// the store forgets it.
    private func takeBackReturnedPrompts(of state: SessionState, at url: URL) {
        for prompt in state.prompts where prompt.delivery == .returned && !takenBack.contains(prompt.id) {
            takenBack.insert(prompt.id)
            putBack(prompt.text)
            context.sessions.dismiss(prompt: prompt.id, at: url)
        }
    }

    /// `words` after what the field already holds, on their own line.
    private func putBack(_ words: String) {
        composer.text = composer.text.isEmpty ? words : composer.text + "\n" + words
        composer.focus()
    }

    private func configureComposer() {
        guard let state else { return }
        let settings = state.settings ?? context.defaults.settings(catalog: catalog)
        composer.configure(
            with: ComposerModel(
                ComposerModel.Input(
                    context: .session(
                        phase: state.phase, isWaitingForYou: !state.requests.isEmpty,
                        isWaitingRequestVisible: isWaitingRequestVisible),
                    settings: settings, pendingModel: state.pendingModel, pendingFastMode: state.pendingFastMode,
                    catalog: catalog, allowsBypassPermissions: preferences.allowsBypassPermissions,
                    contextUsage: state.contextUsage, refusal: state.refusal, commands: state.commands)))
    }

    // MARK: - Back to the draft

    /// The launch this tab started was stopped before it began: the New view
    /// again, the draft as it was sent, the words in the field.
    private func returnToDraft(words: String) {
        guard let startedDraft, transcriptURL != nil else { return }
        followTask?.cancel()
        followTask = nil
        state = nil
        if let transcript {
            transcript.prepareForRemoval()
            transcript.view.removeFromSuperview()
            transcript.removeFromParent()
        }
        transcript = nil
        NSLayoutConstraint.deactivate(sessionConstraints)
        sessionConstraints = []
        composerBottom = nil
        composerWidth = nil
        transcriptURL = nil
        draft = startedDraft
        self.startedDraft = nil
        firstPrompt = nil
        title = SessionTabTitle.draft
        isHandingOver = false
        composer.isFieldDimmed = false
        mountDraft()
        composer.text = words
        newSession?.setHintsVisible(words.isEmpty)
        composer.focus()
        tabDelegate?.transcriptTabDidReturnToDraft(self)
    }

    // MARK: - Opening beside

    /// Opens `document` as a tab beside this one, pinned.
    private func open(_ document: Document) {
        guard let delegate = tabDelegate else { return }
        let sessions = context.sessions
        delegate.transcriptTab(
            self, didRequestOpen: .document(document.reference), pinned: true,
            makeItem: { TranscriptTab.makeDocumentItem(document, sessions: sessions, delegate: delegate) })
    }

    // MARK: - Choices

    private func choose(_ change: SessionSettings.Change, inDraft draft: NewSessionDraft) {
        var next = draft
        next.settings = draft.settings.applying(change, catalog: catalog)
        self.draft = next
        hasChosen = true
        hasChosenSettings = true
        draftSettingsAreKnown = true
        context.defaults.save(next.settings)
        refresh()
    }

    private func confirmRestart(_ change: SessionSettings.Change, at url: URL) {
        guard case .model(let choice) = change, let window = view.window else { return }
        let phase = state?.phase
        let isWorking = phase == .responding || phase == .compacting || phase == .starting
        let confirmation = RestartConfirmation(
            accountName: catalog.account(choice.account)?.name ?? "",
            modelName: catalog.model(choice)?.displayName ?? choice.value, isWorking: isWorking)
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: confirmation.cancelTitle)
        if confirmation.cancelIsDefault {
            // Return must not throw away a turn.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.context.sessions.update(change, at: url)
        }
    }
}

extension SessionTabViewController: ComposerViewControllerDelegate {
    func composerViewController(_ composerViewController: ComposerViewController, didSubmit text: String) {
        if let transcriptURL {
            guard !isHandingOver else { return }
            context.sessions.send(text, to: transcriptURL)
        } else if let draft {
            send(text, from: draft)
        }
    }

    func composerViewControllerDidRequestStop(_ composerViewController: ComposerViewController) {
        if transcriptURL == nil, let handoverURL {
            cancelHandover(at: handoverURL)
            return
        }
        guard let transcriptURL else { return }
        guard state?.phase == .starting else {
            context.sessions.interrupt(at: transcriptURL)
            return
        }
        // Stop while *Starting* cancels the launch and takes the prompts back.
        let returned = context.sessions.cancelLaunch(at: transcriptURL)
        if startedDraft != nil {
            returnToDraft(words: returned.isEmpty ? firstPrompt ?? "" : returned.joined(separator: "\n"))
        } else {
            for words in returned { putBack(words) }
        }
    }

    func composerViewController(
        _ composerViewController: ComposerViewController, didChoose change: SessionSettings.Change
    ) {
        if let draft {
            choose(change, inDraft: draft)
            return
        }
        guard let transcriptURL else { return }
        let timing = state?.timing(of: change) ?? .atLaunch
        if timing == .restart {
            confirmRestart(change, at: transcriptURL)
        } else {
            context.sessions.update(change, at: transcriptURL)
        }
    }

    func composerViewControllerDidRequestRestart(_ composerViewController: ComposerViewController) {
        guard let transcriptURL else { return }
        context.sessions.restart(at: transcriptURL)
    }

    func composerViewControllerDidRequestLog(_ composerViewController: ComposerViewController) {
        guard let transcriptURL, case .failed(let failure)? = state?.phase else { return }
        open(SessionTabDocuments.log(failure, transcriptURL: transcriptURL))
    }

    func composerViewControllerDidRequestWaitingRequest(_ composerViewController: ComposerViewController) {
        transcript?.revealWaitingRequest()
    }

    func composerViewControllerDidRequestContextUsage(_ composerViewController: ComposerViewController) {
        guard let transcriptURL, let report = state?.contextReport else { return }
        open(SessionTabDocuments.context(report, transcriptURL: transcriptURL))
    }

    func composerViewControllerDidChangeText(_ composerViewController: ComposerViewController) {
        newSession?.setHintsVisible(composerViewController.text.isEmpty)
    }
}

extension SessionTabViewController: TranscriptViewControllerDelegate {
    func transcriptViewController(
        _ transcriptViewController: TranscriptViewController, didChangeWaitingRequestVisibility isVisible: Bool
    ) {
        guard isWaitingRequestVisible != isVisible else { return }
        isWaitingRequestVisible = isVisible
        configureComposer()
    }

    func transcriptViewControllerDidRequestComposer(_ transcriptViewController: TranscriptViewController) {
        composer.focus()
    }
}

extension SessionTabViewController: NewSessionViewControllerDelegate {
    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL) {
        guard var draft else { return }
        draft.choose(folder: url)
        self.draft = draft
        hasChosen = true
        loadRepository(of: url)
        refresh()
    }

    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranch branch: NewSessionDraft.Branch
    ) {
        guard var draft, let repository = repositoryState else { return }
        draft.choose(branch: branch, in: repository)
        self.draft = draft
        hasChosen = true
        refresh()
    }

    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController) {
        guard var draft, let repository = repositoryState else { return }
        draft.toggleWorktree(in: repository)
        self.draft = draft
        hasChosen = true
        refresh()
    }
}

extension SessionState.Phase {
    /// Whether ⌘. has something to stop: a launch, a turn, a compaction.
    fileprivate var canStop: Bool {
        switch self {
        case .starting, .responding, .compacting: true
        case .atRest, .idle, .failed: false
        }
    }
}
