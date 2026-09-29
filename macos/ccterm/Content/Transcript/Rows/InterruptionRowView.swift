import AppKit

/// `stop.circle` *Interrupted*: the reader stopped Claude while it was
/// writing — the reply's last word (05-local.md "Interruption").
@MainActor
final class InterruptionRowView: NSView, PageRowView {
    typealias Model = Void

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Void, width: CGFloat) -> CGFloat { 20 }

    func configure(with model: Void) {}
}
