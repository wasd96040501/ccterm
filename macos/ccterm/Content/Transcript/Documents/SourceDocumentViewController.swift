import AppKit

/// What Edit, Write and Read open beside the transcript: Xcode's source
/// editor, read-only, in three modes (design/transcript/03-file.md).
@MainActor
final class SourceDocumentViewController: NSViewController {
    enum Mode {
        /// One file's edits in one run, as one unified change.
        case change([ToolCall])
        case newFile(ToolCall)
        case read(ToolCall)
    }

    private let mode: Mode

    init(_ mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }
}
