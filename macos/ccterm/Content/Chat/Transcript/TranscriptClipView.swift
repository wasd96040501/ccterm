import AppKit

/// `NSClipView` subclass that horizontally centers a documentView narrower
/// than itself. Auto Layout alone can't do this: the default `NSClipView`
/// implementation of `constrainBoundsRect(_:)` clamps `bounds.origin.x`
/// to keep the documentView flush-left when the doc is narrower than the
/// clip, so a `centerXAnchor == clip.centerXAnchor` constraint on the
/// documentView is visually ignored. Every macOS "center a narrow document
/// view" recipe subclasses `NSClipView` for exactly this reason
/// (`docs/refactor/transcript-refactor.md § 4.1` cites the sources).
///
/// Also clamps negative widths / heights on `setFrameSize` per
/// `NativeTranscript2/CLAUDE.md § 2.9` — AppKit briefly feeds negative
/// widths during scroller layout and stock views log "Invalid view
/// geometry" warnings otherwise.
@MainActor
final class TranscriptClipView: NSClipView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }

        // Horizontal centering when the doc is narrower than the clip.
        // `origin.x` in clip coords is the offset applied when composing
        // the doc bitmap; negative pulls the doc rightward. The formula
        // matches the community-consensus centering recipe.
        let docWidth = doc.frame.width
        if docWidth < proposedBounds.width {
            rect.origin.x =
                floor((proposedBounds.width - docWidth) / -2.0)
        }
        return rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(
            NSSize(width: max(0, newSize.width), height: max(0, newSize.height)))
    }
}
