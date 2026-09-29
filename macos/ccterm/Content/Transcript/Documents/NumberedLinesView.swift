import AppKit

/// Lines of monospaced text with a tertiary line-number gutter — the body
/// of a command's output and of a file, read, created or changed
/// (02-command.md "Output", 03-file.md). Selectable, and searchable with ⌘F.
///
/// Shared by `CommandDocumentViewController` and
/// `SourceDocumentViewController`: they differ in what they put in the
/// lines — numbers, washes, change bars — not in how lines are set.
@MainActor
final class NumberedLinesView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
