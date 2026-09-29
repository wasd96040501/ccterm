import AppKit

/// The 28-pt bar on top of every document beside the transcript: the tile,
/// the path, the stat, and *Show in Transcript* — the way back, always in
/// the same place (design/transcript/02-command.md, 03-file.md).
@MainActor
final class JumpBarView: NSView {
    static let height: CGFloat = 28

    weak var delegate: JumpBarViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with header: DocumentHeader) {}
}
