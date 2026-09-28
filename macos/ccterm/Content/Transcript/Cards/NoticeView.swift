import AppKit

/// A line of news — a background task ended, an interruption, a compaction —
/// set small and secondary, as a caption between the turns rather than a turn
/// of its own. Its symbol carries the tone: green done, red failed, grey
/// otherwise. When the news came with more (an agent's answer), the line is
/// pressable and opens it beside the transcript.
@MainActor
final class NoticeView: NSView {
    static let height: CGFloat = 24

    weak var delegate: TranscriptCardDelegate?

    private let pill = PressableRowView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var notice: TranscriptNotice?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, label, chevron])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.highlightInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pill.addSubview(stack)
        addSubview(pill)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -6),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        pill.onClick = { [weak self] clickCount in
            guard let self, let document = notice?.document else { return }
            delegate?.card(self, open: document, pinned: clickCount > 1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with notice: TranscriptNotice) {
        self.notice = notice
        pill.resetHighlight()
        pill.isPressable = notice.document != nil
        icon.image = NSImage(systemSymbolName: notice.symbol, accessibilityDescription: nil)
        icon.contentTintColor =
            switch notice.tone {
            case .positive: .systemGreen
            case .negative: .systemRed
            case .neutral: .secondaryLabelColor
            }
        label.stringValue = notice.text
        pill.toolTip = notice.text
        chevron.isHidden = notice.document == nil
        pill.setAccessibilityLabel(notice.text)
    }
}
