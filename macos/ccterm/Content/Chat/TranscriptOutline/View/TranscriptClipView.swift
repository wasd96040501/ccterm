import AppKit

/// Clip view that centers a fixed-width `documentView` (the outline)
/// horizontally inside a wider window (SPEC §5). The outline is a
/// fixed-width [460, 780] document; this clip places it in the middle so
/// the native indent (disclosure triangle + per-level offset) operates
/// inside that centered column rather than the cell offsetting its own
/// draw origin.
///
/// `NSClipView.constrainBoundsRect` by default clamps a narrow
/// documentView flush-left (documented behavior); reversing that in a
/// subclass is Apple's recommended centering pattern. `NSOutlineView` is
/// an `NSTableView` subclass, so the same technique applies.
final class TranscriptClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docWidth = documentView.frame.width
        // Only center when the document is narrower than the viewport;
        // otherwise leave AppKit's horizontal constraint untouched. The
        // negative divisor mirrors AppKit's flush-left clamp into a
        // centering offset.
        if docWidth < proposedBounds.width {
            rect.origin.x = floor((proposedBounds.width - docWidth) / -2.0)
        }
        return rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        // AppKit briefly hands negative widths during scroller layout;
        // clamp so the clip never adopts an invalid geometry.
        super.setFrameSize(
            NSSize(width: max(0, newSize.width), height: max(0, newSize.height)))
    }
}
