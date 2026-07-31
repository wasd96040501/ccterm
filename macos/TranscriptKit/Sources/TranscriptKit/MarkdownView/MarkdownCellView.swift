import AppKit

/// The view a self-drawn row is served through: holds one block tree and draws
/// it.
///
/// Deliberately thin. It owns no layout — the tree arrived already laid out at
/// the width the transcript committed to — and no styling. What it does own is
/// the two things a block tree cannot: a place in the view hierarchy, and the
/// `dirtyRect` that lets the tree skip what cannot be seen.
///
/// `isFlipped` is true so that the y-down arithmetic every block is written in
/// matches the context it draws into, rather than being un-flipped at each of
/// the several dozen places a rectangle crosses the boundary.
final class MarkdownCellView: NSView {

    static let identifier = NSUserInterfaceItemIdentifier("TranscriptKit.markdown")

    private(set) var block: Block?

    override var isFlipped: Bool { true }

    /// Rows do not overlap and the transcript draws no background of its own, so
    /// AppKit can skip everything behind this view.
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MarkdownCellView is code-only; init(coder:) is unavailable")
    }

    /// Binds a tree. Idempotent — a recycled instance keeps nothing from the row
    /// it was serving a moment ago, because the tree is the entirety of its
    /// state.
    func configure(with block: Block) {
        self.block = block
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let block, let ctx = NSGraphicsContext.current?.cgContext else { return }
        block.draw(at: .zero, in: ctx, dirty: dirtyRect)
    }
}
