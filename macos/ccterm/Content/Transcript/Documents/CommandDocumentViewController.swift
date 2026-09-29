import AppKit

/// What a Bash call — or a `!` command the user ran — opens beside the
/// transcript: a page, not a terminal. What was meant, what ran, what came
/// out (design/transcript/02-command.md).
///
/// The words are `CommandSummary`'s; the page is a `NumberedLinesView` whose
/// header holds what was meant and what ran, so everything scrolls as one and
/// the output is findable and selectable.
@MainActor
final class CommandDocumentViewController: NSViewController {
    enum Command {
        case call(ToolCall)
        case local(LocalCommand)
    }

    private let command: Command

    private lazy var linesView: NumberedLinesView = {
        let view = NumberedLinesView()
        return view
    }()

    init(_ command: Command) {
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = linesView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let summary: CommandSummary =
            switch command {
            case .call(let call): CommandSummary(call)
            case .local(let local): CommandSummary(local)
            }
        linesView.header = CommandHeaderView(summary: summary)
        linesView.configure(with: NumberedLinesView.Content(lines: Self.lines(of: summary), style: .output))
    }

    /// stdout numbered, then stderr under its heading — only when it has text.
    private static func lines(of summary: CommandSummary) -> [NumberedLinesView.Line] {
        var lines = ANSIText(summary.stdout).lines.map {
            NumberedLinesView.Line(
                number: 0, text: $0.text, spans: $0.spans, numberIsError: CommandSummary.isErrorLine($0.text))
        }
        for index in lines.indices { lines[index].number = index + 1 }
        let errors = ANSIText(summary.stderr).lines
        if !errors.isEmpty {
            lines.append(NumberedLinesView.Line(kind: .divider, text: "stderr"))
            lines += errors.enumerated().map {
                NumberedLinesView.Line(
                    number: $0.offset + 1, text: $0.element.text, spans: $0.element.spans, numberIsError: true)
            }
        }
        return lines
    }
}
