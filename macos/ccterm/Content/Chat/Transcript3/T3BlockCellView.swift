import AppKit
import CoreText

/// Draws one `T3Block` using its precomputed `T3RowLayout`. Zero own state:
/// `configure(with:)` is idempotent — every reuse rewrites every field.
///
/// The cell's `drawRect` uses `CTFrameDraw` directly on top of the CoreText
/// framesetter carried by `T3RowLayout`. No `NSTextField` / `NSTextView` — a
/// single frame per cell is cheap and gives us pixel-perfect control over
/// vertical offsets. When the layout's language / markdown IR grows richer,
/// this file grows richer alongside it (adornments, buttons, syntax
/// colouring) — the layout still ships fully typeset from the store.
@MainActor
final class T3BlockCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("T3BlockCellView")

    private var layout: T3RowLayout?
    private var kind: T3Block.Kind?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func configure(with block: T3Block, layout: T3RowLayout) {
        self.kind = block.kind
        self.layout = layout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // User bubble: a right-aligned rounded background rect. Cheap
        // (Bézier + fill). Everything else draws in the shared paragraph
        // rect with no adornment.
        if case .userBubble = kind {
            let bubbleInset: CGFloat = 40
            let rect = NSRect(
                x: bubbleInset,
                y: 4,
                width: bounds.width - bubbleInset - 12,
                height: layout.bounds.height + 12)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }

        // Flip into text coordinates (CoreText is bottom-up), then draw
        // the paragraph rect at the layout's bounds.
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let paragraph = CGRect(
            x: layout.bounds.origin.x,
            y: bounds.height - layout.bounds.origin.y - layout.bounds.height,
            width: layout.bounds.width,
            height: layout.bounds.height)
        let path = CGPath(rect: paragraph, transform: nil)
        let frame = CTFramesetterCreateFrame(
            layout.framesetter,
            CFRange(location: 0, length: layout.attributed.length),
            path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layout = nil
        kind = nil
    }
}
