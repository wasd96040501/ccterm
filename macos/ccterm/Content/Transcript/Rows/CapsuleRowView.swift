import AppKit

/// A command the user ran in the CLI — `/model opus`, `!git status` — as a
/// trailing capsule, with what it printed under it (05-local.md). Not a
/// bubble: the user set something, they didn't say it.
///
/// The capsule is 24 pt, outlined, unfilled; a `!` command that printed more
/// than a line says how long and opens its document beside on a click. Its
/// output sits under it, right-aligned in 11-pt tertiary — red when it went
/// to stderr — with *Show all* under a cut one.
@MainActor
final class CapsuleRowView: NSView, PageRowView {
    typealias Model = LocalCommand

    weak var delegate: PageRowViewDelegate?

    private static let capsuleHeight: CGFloat = 24
    private static let outputGap: CGFloat = 3
    private static let outputInset: CGFloat = 12
    /// A label's cell keeps 2 pt either side of its text.
    private static let cellPadding: CGFloat = 4
    private static let outputFont = NSFont.systemFont(ofSize: 11)
    /// A wrapped output never grows past this many lines.
    private static let outputLines = 4

    private let capsule = Capsule()
    private let output = NSTextField(wrappingLabelWithString: "")
    private let showAll = NSButton()
    private var outputHeight: NSLayoutConstraint!
    private var openID: String?
    private var opensFromCapsule = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)

        output.translatesAutoresizingMaskIntoConstraints = false
        output.font = Self.outputFont
        output.alignment = .right
        output.isSelectable = false
        output.maximumNumberOfLines = Self.outputLines
        output.lineBreakMode = .byWordWrapping
        addSubview(output)

        showAll.translatesAutoresizingMaskIntoConstraints = false
        showAll.isBordered = false
        showAll.attributedTitle = NSAttributedString(
            string: String(localized: "Show all"),
            attributes: [.font: Self.outputFont, .foregroundColor: NSColor.linkColor])
        showAll.target = self
        showAll.action = #selector(showAllClicked)
        addSubview(showAll)

        outputHeight = output.heightAnchor.constraint(equalToConstant: 0)
        let lineHeight = Self.lineHeight
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            capsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
            output.topAnchor.constraint(equalTo: capsule.bottomAnchor, constant: Self.outputGap),
            output.leadingAnchor.constraint(equalTo: leadingAnchor),
            output.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.outputInset - 2)),
            outputHeight,
            showAll.topAnchor.constraint(equalTo: output.bottomAnchor),
            showAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.outputInset - 4)),
            showAll.heightAnchor.constraint(equalToConstant: lineHeight),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Model

    static func height(for model: LocalCommand, width: CGFloat) -> CGFloat {
        var height = capsuleHeight
        if let text = model.inlineOutput {
            height += outputGap + outputTextHeight(text, width: width)
            if model.isOutputCut { height += lineHeight }
        }
        return height
    }

    func configure(with model: LocalCommand) {
        capsule.configure(with: model)
        opensFromCapsule = model.lineCount != nil
        openID = model.id
        if let text = model.inlineOutput {
            output.isHidden = false
            output.stringValue = text
            output.textColor = model.outputIsError ? .failureText : .tertiaryLabelColor
            outputHeight.constant = Self.outputTextHeight(text, width: bounds.width)
            showAll.isHidden = !model.isOutputCut
        } else {
            output.isHidden = true
            output.stringValue = ""
            showAll.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        // The output's height follows the width it wraps at, and is what
        // `height(for:width:)` measured.
        if !output.isHidden {
            outputHeight.constant = Self.outputTextHeight(output.stringValue, width: bounds.width)
        }
        super.layout()
    }

    // MARK: - Measuring

    private static var lineHeight: CGFloat { cell(for: "M", width: 1000).height }

    /// Measured with the cell the label draws with.
    private static func outputTextHeight(_ text: String, width: CGFloat) -> CGFloat {
        let wrapped = cell(for: text, width: max(width - outputInset + 2, 1)).height
        return min(wrapped, lineHeight * CGFloat(outputLines))
    }

    private static func cell(for text: String, width: CGFloat) -> NSSize {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = outputFont
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000))
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A press that opens a document stops here: the focus goes to it.
        if opensFromCapsule, let id = openID, capsule.frame.contains(point) {
            delegate?.pageRowView(self, didRequestDocument: id, pinned: event.clickCount == 2)
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func showAllClicked() {
        guard let id = openID else { return }
        delegate?.pageRowView(self, didRequestDocument: id, pinned: false)
    }

    // MARK: - The capsule

    /// The outlined pill: `⌘` or `$`, the command, and — for a `!` command
    /// that printed more than a line — how many, and `›`.
    private final class Capsule: NSView {
        private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        private let mark = NSTextField(labelWithString: "")
        private let words = NSTextField(labelWithString: "")
        private let count = NSTextField(labelWithString: "")
        private let chevron = NSImageView()
        private var isHovering = false
        private var isClickable = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = CapsuleRowView.capsuleHeight / 2
            layer?.borderWidth = 1

            mark.font = Self.font
            mark.textColor = .tertiaryLabelColor
            words.font = Self.font
            words.lineBreakMode = .byTruncatingTail
            words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            count.font = .systemFont(ofSize: 11)
            count.textColor = .tertiaryLabelColor
            chevron.image = .symbol("chevron.right", pointSize: 9, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor

            let stack = NSStackView(views: [mark, words, count, chevron])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func configure(with model: LocalCommand) {
            switch model.command {
            case .slash: mark.stringValue = "⌘"
            case .shell: mark.stringValue = "$"
            }
            let text = NSMutableAttributedString(
                string: model.title, attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])
            if !model.arguments.isEmpty {
                text.append(
                    NSAttributedString(
                        string: " " + model.arguments,
                        attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor]))
            }
            words.attributedStringValue = text
            toolTip = model.fullName
            count.stringValue = model.lineCount ?? ""
            count.isHidden = model.lineCount == nil
            chevron.isHidden = model.lineCount == nil
            isClickable = model.lineCount != nil
            refreshHover()
            needsDisplay = true
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.backgroundColor =
                    (isClickable && isHovering ? NSColor.quaternarySystemFill : .clear).cgColor
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
            refreshHover()
        }

        override func mouseEntered(with event: NSEvent) {
            isHovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
            needsDisplay = true
        }

        /// Entered and exited come only when the pointer moves; a capsule that
        /// slid under a still pointer, or out from under it, learns so here.
        private func refreshHover() {
            let hovering =
                if let window, window.isKeyWindow {
                    bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
                } else {
                    false
                }
            guard hovering != isHovering else { return }
            isHovering = hovering
            needsDisplay = true
        }
    }
}
