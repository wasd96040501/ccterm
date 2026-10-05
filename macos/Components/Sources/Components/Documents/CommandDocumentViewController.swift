import AppKit
import DisplayModels

/// What a Bash call — or a `!` command the user ran — opens beside the
/// transcript: a page, not a terminal. What was meant, what ran, what came
/// out (design/transcript/02-command.md).
///
/// The words are `CommandSummary`'s; the page is a `NumberedLinesView` whose
/// header holds what was meant and what ran, so everything scrolls as one and
/// the output is findable and selectable.
@MainActor
public final class CommandDocumentViewController: NSViewController {
    private let summary: CommandSummary

    private lazy var linesView = NumberedLinesView()

    public init(_ summary: CommandSummary) {
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        view = linesView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
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
