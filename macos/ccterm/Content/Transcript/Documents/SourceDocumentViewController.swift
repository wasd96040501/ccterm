import AppKit
import Components

/// What Edit, Write and Read open beside the transcript: Xcode's source
/// editor, read-only, in three modes (design/transcript/03-file.md).
///
/// The lines are `SourceLines`'; this draws them in a `NumberedLinesView` —
/// washes for a change, the green bar of a new file, the file map of a read.
@MainActor
final class SourceDocumentViewController: NSViewController {
    enum Mode {
        /// One file's edits in one run, as one unified change.
        case change([ToolCall])
        case newFile(ToolCall)
        case read(ToolCall)
    }

    private let mode: Mode

    private lazy var linesView = NumberedLinesView()

    init(_ mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = linesView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let (source, path, bar): (SourceLines, String?, ChangeBar?) =
            switch mode {
            case .change(let calls): (SourceLines.change(calls), calls.first?.filePath, .hunks)
            case .newFile(let call): (SourceLines.newFile(call), call.filePath, .wholeFile)
            case .read(let call): (SourceLines.read(call), call.filePath, nil)
            }
        var content = NumberedLinesView.Content(
            lines: source.lines.map { Self.line($0, path: path) }, style: .source, bar: bar)
        if case .read = mode, let slice = source.slice, slice.total > 0 {
            content.fileMap = .init(
                start: Double(slice.first - 1) / Double(slice.total),
                length: Double(slice.last - slice.first + 1) / Double(slice.total))
        }
        // The first change a third of the way down, not at the top.
        content.revealLine = source.firstChange
        if !source.notes.isEmpty { linesView.header = Self.notes(source.notes) }
        linesView.configure(with: content)
    }

    private static func line(_ line: SourceLines.Line, path: String?) -> NumberedLinesView.Line {
        switch line.kind {
        case .fold:
            return NumberedLinesView.Line(kind: .fold, text: line.text)
        case .context, .added, .removed:
            let kind: NumberedLinesView.Line.Kind =
                switch line.kind {
                case .added: .added
                case .removed: .removed
                default: .text
                }
            return NumberedLinesView.Line(
                kind: kind, number: line.number, text: line.text,
                spans: SyntaxHighlighter.spans(in: line.text, path: path), changed: line.changed)
        }
    }

    /// `info.circle` and red `xmark.octagon` notes above the first hunk.
    private static func notes(_ notes: [SourceLines.Note]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 61, bottom: 6, right: 16)
        for note in notes {
            let isError = note.style == .error
            let image = NSImageView(
                image: NSImage(
                    systemSymbolName: isError ? "xmark.octagon" : "info.circle", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
            image.contentTintColor = isError ? .failureText : .secondaryLabelColor
            let label = NSTextField(wrappingLabelWithString: note.text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = isError ? .failureText : .secondaryLabelColor
            label.isSelectable = true
            let row = NSStackView(views: [image, label])
            row.spacing = 6
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
            row.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -16).isActive = true
        }
        return stack
    }
}
