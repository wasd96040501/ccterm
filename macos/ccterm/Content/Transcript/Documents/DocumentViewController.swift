import AppKit

/// A tab beside the transcript: one document — a command, a file, a
/// subagent's conversation, words — under the jump bar every document has.
///
/// The shell only: it loads the document when it first appears (a tab made
/// again from editor history has only its reference), words the jump bar
/// from it (`DocumentHeader`), puts an approval bar under it while the call
/// waits for the reader, and embeds the body `DocumentBodyFactory` picks.
/// What a body shows is the body's.
@MainActor
final class DocumentViewController: NSViewController {
    /// Reads the document a reference names, or `nil` when it no longer
    /// exists; off the main actor.
    typealias Load = @Sendable (DocumentReference) async throws -> Document?

    let reference: DocumentReference

    weak var delegate: DocumentViewControllerDelegate?

    private let load: Load
    private let bodyFactory: DocumentBodyFactory
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false
    private var body: NSViewController?

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

    /// `title` names the tab until the document has loaded and its header
    /// says; a tab made from history has none to give.
    init(reference: DocumentReference, title: String?, load: @escaping Load, bodyFactory: DocumentBodyFactory) {
        self.reference = reference
        self.load = load
        self.bodyFactory = bodyFactory
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
        configureHierarchy()
        configureConstraints()
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
        guard !hasLoaded else { return }
        hasLoaded = true
        view.layoutSubtreeIfNeeded()
        let (reference, load) = (reference, load)
        loadTask = Task { [weak self] in
            let document = await Task.detached(priority: .userInitiated) { try? await load(reference) }.value
            guard !Task.isCancelled else { return }
            self?.show(document)
            self?.loadTask = nil
        }
    }

    /// Stops a load in flight, and the body's. The editor area calls it
    /// before the tab leaves the tree.
    func prepareForRemoval() {
        loadTask?.cancel()
        loadTask = nil
        (body as? TranscriptViewController)?.prepareForRemoval()
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
        if let waiting = Self.waitingCall(in: document.content) {
            approvalBar.configure(with: waiting)
            approvalBar.isHidden = false
        }
        embed(bodyFactory.body(for: document))
    }

    private func embed(_ body: NSViewController) {
        self.body = body
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

    /// The call a document is about, while it waits for the reader.
    private static func waitingCall(in content: DocumentContent) -> ToolCall? {
        let call: ToolCall? =
            switch content {
            case .command(let call), .newFile(let call), .read(let call), .search(let call), .web(let call),
                .agent(let call), .other(let call):
                call
            case .change(let calls): calls.last
            default: nil
            }
        guard let call, case .waiting = call.state else { return nil }
        return call
    }
}

extension DocumentViewController: JumpBarViewDelegate {
    func jumpBarViewShowInTranscript(_ jumpBar: JumpBarView) {
        delegate?.documentViewController(self, showInTranscript: reference)
    }
}

extension DocumentViewController: ApprovalBarViewDelegate {
    /// Answering a call is not wired to a live session yet.
    func approvalBarView(_ approvalBar: ApprovalBarView, decide decision: Decision, for callID: String) {
        appLog(.info, "DocumentViewController", "decision \(decision) for \(callID) — no live session")
    }
}
