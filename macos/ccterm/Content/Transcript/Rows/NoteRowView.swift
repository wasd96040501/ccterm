import AppKit

/// The 11-pt line under a bubble, right-aligned (05-local.md, 08-live.md): a
/// command's output, *4 lines ›*, where a prompt written here has got to —
/// *Sent when Claude is ready*, *Queued · Withdraw*, red *Not sent — … ·
/// Resend*. It reports on the message above it and is not a message of its own.
///
/// Words are tertiary, red when a command's stderr; a prompt that was not
/// sent has secondary words after a 12-pt red mark. A link is the accent, 8 pt
/// after the words on their line, or on a line of its own when `isBelow`.
/// Wrapped words never grow past four lines; the mark and an inline link sit
/// centred on them.
@MainActor
final class NoteRowView: NSView, PageRowView {
    typealias Model = Note

    weak var delegate: PageRowViewDelegate?

    /// The words' room to the trailing edge (the design's `padding-right`). A
    /// link's button carries `linkPadding` of it inside itself.
    private static let inset: CGFloat = 12
    /// Between inline words and their link's words.
    private static let linkGap: CGFloat = 8
    /// The not-sent mark's box, and its room before the words.
    private static let markSize: CGFloat = 12
    private static let markGap: CGFloat = 4
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let maxLines = 4

    private let mark = NSImageView()
    private let words = NSTextField(wrappingLabelWithString: "")
    private let inlineLink = NSButton()
    private let belowLink = NSButton()
    private let line: NSStackView
    private let column: NSStackView
    private var intent: Note.Intent?
    private var trailing: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        line = NSStackView(views: [mark, words, inlineLink])
        column = NSStackView(views: [line, belowLink])
        super.init(frame: frameRect)

        words.font = Self.font
        words.alignment = .right
        words.isSelectable = false
        words.maximumNumberOfLines = Self.maxLines
        words.lineBreakMode = .byWordWrapping
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        mark.image = Self.markImage
        mark.imageScaling = .scaleNone
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: Self.markSize).isActive = true
        mark.heightAnchor.constraint(equalToConstant: Self.markSize).isActive = true

        for button in [inlineLink, belowLink] {
            button.isBordered = false
            button.target = self
            button.action = #selector(linkClicked)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 0
        line.setCustomSpacing(Self.markGap, after: mark)
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let trailing = column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset)
        self.trailing = trailing
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.halfLeading),
            trailing,
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
            let reserved = reservedWidth(link: inlineLink, marked: model.style == .notSent)
            height = wordsHeight(model.text, width: width - inset - reserved)
        }
        if inlineLink != nil { height = max(height, lineHeight) }
        if model.link?.isBelow == true { height += lineHeight }
        return max(height, lineHeight) + 2 * halfLeading
    }

    func configure(with model: Note) {
        intent = model.link?.intent
        let isBelow = model.link?.isBelow == true

        mark.isHidden = model.style != .notSent
        words.isHidden = model.text.isEmpty
        words.stringValue = model.text
        switch model.style {
        case .tertiary: words.textColor = .tertiaryLabelColor
        case .failure: words.textColor = .failureText
        case .notSent: words.textColor = .secondaryLabelColor
        }
        line.setCustomSpacing(model.text.isEmpty ? 0 : Self.linkGap - Self.linkPadding, after: words)
        // The ink ends `inset` from the edge, whether words or a link end the line.
        trailing?.constant = -(Self.inset - (model.link != nil && !isBelow ? Self.linkPadding : 0))

        inlineLink.isHidden = model.link == nil || isBelow
        belowLink.isHidden = !isBelow
        if let item = model.link {
            let title = NSAttributedString(
                string: item.title, attributes: [.font: Self.font, .foregroundColor: NSColor.controlAccentColor])
            (isBelow ? belowLink : inlineLink).attributedTitle = title
        }
        needsLayout = true
    }

    override func layout() {
        // The words wrap at what the row leaves them, as `height(for:width:)` measured.
        let link = inlineLink.isHidden ? 0 : Self.linkWidth(of: inlineLink) + Self.linkGap - Self.linkPadding
        let reserved = link + (mark.isHidden ? 0 : Self.markSize + Self.markGap)
        words.preferredMaxLayoutWidth = max(bounds.width - Self.inset - reserved, 1)
        super.layout()
    }

    // MARK: - Measuring

    private static var lineHeight: CGFloat { cell(for: "M", width: 1000).height }

    /// The design sets the line at 1.45 × 11 pt, its words centred in it; the
    /// label's own line is tighter, so the difference sits above and below.
    private static var halfLeading: CGFloat { max(0, (16 - lineHeight) / 2) }

    /// What a borderless button adds either side of its title.
    private static let linkPadding: CGFloat = 2

    /// Beside the words on their line: the mark before them, the link after.
    private static func reservedWidth(link: Note.Link?, marked: Bool) -> CGFloat {
        let link = link.map { linkWidth($0) + linkGap - linkPadding } ?? 0
        return link + (marked ? markSize + markGap : 0)
    }

    private static func linkWidth(_ link: Note.Link) -> CGFloat {
        ceil((link.title as NSString).size(withAttributes: [.font: font]).width) + 2 * linkPadding
    }

    private static func linkWidth(of button: NSButton) -> CGFloat {
        ceil(button.attributedTitle.size().width) + 2 * linkPadding
    }

    /// A red disc with a white *!*, 11 pt across in its 12-pt box.
    private static let markImage: NSImage? = NSImage(
        systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil
    )?
    .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])))

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
