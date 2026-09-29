import AppKit

/// The 20-pt line naming who speaks in the `.markdown` row under it — a
/// subagent, a session, the coordinator, a plugin, or a plan
/// (06-voices.md, 07-talk.md).
///
/// A party is drawn with the sidebar's glyph for it, in the sidebar's colour;
/// a plan with its tool tile. The words are 13-pt secondary.
@MainActor
final class CaptionRowView: NSView, PageRowView {
    typealias Model = Caption

    weak var delegate: PageRowViewDelegate?

    private static let side: CGFloat = 16

    private let glyph = NSImageView()
    private let tile = ToolTileView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [glyph, tile, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Self.side),
            glyph.heightAnchor.constraint(equalToConstant: Self.side),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Caption, width: CGFloat) -> CGFloat { 20 }

    func configure(with model: Caption) {
        label.stringValue = model.text
        if case .tile(let value) = model.glyph {
            tile.tile = value
            tile.isHidden = false
            glyph.isHidden = true
            glyph.image = nil
            return
        }
        tile.isHidden = true
        glyph.isHidden = false
        switch model.glyph {
        case .subagent:
            glyph.image = NSImage(resource: .sidebarAgent)
            glyph.contentTintColor = .systemGray
        case .session:
            glyph.image = NSImage(resource: .sidebarSession)
            glyph.contentTintColor = NSColor(resource: .sidebarCoral)
        case .coordinator:
            glyph.image = NSImage(resource: .sidebarWorkflow)
            glyph.contentTintColor = .systemIndigo
        case .plugin:
            glyph.image = .symbol("puzzlepiece.extension", pointSize: 13)
            glyph.contentTintColor = .systemGray
        case .tile:
            break
        }
    }
}
