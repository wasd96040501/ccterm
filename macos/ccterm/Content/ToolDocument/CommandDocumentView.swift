import AppKit
import TranscriptSource

/// A shell command over what it printed, in the source editor's own terms: the
/// command highlighted as shell, sized to its text up to a few lines, and the
/// output below as the terminal coloured it, what went to standard error in
/// red after what went to standard out.
@MainActor
final class CommandDocumentView: NSView {
    /// A long command scrolls inside this many lines.
    private static let maximumCommandLines = 6

    private let commandView: SourceView?
    private let outputView = SourceView()
    private let placeholder = NSTextField(labelWithString: String(localized: "No Output"))

    init(command: ToolDocument.Command) {
        commandView = command.command.map {
            SourceView(document: SourceDocument(text: $0, firstLine: nil, language: .shell))
        }
        super.init(frame: .zero)
        outputView.document = SourceDocument(terminalOutput: Self.terminalText(command))
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.isHidden = !(command.output.isEmpty && command.errorOutput.isEmpty)
        build(commandLines: command.command.map { $0.components(separatedBy: "\n").count } ?? 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Standard out, then standard error painted red the way a terminal would
    /// show it — so one view, one find, one selection covers both.
    private static func terminalText(_ command: ToolDocument.Command) -> String {
        let error = command.errorOutput.trimmingCharacters(in: .newlines)
        guard !error.isEmpty else { return command.output }
        let output = command.output.trimmingCharacters(in: .newlines)
        let painted = "\u{1B}[31m" + error + "\u{1B}[0m"
        return output.isEmpty ? painted : output + "\n" + painted
    }

    private func build(commandLines: Int) {
        var constraints: [NSLayoutConstraint] = []
        outputView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outputView)
        addSubview(placeholder)
        let outputTop: NSLayoutYAxisAnchor
        if let commandView {
            let separator = NSBox()
            separator.boxType = .separator
            for view in [commandView, separator] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            let height = SourceView.height(ofLines: min(max(commandLines, 1), Self.maximumCommandLines)) + 8
            constraints += [
                commandView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                commandView.leadingAnchor.constraint(equalTo: leadingAnchor),
                commandView.trailingAnchor.constraint(equalTo: trailingAnchor),
                commandView.heightAnchor.constraint(equalToConstant: height),
                separator.topAnchor.constraint(equalTo: commandView.bottomAnchor, constant: 4),
                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            outputTop = separator.bottomAnchor
        } else {
            outputTop = topAnchor
        }
        constraints += [
            outputView.topAnchor.constraint(equalTo: outputTop),
            outputView.leadingAnchor.constraint(equalTo: leadingAnchor),
            outputView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outputView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: outputView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: outputView.centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
    }
}
