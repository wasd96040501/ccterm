import AppKit

/// A command the user ran in the CLI — `/model opus`, `!git status` — as a
/// trailing capsule, with what it printed under it (05-local.md). Not a
/// bubble: the user set something, they didn't say it.
@MainActor
final class CapsuleRowView: NSView, PageRowView {
    typealias Model = LocalCommand

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: LocalCommand, width: CGFloat) -> CGFloat { 24 }

    func configure(with model: LocalCommand) {}
}
