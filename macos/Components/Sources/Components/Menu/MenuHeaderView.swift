import AppKit

/// A menu's head over a group: 11-pt semibold tertiary words in the items'
/// glyph column with a key hint at the trailing edge — or an account's, its
/// mark, its name in secondary, its detail in tertiary after it and a note on
/// a line under the name.
final class MenuHeaderView: NSTableCellView {
    private let mark = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private lazy var line = NSStackView(views: [mark, name, detail])
    private lazy var lineLeading = line.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var lineTop = line.topAnchor.constraint(equalTo: topAnchor)
    private lazy var lineBottom = line.bottomAnchor.constraint(equalTo: bottomAnchor)
    private lazy var noteBottom = note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [detail, note, hint] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        for view in [line, note, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 14),
            mark.heightAnchor.constraint(equalToConstant: 14),
            lineLeading,
            lineTop,
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            note.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            note.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 1),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hint.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows a `.header` or an `.account` row.
    func configure(_ row: MenuContent.Row) {
        var hasNote = false
        switch row {
        case .header(let words, let hintWords):
            mark.isHidden = true
            name.stringValue = words
            name.textColor = .tertiaryLabelColor
            detail.isHidden = true
            hint.stringValue = hintWords ?? ""
            hint.isHidden = hintWords == nil
            // Over the items' glyph column.
            lineLeading.constant = 18
            lineTop.constant = 4
            lineBottom.constant = -2
            setAccessibilityLabel(words)
        case .account(let image, let words, let detailWords, let noteWords):
            mark.image = image
            mark.contentTintColor = image.isTemplate ? .secondaryLabelColor : nil
            mark.isHidden = false
            name.stringValue = words
            name.textColor = .secondaryLabelColor
            detail.stringValue = detailWords
            detail.isHidden = detailWords.isEmpty
            note.stringValue = noteWords ?? ""
            hasNote = noteWords != nil
            hint.isHidden = true
            lineLeading.constant = 0
            lineTop.constant = 8
            lineBottom.constant = -4
            setAccessibilityLabel([words, detailWords, noteWords].compactMap { $0 }.joined(separator: " "))
        case .item, .separator:
            break
        }
        note.isHidden = !hasNote
        lineBottom.isActive = !hasNote
        noteBottom.isActive = hasNote
    }
}
