import AppKit

/// What a Bash call — or a `!` command the user ran — opens beside the
/// transcript: a page, not a terminal. What was meant, what ran, what came
/// out (design/transcript/02-command.md).
@MainActor
final class CommandDocumentViewController: NSViewController {
    enum Command {
        case call(ToolCall)
        case local(LocalCommand)
    }

    private let command: Command

    init(_ command: Command) {
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }
}
