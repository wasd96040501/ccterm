import AppKit

/// A hairline where the session's shape changed — compacted, resumed, an
/// hour of silence — with its label centred on it (05-local.md).
///
/// The label is 11-pt secondary; *Summary*, when the model has one, is a link
/// after it. A compaction in progress puts a small running tile before the
/// label.
@MainActor
final class DividerRowView: NSView, PageRowView {
    typealias Model = SessionDivider

    weak var delegate: PageRowViewDelegate?

    private static let font = NSFont.systemFont(ofSize: 11)

    private let leadingLine = HairlineView()
    private let trailingLine = HairlineView()
    private let tile = TileView()
    private let label = NSTextField(labelWithString: "")
    private let summary = NSButton()
    private var summaryID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Self.font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tile.tile = Tile(glyph: .tool(.other), state: .running)

        summary.isBordered = false
        summary.attributedTitle = NSAttributedString(
            string: String(localized: "Summary"),
            attributes: [.font: Self.font, .foregroundColor: NSColor.linkColor])
        summary.target = self
        summary.action = #selector(summaryClicked)

        let centre = NSStackView(views: [tile, label, summary])
        centre.orientation = .horizontal
        centre.alignment = .centerY
        centre.spacing = 6
        for view in [leadingLine, trailingLine, centre] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let centred = centre.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centre.centerYAnchor.constraint(equalTo: centerYAnchor),
            centred,
            centre.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            centre.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            leadingLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingLine.trailingAnchor.constraint(equalTo: centre.leadingAnchor, constant: -12),
            trailingLine.leadingAnchor.constraint(equalTo: centre.trailingAnchor, constant: 12),
            trailingLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            leadingLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingLine.heightAnchor.constraint(equalToConstant: 0.5),
            trailingLine.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: SessionDivider, width: CGFloat) -> CGFloat { 28 }

    func configure(with model: SessionDivider) {
        label.stringValue = model.label
        if case .compacting = model.kind { tile.isHidden = false } else { tile.isHidden = true }
        summaryID = model.summary == nil ? nil : model.id
        summary.isHidden = model.summary == nil
    }

    @objc private func summaryClicked() {
        guard let id = summaryID else { return }
        delegate?.pageRowView(self, didRequestDocument: id, pinned: false)
    }

    /// The 0.5-pt line either side of the label, in the separator colour.
    private final class HairlineView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }
    }
}
