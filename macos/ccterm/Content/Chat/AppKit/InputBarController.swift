import AppKit
import Observation
import UniformTypeIdentifiers

/// AppKit replacement for the `ChatComposeHostRoot → ChatComposeStack →
/// ChatRestingBar → InputBarChrome → InputBarView2` chain (migration plan
/// §4.0, §4.1) — the SPINE. A child `NSViewController` of
/// `ChatSessionViewController` (NOT a `DetailRouterChild`), created ONCE in
/// `loadView` and rebound in place via `rebind(sessionId:)` (the AppKit
/// analogue of SwiftUI's `.id(sid)` reset — reset the model fields, never
/// rebuild the view). It is the `NSTextViewDelegate` and the owner of the
/// reused-verbatim `CompletionState` / `InputDraftStore` glue / the session
/// observation sinks.
///
/// SCOPE NOTE: this is the spine only. The completion popup VIEW
/// (`CompletionPopupView`, §4.3) and the attachment thumbnail strip are
/// co-delivered components; this controller already owns the `CompletionState`
/// and feeds `checkTrigger` from both delegate paths + routes key nav, but
/// the popup's height plugs into `InputBarView.extraPillContentHeight` later.
@MainActor
final class InputBarController: NSViewController, NSTextViewDelegate {

    // MARK: - Injected dependencies

    private let sessionManager: SessionManager
    private let inputDraftStore: InputDraftStore
    /// User defaults the `sendKeyBehavior` value is read from + observed on
    /// (D2). Injected (`UserDefaults(suiteName:)` in tests) — never
    /// `.standard` directly so the observation is parallel-safe.
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter

    /// Forwarded to the completion trigger context (`/new`, `/clear`).
    private let onBuiltinCommand: ((BuiltinSlashCommand) -> Void)?
    /// Called with the snapshotted `Submission` AND the bound session id, so
    /// the chat VC can forward to `submitSessionInput`. The controller knows
    /// its own session id, so it always supplies it.
    private let onSubmit: (Submission, String) -> Void
    /// External send gate beyond text/attachment. `true` for the chat resting
    /// bar; compose passes a closure reading `session.cwd != nil`. Re-evaluated
    /// on every relevant change (`session.cwd` observation re-fires it).
    private let submitEnabledProvider: (Session) -> Bool
    /// Auto-focus the text field once the bar is windowed (draft-landing).
    /// The chat resting bar + compose card leave this false.
    private let autofocus: Bool

    // MARK: - Bound session state

    private var boundSessionId: String?
    private var boundSession: Session?
    /// The key the persisted draft is loaded/saved under. In chat mode this
    /// coincides with `boundSessionId`; in compose mode it is the stable
    /// `InputDraftStore.newSessionKey` ("__new_session__") so the draft
    /// survives the lazily-allocated `draftSessionId` regenerating — the
    /// indirection the original `InputBarChrome.draftKey` preserved
    /// (`ComposeSessionViewController.swift:150`). Decoupled from the
    /// `onSubmit` session id (always `boundSessionId`) on purpose.
    private var boundDraftKey: String?

    /// View-private completion interaction state machine (REUSED VERBATIM).
    let completion = CompletionState()

    /// Owned model fields (the SwiftUI `@State` analogues). `text` is read
    /// from `textView.string`; attachments are held here for `canSend` /
    /// draft save. The attachment strip view consumes `attachments` later.
    private(set) var attachments: [Attachment] = []

    /// True while the controller is performing a programmatic write
    /// (draft restore, completion splice, handleSend clear) so the delegate
    /// methods early-return — the AppKit home of the deleted Coordinator's
    /// `isUpdatingText` guard (§4.1-6a).
    private var isApplyingProgrammaticText = false

    // MARK: - Observation tasks / tokens

    private var draftLoadTask: Task<Void, Never>?
    private var isRunningObservationActive = false
    private var cwdObservationActive = false
    private var prewarmObservationActive = false
    private var lastPrewarmKey: CompletionPrewarmer.Key?
    private var sendKeyObserver: NSObjectProtocol?

    // MARK: - The view

    /// The hand-laid pill. Exposed so the chat VC can read it for the
    /// regime-B host constraints + scrim anchor wiring.
    private(set) var barView: InputBarView!

    // MARK: - Init

    /// Production init. The chat / compose / draft hosts call this.
    init(
        sessionManager: SessionManager,
        inputDraftStore: InputDraftStore,
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        autofocus: Bool = false,
        onBuiltinCommand: ((BuiltinSlashCommand) -> Void)? = nil,
        submitEnabledProvider: @escaping (Session) -> Bool = { _ in true },
        onSubmit: @escaping (Submission, String) -> Void
    ) {
        self.sessionManager = sessionManager
        self.inputDraftStore = inputDraftStore
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        self.autofocus = autofocus
        self.onBuiltinCommand = onBuiltinCommand
        self.submitEnabledProvider = submitEnabledProvider
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - Lifecycle

    override func loadView() {
        let bar = InputBarView()
        bar.textView.delegate = self
        bar.sendStopButton.onSend = { [weak self] in self?.handleSend() }
        bar.sendStopButton.onStop = { [weak self] in self?.boundSession?.interrupt() }
        bar.attachButton.onPick = { [weak self] in self?.presentPicker() }
        // Window-gated autofocus from a guaranteed hook: a child VC added after
        // its parent already appeared may never get a fresh `viewDidAppear`,
        // so also focus when the bar first lands in a window (plan §4.1-5).
        bar.onDidMoveToWindow = { [weak self] in self?.focusIfNeeded() }
        wireTextCallbacks(on: bar.textView, scroll: bar.textScrollView)
        barView = bar
        view = bar

        applySendKeyBehavior()
        observeSendKeyBehavior()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusIfNeeded()
    }

    /// Teardown hook called from `ChatSessionViewController.prepareForRemoval()`.
    /// Cancel-and-dismiss only — NO relayout/async work that would perturb an
    /// in-flight transcript swap's disabled `CATransaction` (plan §4.0, R16).
    func prepareForRemoval() {
        draftLoadTask?.cancel()
        draftLoadTask = nil
        completion.dismiss()
        isRunningObservationActive = false
        cwdObservationActive = false
        prewarmObservationActive = false
        if let token = sendKeyObserver {
            notificationCenter.removeObserver(token)
            sendKeyObserver = nil
        }
    }

    // MARK: - Rebind in place (plan §4.0, §4.1-5/6)

    /// Reset the bar's model fields to the new session, in place. Ordering
    /// (plan §4.1): cancel in-flight draft-load → resign focus → reset state →
    /// resolve session → re-arm observation → start draft load → (after load)
    /// focus if autofocus.
    ///
    /// - Parameters:
    ///   - sessionId: the session resolved + handed to `onSubmit`.
    ///   - draftKey: the key the persisted draft is loaded/saved under. Defaults
    ///     to `sessionId` (chat mode); compose passes
    ///     `InputDraftStore.newSessionKey` so the draft outlives the
    ///     regenerating `draftSessionId`.
    func rebind(sessionId: String, draftKey: String? = nil) {
        loadViewIfNeeded()
        let resolvedDraftKey = draftKey ?? sessionId

        // (1) cancel in-flight draft-load.
        draftLoadTask?.cancel()
        draftLoadTask = nil

        // (2) resign first responder if currently focused.
        if view.window?.firstResponder === barView.textView {
            view.window?.makeFirstResponder(nil)
        }

        // (3) reset model fields in place.
        applyProgrammatic { barView.textView.string = "" }
        attachments = []
        completion.dismiss()
        barView.extraPillContentHeight = 0
        barView.relayout()

        // (4) resolve the new Session (idempotent get-or-create).
        boundSessionId = sessionId
        boundDraftKey = resolvedDraftKey
        let session = sessionManager.prepareDraftSession(sessionId)
        boundSession = session

        // (5) re-arm isRunning + cwd + prewarmKey observation.
        startRunningObservation(for: session)
        startCwdObservation(for: session)
        startPrewarmObservation(for: session)

        // Reflect the resolved session immediately.
        barView.sendStopButton.setRunning(session.isRunning, animated: false)
        updateSubmitEnabled()
        firePrewarmIfChanged(for: session)

        // (6) start draft load keyed on the draft key.
        startDraftLoad(key: resolvedDraftKey)

        // (7) focus is fired from viewDidAppear / after draft load via
        //     focusIfNeeded (window-gated).
        focusIfNeeded()
    }

    // MARK: - canSend (plan §4.1, verbatim from InputBarView2.canSend)

    var canSend: Bool {
        guard let session = boundSession else { return false }
        guard submitEnabledProvider(session) else { return false }
        let trimmed = barView.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !attachments.isEmpty
    }

    private func updateSubmitEnabled() {
        barView?.sendStopButton.updateEnabled(canSend)
    }

    // MARK: - handleSend (plan §4.1-4 — draft-clear BEFORE onSubmit)

    func handleSend() {
        guard canSend, let sessionId = boundSessionId else { return }
        let trimmed = barView.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        var images: [(data: Data, mediaType: String)] = []
        var filePaths: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image(let data, let mediaType):
                images.append((data: data, mediaType: mediaType))
            case .file(let path):
                filePaths.append(path)
            }
        }
        let submission = Submission(text: trimmed, images: images, filePaths: filePaths)

        // Clear local state AND the persisted draft BEFORE onSubmit — onSubmit
        // flips selection and tears this VC down synchronously in the same
        // source phase, so there is no later reactive hook to clear the draft.
        // The draft is keyed on `boundDraftKey` (the compose newSessionKey in
        // compose mode), NOT the onSubmit session id.
        applyProgrammatic { barView.textView.string = "" }
        attachments = []
        completion.dismiss()
        barView.extraPillContentHeight = 0
        barView.relayout()
        if let draftKey = boundDraftKey { inputDraftStore.clear(draftKey) }
        updateSubmitEnabled()

        onSubmit(submission, sessionId)
    }

    // MARK: - Draft load / save

    private func startDraftLoad(key: String) {
        draftLoadTask = Task { [weak self] in
            guard let store = self?.inputDraftStore else { return }
            let draft = await store.load(sessionId: key)
            guard !Task.isCancelled, let self else { return }
            defer { self.focusIfNeeded() }
            guard let draft else { return }
            // Empty-guard: never clobber in-flight input typed before the
            // async read returned.
            guard self.barView.textView.string.isEmpty, self.attachments.isEmpty else { return }
            self.applyProgrammatic { self.barView.textView.string = draft.text }
            self.attachments = draft.filePaths.map { Self.restoreFileAttachment(path: $0) }
            self.barView.relayout()
            self.updateSubmitEnabled()
        }
    }

    private func scheduleDraftSave() {
        guard let key = boundDraftKey else { return }
        let filePaths: [String] = attachments.compactMap { attachment in
            if case .file(let path) = attachment.kind { return path }
            return nil
        }
        inputDraftStore.save(
            InputDraft(text: barView.textView.string, filePaths: filePaths, updatedAt: Date()),
            for: key)
    }

    /// Rehydrate a `.file` attachment from a persisted path (verbatim from
    /// `InputBarView2.restoreFileAttachment`).
    private static func restoreFileAttachment(path: String) -> Attachment {
        let url = URL(fileURLWithPath: path)
        let icon = NSWorkspace.shared.icon(forFile: path)
        return Attachment(kind: .file(path: path), thumbnail: icon, filename: url.lastPathComponent)
    }

    // MARK: - Session observation (re-armed withObservationTracking)

    private func startRunningObservation(for session: Session) {
        isRunningObservationActive = true
        observeRunning(session)
    }

    private func observeRunning(_ session: Session) {
        withObservationTracking {
            _ = session.isRunning
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.isRunningObservationActive, self.boundSession === session
                else { return }
                self.barView.sendStopButton.setRunning(session.isRunning)
                self.updateSubmitEnabled()
                self.observeRunning(session)
            }
        }
    }

    private func startCwdObservation(for session: Session) {
        cwdObservationActive = true
        observeCwd(session)
    }

    private func observeCwd(_ session: Session) {
        withObservationTracking {
            _ = session.cwd
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.cwdObservationActive, self.boundSession === session
                else { return }
                self.updateSubmitEnabled()
                self.observeCwd(session)
            }
        }
    }

    private func startPrewarmObservation(for session: Session) {
        prewarmObservationActive = true
        observePrewarm(session)
    }

    private func observePrewarm(_ session: Session) {
        withObservationTracking {
            _ = session.cwd
            _ = session.additionalDirectories
            _ = session.pluginDirectories
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.prewarmObservationActive, self.boundSession === session
                else { return }
                self.firePrewarmIfChanged(for: session)
                self.observePrewarm(session)
            }
        }
    }

    private func firePrewarmIfChanged(for session: Session) {
        let key = CompletionPrewarmer.Key(
            directory: session.cwd,
            additionalDirs: session.additionalDirectories,
            pluginDirs: session.pluginDirectories)
        guard key != lastPrewarmKey else { return }
        lastPrewarmKey = key
        CompletionPrewarmer.prewarm(key)
    }

    // MARK: - sendKeyBehavior wiring (D2, plan §4.1-6)

    private func applySendKeyBehavior() {
        let raw = userDefaults.string(forKey: "sendKeyBehavior")
        let behavior = raw.flatMap(SendKeyBehavior.init(rawValue:)) ?? .commandEnter
        // `UserDefaults.didChangeNotification` carries no key info and (on the
        // production `.standard` defaults) fires for ANY default write
        // app-wide — a firehose on the bar's hot path. Re-set only when the
        // parsed value actually changed so the broadcast doesn't thrash the
        // text view's property.
        guard barView?.textView.sendKeyBehavior != behavior else { return }
        barView?.textView.sendKeyBehavior = behavior
    }

    private func observeSendKeyBehavior() {
        sendKeyObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySendKeyBehavior() }
        }
    }

    // MARK: - Autofocus (plan §4.1-5 — window-gated)

    private func focusIfNeeded() {
        guard autofocus, let window = view.window else { return }
        if window.firstResponder !== barView.textView {
            window.makeFirstResponder(barView.textView)
        }
    }

    // MARK: - Attach picker (plan §4.1-10)

    private func presentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose a file to attach")
        let completion: ([URL]) -> Void = { [weak self] urls in
            guard let self else { return }
            for url in urls { self.attachPickedURL(url) }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        } else {
            panel.begin { response in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        }
    }

    // MARK: - Attach dispatch (verbatim logic from InputBarView2)

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif",
    ]

    func attachPickedURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            attachImage(at: url)
        } else {
            attachFile(at: url)
        }
    }

    private func attachImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let thumb = NSImage(data: data) ?? NSImage()
        appendAttachment(
            Attachment(
                kind: .image(data: data, mediaType: mediaType(for: url)),
                thumbnail: thumb, filename: url.lastPathComponent))
    }

    private func attachFile(at url: URL) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appendAttachment(
            Attachment(kind: .file(path: url.path), thumbnail: icon, filename: url.lastPathComponent))
    }

    private func appendAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
        // Attachment add/remove animates the pill grow/shrink at .smooth(0.35)
        // (matching `InputBarView2`'s `.animation(_, value: attachments.isEmpty)`).
        barView.relayout(animated: true)
        updateSubmitEnabled()
        scheduleDraftSave()
    }

    private func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "image/png"
    }

    // MARK: - NSTextViewDelegate (plan §4.1-6/7)

    func textDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticText else { return }
        if barView.textView.hasMarkedText() { return }
        barView.textScrollView.updateIntrinsicHeight()
        updateSubmitEnabled()
        scheduleDraftSave()
        feedCompletion()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingProgrammaticText else { return }
        if barView.textView.hasMarkedText() { return }
        // Pure caret move feeds completion too (§4.1-7) so the popup
        // dismisses / re-evaluates when the caret arrows into/out of a token.
        feedCompletion()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscape()
            return true
        }
        return false
    }

    private func feedCompletion() {
        completion.checkTrigger(
            text: barView.textView.string,
            cursorLocation: barView.textView.selectedRange().location,
            // D4: pass the LIVE hasMarkedText so trigger detection is
            // suppressed during IME composition.
            hasMarkedText: barView.textView.hasMarkedText(),
            context: triggerContext)
    }

    private var triggerContext: CompletionTriggerContext {
        let session = boundSession
        return CompletionTriggerContext(
            directory: session?.cwd,
            additionalDirs: session?.additionalDirectories ?? [],
            pluginDirs: session?.pluginDirectories ?? [],
            knownSlashCommands: (session?.slashCommands.isEmpty ?? true) ? nil : session?.slashCommands,
            onBuiltinCommand: onBuiltinCommand)
    }

    // MARK: - Key handling (plan §4.1 — completion priority)

    /// Wire the text view's send-key + key-interceptor callbacks. The
    /// interceptor runs BEFORE the send-key switch (`InputTextView.swift:268`)
    /// so it swallows plain Return / Tab while a completion is active.
    private func wireTextCallbacks(on textView: InputNSTextView, scroll: InputTextScrollView) {
        textView.onCommandReturn = { [weak self] in
            guard let self else { return }
            // Guard the confirm at the decision point: never fire
            // `confirmSelection()` (which dispatches the builtin side effect +
            // dismisses) while IME marked text is present, since the splice
            // (`applyReplacement`) would be suppressed — leaving text and the
            // dispatched command out of sync. The live keyDown path already
            // blocks the interceptor on `hasMarkedText`; match it here so the
            // controller-level path is robust regardless of caller.
            if self.completion.isActive, !self.barView.textView.hasMarkedText(),
                let result = self.completion.confirmSelection()
            {
                self.applyReplacement(result)
                return
            }
            self.handleSend()
        }
        textView.onInterceptKeyDown = { [weak self] event in
            self?.handleCompletionKey(event) ?? false
        }
        textView.onMarkedTextChanged = { [weak self] in
            self?.barView.textView.needsDisplay = true
            scroll.updateIntrinsicHeight()
        }
    }

    private func handleEscape() {
        if completion.isActive {
            completion.dismiss()
            return
        }
        if boundSession?.isRunning == true {
            boundSession?.interrupt()
        }
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard completion.isActive else { return false }
        switch event.keyCode {
        case 126:  // Up
            completion.moveSelectionUp()
            return true
        case 125:  // Down
            completion.moveSelectionDown()
            return true
        case 48, 36:  // Tab or Return — confirm.
            // Don't confirm (and don't fire `onItemConfirmed` / dismiss) while
            // IME marked text is present — the splice would be suppressed.
            // Still swallow the key so it doesn't insert a tab/newline.
            guard !barView.textView.hasMarkedText() else { return true }
            if let result = completion.confirmSelection() {
                applyReplacement(result)
            }
            return true
        default:
            return false
        }
    }

    /// Splice `result.replacement` into the text at `result.range`, then move
    /// the cursor to the end of the inserted text. Wrapped in the programmatic
    /// guard so the delegate methods (which the splice's `textDidChange` +
    /// `textViewDidChangeSelection` fire) early-return (§4.3-4). Replaces the
    /// deleted `desiredCursorPosition` consume-once binding.
    private func applyReplacement(_ result: (range: NSRange, replacement: String)) {
        guard !barView.textView.hasMarkedText() else { return }
        let ns = barView.textView.string as NSString
        guard result.range.location >= 0,
            result.range.location + result.range.length <= ns.length
        else { return }
        let end = result.range.location + (result.replacement as NSString).length
        applyProgrammatic {
            barView.textView.insertText(result.replacement, replacementRange: result.range)
            barView.textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        barView.textScrollView.updateIntrinsicHeight()
        barView.relayout()
        updateSubmitEnabled()
        scheduleDraftSave()
    }

    // MARK: - Programmatic-write guard

    private func applyProgrammatic(_ body: () -> Void) {
        isApplyingProgrammaticText = true
        body()
        isApplyingProgrammaticText = false
    }
}
