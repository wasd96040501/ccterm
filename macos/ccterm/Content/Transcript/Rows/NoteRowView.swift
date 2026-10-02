import AppKit

/// The 11-pt line under a bubble, right-aligned (05-local.md, 08-live.md): a
/// command's output, *4 lines ›*, where a prompt written here has got to —
/// *Sent when Claude is ready*, *Queued · Withdraw*, red *Not sent — … ·
/// Resend*. It reports on the message above it and is not a message of its own.
///
/// Words are tertiary, red when they say something failed; a link is the
/// accent. Wrapped words never grow past four lines; a link after the words
/// shares their line, one that `isBelow` has a line of its own.
@MainActor
final class NoteRowView: NSView, PageRowView {
    typealias Model = Note

    weak var delegate: PageRowViewDelegate?

    /// The line's room to the trailing edge, as the bubble's text sits in it.
    private static let inset: CGFloat = 10
    /// Between inline words and their link.
    private static let separator = " · "
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let maxLines = 4

    private let words = NSTextField(wrappingLabelWithString: "")
    private let inlineLink = NSButton()
    private let belowLink = NSButton()
    private let line: NSStackView
    private let column: NSStackView
    private var intent: Note.Intent?

    override init(frame frameRect: NSRect) {
        line = NSStackView(views: [words, inlineLink])
        column = NSStackView(views: [line, belowLink])
        super.init(frame: frameRect)

        words.font = Self.font
        words.alignment = .right
        words.isSelectable = false
        words.maximumNumberOfLines = Self.maxLines
        words.lineBreakMode = .byWordWrapping
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [inlineLink, belowLink] {
            button.isBordered = false
            button.target = self
            button.action = #selector(linkClicked)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 0
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Model

    static func height(for model: Note, width: CGFloat) -> CGFloat {
        let inlineLink = model.link.flatMap { $0.isBelow ? nil : $0 }
        var height: CGFloat = 0
        if !model.text.isEmpty {
            let reserved = inlineLink.map { linkWidth($0) + separatorWidth } ?? 0
            height = wordsHeight(model.text, width: width - inset - reserved)
        }
        if inlineLink != nil { height = max(height, lineHeight) }
        if model.link?.isBelow == true { height += lineHeight }
        return max(height, lineHeight)
    }

    func configure(with model: Note) {
        intent = model.link?.intent
        let isBelow = model.link?.isBelow == true

        words.isHidden = model.text.isEmpty
        words.stringValue = model.text + (model.link != nil && !isBelow && !model.text.isEmpty ? Self.separator : "")
        words.textColor = model.style == .failure ? .failureText : .tertiaryLabelColor

        inlineLink.isHidden = model.link == nil || isBelow
        belowLink.isHidden = !isBelow
        if let item = model.link {
            let title = NSAttributedString(
                string: item.title, attributes: [.font: Self.font, .foregroundColor: NSColor.linkColor])
            (isBelow ? belowLink : inlineLink).attributedTitle = title
        }
        needsLayout = true
    }

    override func layout() {
        // The words wrap at what the row leaves them, as `height(for:width:)` measured.
        let reserved = inlineLink.isHidden ? 0 : Self.linkWidth(of: inlineLink) + Self.separatorWidth
        words.preferredMaxLayoutWidth = max(bounds.width - Self.inset - reserved, 1)
        super.layout()
    }

    // MARK: - Measuring

    private static var lineHeight: CGFloat { cell(for: "M", width: 1000).height }

    private static var separatorWidth: CGFloat {
        ceil((separator as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func linkWidth(_ link: Note.Link) -> CGFloat {
        ceil((link.title as NSString).size(withAttributes: [.font: font]).width) + 8
    }

    private static func linkWidth(of button: NSButton) -> CGFloat {
        ceil(button.attributedTitle.size().width) + 8
    }

    /// Measured with the cell the label draws with.
    private static func wordsHeight(_ text: String, width: CGFloat) -> CGFloat {
        min(cell(for: text, width: max(width, 1)).height, lineHeight * CGFloat(maxLines))
    }

    private static func cell(for text: String, width: CGFloat) -> NSSize {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000))
    }

    // MARK: - Events

    @objc private func linkClicked() {
        switch intent {
        case .open(let id)?: delegate?.pageRowView(self, didRequestDocument: id, pinned: false)
        case .withdraw(let uuid)?: delegate?.pageRowView(self, didRequestWithdrawOfPrompt: uuid)
        case .resend(let uuid)?: delegate?.pageRowView(self, didRequestResendOfPrompt: uuid)
        case nil: break
        }
    }
}
