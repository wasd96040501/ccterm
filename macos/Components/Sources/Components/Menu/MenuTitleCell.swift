import AppKit

/// A section's head (`.mh`): 11-pt semibold tertiary words over the items'
/// glyph column, a key hint at the trailing edge.
final class MenuTitleCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = MenuMetrics.headerFont
        title.textColor = .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = MenuMetrics.hintFont
        hint.textColor = .tertiaryLabelColor
        for view in [title, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let baseline =
            MenuMetrics.headerTop + MenuMetrics.baseline(of: MenuMetrics.headerFont, onLine: MenuMetrics.headerLine)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.inset + 24),
            title.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: baseline),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            hint.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ words: String, hint: String?) {
        title.stringValue = words
        self.hint.stringValue = hint ?? ""
        self.hint.isHidden = hint == nil
        setAccessibilityLabel(words)
    }
}
