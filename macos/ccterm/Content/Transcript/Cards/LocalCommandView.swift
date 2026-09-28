import AppKit
import TranscriptSource

/// A command the user ran in the CLI and what it printed, as one card: the
/// command in the code face, then the first lines of its output, dimmer, each
/// cut at the card's edge. More than fits is counted at the foot; pressing the
/// card opens all of it beside the transcript.
@MainActor
final class LocalCommandView: CardSurfaceView {
    weak var delegate: TranscriptCardDelegate?

    private static let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let inputHeight: CGFloat = 18
    private static let outputLineHeight: CGFloat = 15
    private static let gap: CGFloat = 4
    private static let footerHeight: CGFloat = 16

    private let surface = PressableRowView()
    private let inputLabel = NSTextField(labelWithString: "")
    private var outputLabels: [NSTextField] = []
    private let footerLabel = NSTextField(labelWithString: "")
    private var command: LocalCommand?

    /// The card's height: fixed per line, since nothing wraps.
    static func height(for command: LocalCommand) -> CGFloat {
        var height = padding.top + padding.bottom
        if command.input != nil { height += inputHeight }
        let lines = command.previewLineCount
        if lines > 0 { height += (command.input != nil ? gap : 0) + CGFloat(lines) * outputLineHeight }
        if command.printedLineCount > LocalCommand.previewLimit { height += footerHeight }
        return height
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.highlightInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        addSubview(surface)
        for label in [inputLabel, footerLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            surface.addSubview(label)
        }
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        surface.onClick = { [weak self] clickCount in
            guard let self, let document = command?.document else { return }
            delegate?.card(self, open: document, pinned: clickCount > 1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with command: LocalCommand) {
        self.command = command
        surface.resetHighlight()
        surface.isPressable = command.document != nil
        inputLabel.attributedStringValue = Self.attributedInput(command)
        inputLabel.isHidden = command.input == nil

        let lines = Self.previewLines(command)
        while outputLabels.count < lines.count {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            surface.addSubview(label)
            outputLabels.append(label)
        }
        for (index, label) in outputLabels.enumerated() {
            label.isHidden = index >= lines.count
            guard index < lines.count else { continue }
            label.stringValue = lines[index].text
            label.textColor = lines[index].isError ? .systemRed : .secondaryLabelColor
        }
        let more = command.printedLineCount - command.previewLineCount
        footerLabel.stringValue = more == 1 ? String(localized: "1 more line") : String(localized: "\(more) more lines")
        footerLabel.isHidden = more <= 0
        surface.toolTip = command.input
        surface.setAccessibilityLabel(command.input ?? String(localized: "Command output"))
        needsLayout = true
    }

    private static func attributedInput(_ command: LocalCommand) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        if command.kind == .shell {
            text.append(
                NSAttributedString(
                    string: "$ ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        text.append(
            NSAttributedString(
                string: command.input ?? "", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return text
    }

    /// The output's first lines, escapes stripped, errors marked.
    private static func previewLines(_ command: LocalCommand) -> [(text: String, isError: Bool)] {
        let output = ANSIText.plainText(of: command.output).components(separatedBy: "\n").map { ($0, false) }
        let errors = ANSIText.plainText(of: command.errorOutput).components(separatedBy: "\n").map { ($0, true) }
        let all = (command.output.isEmpty ? [] : output) + (command.errorOutput.isEmpty ? [] : errors)
        return Array(all.prefix(command.previewLineCount)).map {
            (text: $0.0.replacingOccurrences(of: "\t", with: "    "), isError: $0.1)
        }
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let padding = Self.padding
        let width = bounds.width - padding.left - padding.right
        var y = padding.top
        if command?.input != nil {
            inputLabel.frame = NSRect(x: padding.left, y: y, width: width, height: Self.inputHeight)
            y += Self.inputHeight + Self.gap
        }
        for label in outputLabels where !label.isHidden {
            label.frame = NSRect(x: padding.left, y: y, width: width, height: Self.outputLineHeight)
            y += Self.outputLineHeight
        }
        footerLabel.frame = NSRect(x: padding.left, y: y, width: width, height: Self.footerHeight)
    }
}
