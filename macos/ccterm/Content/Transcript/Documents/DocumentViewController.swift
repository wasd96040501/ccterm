import AgentSDK
import AppKit

/// A tab beside the transcript: one document — a command, a file, a
/// subagent's conversation, words — under the jump bar every document has.
///
/// The shell only: it shows the document when it first appears — at once if
/// it was handed one (a tab made again from editor history has only its
/// reference, and reads it) — and follows it while its call is still going
/// (`Document.isLive`); words the tab and the jump bar from it
/// (`DocumentHeader`); puts an approval bar under it while the call waits
/// for the reader; and embeds the body it picks (`makeBody(for:)`). What a
/// body shows is the body's.
@MainActor
final class DocumentViewController: NSViewController {
    /// The document as it stands in its transcript, then each change — the
    /// page already built, off the main actor; `nil` when the transcript
    /// doesn't have it (any more). One value for a transcript at rest.
    typealias DocumentLoader = @MainActor (DocumentReference) -> AsyncStream<Document?>

    private let reference: DocumentReference

    /// What the reader opened, until it is shown.
    private var document: Document?
    private let loadDocument: DocumentLoader
    private let showInTranscript: @MainActor (DocumentReference) -> Void
    /// Answers the call waiting on the reader: the approval bar's decision.
    private let decide: @MainActor (Decision, String) -> Void
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
    /// from history — the tab has no title until `load` gives it.
    /// `makeConversation` makes the transcript tab a subagent's conversation
    /// opens as; `showInTranscript` is *Show in Transcript*; `decide` answers
    /// the call (decision, call id).
    init(
        reference: DocumentReference, document: Document? = nil,
        load: @escaping DocumentLoader,
        makeConversation: @escaping @MainActor (URL, String) -> NSViewController,
        showInTranscript: @escaping @MainActor (DocumentReference) -> Void,
        decide: @escaping @MainActor (Decision, String) -> Void
    ) {
        self.reference = reference
        self.document = document
        loadDocument = load
        self.showInTranscript = showInTranscript
        self.decide = decide
        self.makeConversation = makeConversation
        super.init(nibName: nil, bundle: nil)
        title = document.map { DocumentHeader($0).title }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = FocusableView()
        configureHierarchy()
        configureConstraints()
    }

    /// The tab's own view takes the focus when the reader opens the document,
    /// as a tab view does: the window's commands (⌘W, ⌘F) then aim at this
    /// tab. A click inside moves it to what was clicked.
    private final class FocusableView: NSView {
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
        var shown = false
        if let document {
            self.document = nil
            show(document)
            // A settled document never changes: nothing to follow, nothing to read.
            guard document.isLive else { return }
            shown = true
        }
        let documents = loadDocument(reference)
        loadTask = Task { [weak self] in
            for await document in documents {
                guard let self, !Task.isCancelled else { return }
                if shown {
                    update(document)
                } else {
                    show(document)
                    shown = true
                }
            }
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

    /// Shows the document again as its live session changed it — its call
    /// finished, its approval answered; nothing if it didn't change.
    private func update(_ document: Document?) {
        // TODO(live): compare with what is shown; re-word the jump bar, show
        // or hide the approval bar, and swap the body when its content changed.
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
    func jumpBarViewDidRequestShowInTranscript(_ jumpBar: JumpBarView) {
        showInTranscript(reference)
    }
}

extension DocumentViewController: ApprovalBarViewDelegate {
    func approvalBarView(_ approvalBar: ApprovalBarView, didDecide decision: Decision, forCall callID: String) {
        decide(decision, callID)
    }
}
