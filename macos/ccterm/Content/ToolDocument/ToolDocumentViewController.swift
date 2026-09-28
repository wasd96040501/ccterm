import AgentSDK
import AppKit
import TranscriptSource

/// An editor tab showing a ``ToolDocument``: a path bar over the document's
/// body.
///
/// Files, changes and plain text open in the source editor (Xcode's, read-
/// only); a change scrolls to its first hunk, and the bar's arrows step
/// through the rest. A command shows its text over its output. Prose — a
/// subagent's report, a plan — is set as the transcript sets it.
@MainActor
final class ToolDocumentViewController: NSViewController {
    let document: ToolDocument

    /// The transcript the document came from — what the window reports as
    /// being read while the tab is active.
    var transcriptURL: URL { document.id.transcript }

    private let pathBar = DocumentPathBar()
    private var sourceView: SourceView?
    private var markdownView: MarkdownDocumentView?
    /// The changes the arrows step through, and the one last stepped to.
    private var changes: [Range<Int>] = []
    private var currentChange = 0
    private var hasAppeared = false

    init(document: ToolDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        title = document.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let body = makeBody()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        view.addSubview(pathBar)
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: view.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if let path = document.path {
            pathBar.showPath(path)
        } else {
            pathBar.showTitle(document.title, symbol: document.symbol)
        }
        pathBar.setStatus(status())
        pathBar.setStepsChanges(changes.count > 1)
        pathBar.onStep = { [weak self] direction in self?.step(direction) }
    }

    /// The first change in view, once the editor has its size.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppeared else { return }
        hasAppeared = true
        view.layoutSubtreeIfNeeded()
        markdownView?.load()
        if !changes.isEmpty { sourceView?.scrollToChange(at: 0) }
    }

    // MARK: - Body

    private func makeBody() -> NSView {
        switch document.content {
        case .file(let path, let text, let firstLine):
            return source(SourceDocument(text: text, firstLine: firstLine, language: .forPath(path)))
        case .comparison(let path, let hunks, let original):
            let hunks = hunks.map {
                SourceDiffHunk(
                    oldStart: $0.oldStart, oldLines: $0.oldLines, newStart: $0.newStart, newLines: $0.newLines,
                    lines: $0.lines)
            }
            return source(SourceDocument(hunks: hunks, original: original, language: .forPath(path)))
        case .replacement(let path, let old, let new):
            return source(SourceDocument(old: old, new: new, firstLine: nil, language: .forPath(path)))
        case .command(let command):
            let view = CommandDocumentView(command: command)
            view.wantsLayer = true
            view.layer?.backgroundColor = SourceView.backgroundColor.cgColor
            return view
        case .markdown(let text):
            let view = MarkdownDocumentView(markdown: text)
            markdownView = view
            return view
        case .text(let text):
            return source(SourceDocument(text: text, language: .plainText))
        }
    }

    private func source(_ document: SourceDocument) -> SourceView {
        let view = SourceView(document: document)
        sourceView = view
        changes = document.changes
        return view
    }

    /// `+12 −3` for a change, how a command ended when it didn't succeed.
    private func status() -> NSAttributedString? {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        if case .command(let command) = document.content {
            let text: String
            let color: NSColor
            switch command.status {
            case .failed(let code?):
                (text, color) = (String(localized: "Exit Code \(code)"), .systemRed)
            case .failed(nil):
                (text, color) = (String(localized: "Failed"), .systemRed)
            case .interrupted:
                (text, color) = (String(localized: "Interrupted"), .secondaryLabelColor)
            case .running:
                (text, color) = (String(localized: "Running in Background"), .secondaryLabelColor)
            case .succeeded, .unknown:
                return nil
            }
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        guard let lines = sourceView?.document, !changes.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        if lines.insertions > 0 {
            result.append(
                NSAttributedString(
                    string: "+\(lines.insertions)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
        }
        if lines.deletions > 0 {
            if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            result.append(
                NSAttributedString(
                    string: "−\(lines.deletions)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        return result.length > 0 ? result : nil
    }

    // MARK: - Changes

    /// Steps to the change before or after the last one, wrapping at the ends
    /// as Xcode's does.
    private func step(_ direction: Int) {
        guard !changes.isEmpty else { return }
        currentChange = (currentChange + direction + changes.count) % changes.count
        sourceView?.scrollToChange(at: currentChange)
    }
}
