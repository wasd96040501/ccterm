import AppKit

/// The 20-pt line naming who speaks in the `.markdown` row under it — a
/// subagent, a session, the coordinator, a plugin, or a plan
/// (06-voices.md, 07-talk.md).
@MainActor
final class CaptionRowView: NSView, PageRowView {
    typealias Model = Caption

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Caption, width: CGFloat) -> CGFloat { 20 }

    func configure(with model: Caption) {}
}
