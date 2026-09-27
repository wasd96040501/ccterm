import AppKit

/// One picture, aspect-fitted into the overlay — the content half of Telegram's
/// gallery, with the window, the mask and the flight all supplied by
/// `MediaOverlayWindow`.
///
/// Nothing is rounded and nothing is cropped here, which is the whole difference
/// between this and the tile it flew out of. A tile in a mosaic is cropped to a
/// shape the *layout* chose; a preview is the picture's own shape at the largest
/// size the screen allows. That the two disagree is the point of opening one.
@MainActor
public final class ImagePreviewView: NSView, MediaOverlayContent {

    private var image: NSImage?

    /// The tile's copy shows immediately; the original replaces it when it has
    /// been decoded.
    ///
    /// Two loads rather than one, and the reason is the `fitted` rule below: the
    /// preview shows the picture at **its own size**, and the copy the mosaic
    /// decoded is at most 1024 pixels on its long side — enough for a 360-point
    /// tile and not enough for the middle of a display. Handing the tile's copy to
    /// the preview would mean a soft picture wherever the original was larger,
    /// which is the failure the size rule exists to avoid.
    ///
    /// The swap is not animated. It is the same picture at a better resolution, so
    /// a crossfade would read as a flicker rather than as an arrival.
    public init(url: URL) {
        self.image = MediaImageStore.shared.cachedImage(for: url)
        super.init(frame: .zero)
        wantsLayer = true

        MediaImageStore.shared.loadOriginal(for: url) { [weak self] original in
            guard let self, let original else { return }
            self.image = original
            self.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImagePreviewView is code-only; init(coder:) is unavailable")
    }

    /// The picture at its **own size**, centred — shrunk proportionally only when
    /// it is larger than the space.
    ///
    /// This is `NSSize.fitted` from `TGUIKit`, which the gallery composes as
    /// `item.sizeValue.fitted(contentFrame.size)` and then centres with
    /// `view.focus(_:inset:)`. Read rather than recalled, because the shape of it
    /// is the part that is easy to get backwards: `fitted` shrinks and **never
    /// enlarges** — its two branches are `if width > size.width` and `if height >
    /// size.height`, and a picture smaller than the screen falls through both
    /// unchanged.
    ///
    /// An earlier version here scaled small pictures **up**, on the reasoning that
    /// a lightbox showing a thumbnail at thumbnail size has opened for nothing.
    /// That reasoning is wrong about what a viewer is for: enlarging a 200-point
    /// picture to fill a 27-inch display shows a soft, resampled 200-point
    /// picture, and "this is all there is" is information the reader wants rather
    /// than a shortcoming to paper over.
    public func overlayFrame(in available: NSRect) -> NSRect {
        // The tile's copy while that is all there is. Its proportion is the
        // original's, so the frame this answers does not move when the original
        // lands — only the pixels inside it get better.
        let natural = image?.size ?? MediaImageStore.fallbackSize
        guard natural.width > 0, natural.height > 0, available.width > 0, available.height > 0
        else { return available }

        var size = natural
        if size.width > available.width {
            size = CGSize(
                width: available.width,
                height: (size.height * available.width / max(size.width, 1)).rounded(.up))
        }
        if size.height > available.height {
            size = CGSize(
                width: (size.width * available.height / max(size.height, 1)).rounded(.up),
                height: available.height)
        }

        return NSRect(
            x: available.midX - size.width / 2, y: available.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }
}
