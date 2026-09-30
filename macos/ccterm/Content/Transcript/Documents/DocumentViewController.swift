import AgentSDK
import AppKit

/// A tab beside the transcript: one document — a command, a file, a
/// subagent's conversation, words — under the jump bar every document has.
///
/// The shell only: it reads the document from its transcript when it first
/// appears, unless it was handed one (a tab made again from editor history
/// has only its reference); words the tab and the jump bar from it
/// (`DocumentHeader`); puts an approval bar under it while the call waits
/// for the reader; and embeds the body it picks (`makeBody(for:)`). What a
/// body shows is the body's.
@MainActor
final class DocumentViewController: NSViewController {
    /// Reads one document — the transcript's page already built, off the main
    /// actor — or `nil` when the transcript no longer has it.
    typealias DocumentLoader = @Sendable (DocumentReference) async -> Document?

    private let reference: DocumentReference

    /// What the reader opened, until it is shown.
    private var document: Document?
    private let loadDocument: DocumentLoader
    private let showInTranscript: @MainActor (DocumentReference) -> Void
    /// A transcript tab for the conversation at a URL, titled — this module
    /// doesn't know the transcript view controller.
    private let makeConversation: @MainActor (URL, String) -> NSViewController
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false

    private lazy var jumpBar: JumpBarView = {
        let bar = JumpBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    private lazy var approvalBar: ApprovalBarView = {
        let bar = ApprovalBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        return bar
    }()

    /// Where the body goes, under the bars.
    private lazy var bodyArea: NSView = {
        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        return area
    }()

    private lazy var bars: NSStackView = {
        let stack = NSStackView(views: [jumpBar, approvalBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var note: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    /// `document` is what the reader just opened; without one — a tab made
    /// from history — the shell reads it with `load`, and the tab has no title
    /// until then. `makeConversation` makes the transcript tab a subagent's
    /// conversation opens as; `showInTranscript` is *Show in Transcript*.
    init(
        reference: DocumentReference, document: Document? = nil,
        load: @escaping DocumentLoader,
        makeConversation: @escaping @MainActor (URL, String) -> NSViewController,
        showInTranscript: @escaping @MainActor (DocumentReference) -> Void
    ) {
        self.reference = reference
        self.document = document
        loadDocument = load
        self.showInTranscript = showInTranscript
        self.makeConversation = makeConversation
        super.init(nibName: nil, bundle: nil)
        title = document.map { DocumentHeader($0).title }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = TabView()
        configureHierarchy()
        configureConstraints()
    }

    /// The tab's own view takes the focus when the reader opens the document,
    /// as a tab view does: the window's commands (⌘W, ⌘F) then aim at this
    /// tab. A click inside moves it to what was clicked.
    private final class TabView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Whether the tab takes the focus once it is in a window.
    private var takesFocusWhenShown = false

    /// Gives the reader's focus to this tab, now or as soon as it is in a
    /// window: they just opened it.
    func takeFocus() {
        guard let window = view.window else {
            takesFocusWhenShown = true
            return
        }
        takesFocusWhenShown = false
        window.makeFirstResponder(view)
    }

    private func configureHierarchy() {
        view.addSubview(bars)
        view.addSubview(bodyArea)
        view.addSubview(note)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bars.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            jumpBar.widthAnchor.constraint(equalTo: bars.widthAnchor),
            jumpBar.heightAnchor.constraint(equalToConstant: JumpBarView.height),
            approvalBar.widthAnchor.constraint(equalTo: bars.widthAnchor),
            bodyArea.topAnchor.constraint(equalTo: bars.bottomAnchor),
            bodyArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            note.centerXAnchor.constraint(equalTo: bodyArea.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: bodyArea.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        jumpBar.delegate = self
        approvalBar.delegate = self
    }

    /// Loads once, when the tab first appears and has its size — a body
    /// that measures (a transcript) is mounted into a laid-out area.
    override func viewDidAppear() {
        super.viewDidAppear()
        if takesFocusWhenShown { takeFocus() }
        guard !hasLoaded else { return }
        hasLoaded = true
        view.layoutSubtreeIfNeeded()
        if let document {
            self.document = nil
            show(document)
            return
        }
        let (reference, loadDocument) = (reference, loadDocument)
        loadTask = Task { [weak self] in
            let document = await loadDocument(reference)
            guard !Task.isCancelled else { return }
            self?.show(document)
            self?.loadTask = nil
        }
    }

    /// Stops the document's load in flight. The editor area calls it before
    /// the tab leaves the tree; a body with work of its own is the caller's to
    /// stop — it made it (`makeConversation`).
    func prepareForRemoval() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Showing

    private func show(_ document: Document?) {
        guard let document else {
            note.stringValue = String(localized: "This document is no longer in the transcript.")
            note.isHidden = false
            appLog(.warning, "DocumentViewController", "no document for \(reference.id)")
            return
        }
        let header = DocumentHeader(document)
        title = header.title
        jumpBar.configure(with: header)
        if let approval = document.approval {
            approvalBar.configure(with: approval)
            approvalBar.isHidden = false
        }
        embed(makeBody(for: document))
    }

    /// The view controller that shows a document under its jump bar — the one
    /// place a kind of document meets its body.
    ///
    /// A subagent's work opens as its conversation — the transcript it wrote —
    /// when that file is on disk, and as its report in markdown otherwise.
    private func makeBody(for document: Document) -> NSViewController {
        switch document.content {
        case .command(let call):
            return CommandDocumentViewController(.call(call))
        case .shellCommand(let command):
            return CommandDocumentViewController(.local(command))
        case .change(let calls):
            return SourceDocumentViewController(.change(calls))
        case .newFile(let call):
            return SourceDocumentViewController(.newFile(call))
        case .read(let call):
            return SourceDocumentViewController(.read(call))
        case .agent(let call):
            if let agentID = call.agentID {
                let url = document.reference.conversationURL(ofAgent: agentID)
                if FileManager.default.fileExists(atPath: url.path) {
                    return makeConversation(url, DocumentHeader(document).title)
                }
            }
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        case .agentMessage, .search, .web, .taskList, .news, .commandOutput, .compactionSummary, .other:
            return MarkdownDocumentViewController(markdown: DocumentMarkdown.markdown(for: document.content))
        }
    }

    private func embed(_ body: NSViewController) {
        addChild(body)
        body.view.translatesAutoresizingMaskIntoConstraints = false
        bodyArea.addSubview(body.view)
        NSLayoutConstraint.activate([
            body.view.topAnchor.constraint(equalTo: bodyArea.topAnchor),
            body.view.leadingAnchor.constraint(equalTo: bodyArea.leadingAnchor),
            body.view.trailingAnchor.constraint(equalTo: bodyArea.trailingAnchor),
            body.view.bottomAnchor.constraint(equalTo: bodyArea.bottomAnchor),
        ])
    }
}

extension DocumentViewController: JumpBarViewDelegate {
    func jumpBarViewShowInTranscript(_ jumpBar: JumpBarView) {
        showInTranscript(reference)
    }
}

extension DocumentViewController: ApprovalBarViewDelegate {
    /// Answering a call is not wired to a live session yet.
    func approvalBarView(_ approvalBar: ApprovalBarView, decide decision: Decision, for callID: String) {
        appLog(.info, "DocumentViewController", "decision \(decision) for \(callID) — no live session")
    }
}
