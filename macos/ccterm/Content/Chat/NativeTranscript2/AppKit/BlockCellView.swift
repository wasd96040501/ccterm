import AppKit

/// Custom-drawn row cell. Holds a prepared `RowLayout`, draws it via
/// `override draw(_:)`.
///
/// Layer policy: `wantsLayer = true` + `.onSetNeedsDisplay`. The cached
/// layer bitmap is reused during scroll (zero `draw(_:)` calls), and AppKit
/// only re-issues `draw(_:)` after we mark `needsDisplay = true`.
///
/// ### Link interaction
///
/// `RowLayout.links` carries layout-local hot zones for `.link`-attributed
/// runs. The cell offsets them by `layoutOrigin` to get cell-local rects,
/// then:
/// - `mouseDown` opens the URL on a hit (and consumes the event).
/// - `resetCursorRects` registers a `pointingHand` cursor for each rect, so
///   the system handles cursor swapping during hover without us having to
///   install a tracking area.
final class BlockCellView: NSView {
    var layout: RowLayout? {
        didSet {
            needsDisplay = true
            // Cursor rects are cached by AppKit per-view; layout changes
            // (resize, content swap) invalidate those caches so the new
            // link rects take effect on the next mouse motion.
            window?.invalidateCursorRects(for: self)
        }
    }

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    private var layoutOrigin: CGPoint {
        CGPoint(
            x: BlockStyle.blockHorizontalPadding,
            y: BlockStyle.blockVerticalPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        layout.draw(in: ctx, origin: layoutOrigin)
    }

    // MARK: - Link interaction

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout else { return }
        let origin = layoutOrigin
        for hit in layout.links {
            addCursorRect(hit.rect.offsetBy(dx: origin.x, dy: origin.y),
                          cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func linkURL(at event: NSEvent) -> URL? {
        guard let layout else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let origin = layoutOrigin
        for hit in layout.links {
            if hit.rect.offsetBy(dx: origin.x, dy: origin.y).contains(local) {
                return hit.url
            }
        }
        return nil
    }
}
