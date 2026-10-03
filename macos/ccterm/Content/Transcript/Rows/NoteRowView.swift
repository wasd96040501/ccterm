import AppKit

/// The 11-pt line under a bubble, right-aligned (05-local.md, 08-live.md): a
/// command's output, *4 lines ›*, where a prompt written here has got to —
/// *Sent when Claude is ready*, *Queued · Withdraw*, red *Not sent — … ·
/// Resend*. It reports on the message above it and is not a message of its own.
///
/// Words are tertiary, red when a command's stderr; a prompt that was not
/// sent has secondary words after a 12-pt red mark. A link is the accent on
/// the words' line: 8 pt after them, or after ` · ` for a cut output
/// (`.cap-out` with its *Show all*). Wrapped words never grow past four lines;
/// the mark and the link sit centred on them.
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
    /// The ` · ` before a cut output's link, a label of its own so the words
    /// never wrap it away from them.
    private let dot = NSTextField(labelWithString: "·")
    private let line: NSStackView
    private var intent: Note.Intent?
    private var trailing: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        line = NSStackView(views: [mark, words, dot, inlineLink])
        super.init(frame: frameRect)

        words.font = Self.font
        words.alignment = .right
        words.isSelectable = false
        words.maximumNumberOfLines = Self.maxLines
        words.lineBreakMode = .byWordWrapping
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dot.font = Self.font
        dot.textColor = .tertiaryLabelColor
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)

        mark.image = Self.markImage
        mark.imageScaling = .scaleNone
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: Self.markSize).isActive = true
        mark.heightAnchor.constraint(equalToConstant: Self.markSize).isActive = true

        inlineLink.isBordered = false
        inlineLink.target = self
        inlineLink.action = #selector(linkClicked)
        inlineLink.setContentHuggingPriority(.required, for: .horizontal)

        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 0
        line.setCustomSpacing(Self.markGap, after: mark)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        let trailing = line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset)
        self.trailing = trailing
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: Self.halfLeading),
            trailing,
            line.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Model

    static func height(for model: Note, width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if !model.text.isEmpty {
            let reserved = reservedWidth(link: model.link, marked: model.style == .notSent)
            height = wordsHeight(model.text, width: width - inset - reserved)
        }
        return max(height, lineHeight) + 2 * halfLeading
    }

    /// A space at the words' size: either side of the dot (`.cap-out`'s ` · `).
    private static var space: CGFloat { ceil((" " as NSString).size(withAttributes: [.font: font]).width) }

    private static var dotWidth: CGFloat { ceil(("·" as NSString).size(withAttributes: [.font: font]).width) + 4 }

    /// From the words' end to the link's ink: 8 pt, or ` · `.
    private static func linkLead(for link: Note.Link) -> CGFloat {
        link.isAfterDot ? space + dotWidth + space : linkGap
    }

    func configure(with model: Note) {
        intent = model.link?.intent

        mark.isHidden = model.style != .notSent
        words.isHidden = model.text.isEmpty
        words.stringValue = model.text
        switch model.style {
        case .tertiary: words.textColor = .tertiaryLabelColor
        case .failure: words.textColor = .failureText
        case .notSent: words.textColor = .secondaryLabelColor
        }
        let dotted = model.link?.isAfterDot == true && !model.text.isEmpty
        dot.isHidden = !dotted
        // A label carries 2 pt inside either side of its words, the link's button 2 more.
        line.setCustomSpacing(
            dotted ? Self.space - 2 : (model.text.isEmpty ? 0 : Self.linkGap - Self.linkPadding), after: words)
        line.setCustomSpacing(Self.space - 2 - Self.linkPadding, after: dot)
        // The ink ends `inset` from the edge, whether words or a link end the line.
        trailing?.constant = -(Self.inset - (model.link != nil ? Self.linkPadding : 0))

        inlineLink.isHidden = model.link == nil
        if let item = model.link {
            inlineLink.attributedTitle = NSAttributedString(
                string: item.title, attributes: [.font: Self.font, .foregroundColor: NSColor.controlAccentColor])
        }
        needsLayout = true
    }

    override func layout() {
        // The words wrap at what the row leaves them, as `height(for:width:)` measured.
        let lead = dot.isHidden ? Self.linkGap : Self.space + Self.dotWidth + Self.space
        let link = inlineLink.isHidden ? 0 : Self.linkWidth(of: inlineLink) + lead - Self.linkPadding
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
        let link = link.map { linkWidth($0) + linkLead(for: $0) - linkPadding } ?? 0
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
