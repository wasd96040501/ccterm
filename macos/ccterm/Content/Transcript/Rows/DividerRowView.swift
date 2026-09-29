import AppKit

/// A hairline where the session's shape changed — compacted, resumed, an
/// hour of silence — with its label centred on it (05-local.md).
@MainActor
final class DividerRowView: NSView, PageRowView {
    typealias Model = SessionDivider

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: SessionDivider, width: CGFloat) -> CGFloat { 24 }

    func configure(with model: SessionDivider) {}
}
