import AppKit

/// Custom-drawn row cell. Holds a fully prepared `RowItem`(block + Core Text
/// layout), draws it via `override draw(_:)`.
///
/// Layer policy: `wantsLayer = true` + `.onSetNeedsDisplay`. The cached layer
/// bitmap is reused during scroll(zero `draw(_:)` calls), and AppKit only
/// re-issues `draw(_:)` after we mark `needsDisplay = true`.
final class BlockCellView: NSView {
    var item: RowItem? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = CGPoint(
            x: BlockStyle.blockHorizontalPadding,
            y: BlockStyle.blockVerticalPadding)
        item.layout.draw(in: ctx, origin: origin)
    }
}
