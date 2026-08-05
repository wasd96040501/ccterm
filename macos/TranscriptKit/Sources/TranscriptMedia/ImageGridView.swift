import AppKit
import TranscriptKit

/// A transcript row made of pictures, arranged the way Telegram arranges a
/// grouped-media message.
///
/// This is a **host** row — a `.view` in `TranscriptRowContent`'s vocabulary —
/// and it is the shape of the argument that keeps `TranscriptKit` from having a
/// picture case of its own. What a row of images costs is decode, placeholder,
/// failure, an original that is not the copy on screen, and a press that opens
/// something. None of it is the renderer's, and all of it is right here.
///
/// ## Built from URLs
///
/// `file:`, `data:` and `https:` are the three ways a picture reaches a
/// transcript and they are already one type, so that is the input. See
/// `MediaImageStore` for why taking `NSImage` instead was the expensive shape,
/// with the measurements.
///
/// ## Layers, not paint
///
/// Each tile is a `CALayer`. The row's own `draw` puts down only the plates
/// underneath them — a flat fill at the exact geometry, which is what a tile
/// looks like before its picture arrives.
///
/// The split is forced by the fade. A paint list is a snapshot played
/// synchronously with no notion of time in it, so fading a picture in that way
/// would mean repainting the row every frame for a fifth of a second; as a layer
/// it is interpolated by the render server and this side draws nothing at all.
/// `BlockView`'s hover band moved for exactly this reason, and it is the same
/// rule: **anything that changes on its own clock is a layer.**
///
/// Two consequences fall out. `CALayer.cornerRadius` is one value and
/// `maskedCorners` only chooses which corners take it, so a tile needing 17 on
/// the group's outside and 5 on its inside has to be masked by a `CAShapeLayer`
/// carrying the real path. And a hand-made layer runs **implicit** animations —
/// a view's backing layer has them disabled by AppKit but a sublayer does not —
/// so they are turned off outright and the one fade that should happen is added
/// by hand.
///
/// ## Two numbers and where they come from
///
/// - **Outer corners are 17**, `.cornerRadius * 3 + 2` in Telegram's arithmetic,
///   so the group reads as one rounded card rather than as several.
/// - **Inner corners are 5**, their plain `.cornerRadius`. Not zero: two square
///   corners meeting across a four-point gap read as a crack, where two slightly
///   rounded ones read as a seam.
@MainActor
public final class ImageGridView: NSView {

    /// Telegram's `.cornerRadius * 3 + 2`.
    private static let outerRadius: CGFloat = 17

    /// Telegram's `.cornerRadius`.
    private static let innerRadius: CGFloat = 5

    /// `ChatGroupedItem`'s `_width = min(width, 360)`, and the `min(_width, 320)`
    /// it pairs with.
    ///
    /// **The pair is the load-bearing part, not either number.** The mosaic's
    /// hand-written arrangements are driven by `maxSize`'s own proportion:
    /// Telegram's 360 × 320 is 1.125, near enough square that a portrait-led
    /// group fills its width by taking the full height on the left. Hand the same
    /// algorithm a transcript's whole 700-point column against the same 320 and
    /// the box becomes 2.19 — the height-driven branches then produce a block
    /// two fifths as wide as the column, with the rest of the row empty. Measured
    /// on the demo's own screen before the cap went in, which is exactly the class
    /// of thing only a picture of it shows.
    ///
    /// So the block is capped rather than stretched to whatever width the window
    /// happens to have, and sits against the column's **trailing** edge — the
    /// side a user turn's bubble is on, because pictures in a transcript are
    /// something the reader attached rather than something the answer contained.
    private static let maxGroupWidth: CGFloat = 360
    private static let maxHeightHint: CGFloat = 320

    /// `ChatLayoutUtils.contentSize`'s `min(width, 320)` **square** for a picture
    /// travelling alone: a lone picture is fitted, not packed, so the box it is
    /// fitted into is the same on both axes and neither proportion is favoured.
    private static let maxSingleSide: CGFloat = 320

    /// Under every tile: what a picture that has not arrived looks like, and what
    /// keeps one with alpha in it from being a hole through to the window.
    private static let plateColor = NSColor(white: 0.5, alpha: 0.18)

    /// Telegram's `animateAlpha(from: 0, to: 1, duration: 0.2)`.
    private static let fadeDuration: CFTimeInterval = 0.2

    /// The mark a tile carries when there is nothing to show — a broken address,
    /// a file that is not there, bytes that are not a picture.
    private static let fallbackSymbol = "photo"

    /// A tile was clicked: its index, and its frame in this view's coordinates.
    public var onActivate: ((Int, NSRect) -> Void)?

    private var urls: [URL] = []
    private var layout = MosaicLayout(imageSizes: [], maxSize: .zero)
    private var tileLayers: [CALayer] = []

    /// Which tiles asked and got nothing back, so `draw` knows where to put the
    /// fallback mark. Indices rather than a per-tile flag because the answer is
    /// needed while drawing, when the layers are not the thing being consulted.
    private var failed: Set<Int> = []

    /// Bumped on every `configure`. A load that comes back carrying a stale
    /// generation is answering for a row this instance no longer serves — the
    /// recycling rule, expressed as the one piece of state it needs rather than
    /// as a cancellation protocol the decode does not have.
    private var generation = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImageGridView is code-only; init(coder:) is unavailable")
    }

    /// Top-left origin: the mosaic's rectangles are in `MeasuredBlock`'s
    /// convention and this draws them without a flip in between.
    public override var isFlipped: Bool { true }

    // MARK: - The height answer

    /// What a row of these pictures comes to at `width`, without decoding one.
    ///
    /// Asked of every picture row in the transcript on every content-width
    /// change, so it reads dimensions and nothing else — from `MediaImageStore`,
    /// which caches them per URL and reads them from the header. A remote address
    /// answers `fallbackSize`, and keeps answering it after the picture arrives:
    /// the row's shape is settled before the fetch and is not revised, so nothing
    /// reflows under a reader who is already looking at it.
    public static func height(for urls: [URL], width: CGFloat) -> CGFloat {
        guard !urls.isEmpty, width > 0 else { return 0 }
        return layout(for: urls, width: width).size.height
    }

    private static func layout(for urls: [URL], width: CGFloat) -> MosaicLayout {
        let sizes = urls.map { MediaImageStore.shared.size(of: $0) }
        return MosaicLayout(imageSizes: sizes, maxSize: maxSize(count: urls.count, in: width))
    }

    /// Telegram has two callers with two boxes — `ChatLayoutUtils` fits a lone
    /// picture, `ChatGroupedItem` packs a group — and the split is kept because
    /// the two want different things from the number.
    private static func maxSize(count: Int, in width: CGFloat) -> CGSize {
        if count == 1 {
            let side = min(width, maxSingleSide)
            return CGSize(width: side, height: side)
        }
        let capped = min(width, maxGroupWidth)
        return CGSize(width: capped, height: min(capped, maxHeightHint))
    }

    // MARK: - Binding

    /// Idempotent, as a recycled row's binding has to be: the URLs and everything
    /// derived from them are the whole of this view's state, and the generation
    /// bump is what stops the previous row's decodes from landing here.
    ///
    /// **This is where loading starts** — not in `draw`. `viewForRow` is called
    /// only for rows entering the viewport, which is the frequency a decode
    /// should have; `draw` is called again on every scroll, every resize frame
    /// and every appearance change, and would need a guard of its own to avoid
    /// starting the same work repeatedly.
    public func configure(with urls: [URL]) {
        generation += 1
        self.urls = urls
        failed = []
        relayout()
        loadTiles()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // The transcript sizes this view to the row it reserved, so a width
        // change arrives here rather than being asked for. Re-running the layout
        // is what keeps the tiles agreeing with the height that was measured —
        // and it moves the layers, which is why it is not only `draw`'s problem.
        if widthChanged { relayout() }
    }

    private func relayout() {
        layout = Self.layout(for: urls, width: bounds.width)
        rebuildTileLayers()
        needsDisplay = true
    }

    /// How far right the whole block sits. `MosaicLayout` works in its own space
    /// with the block's left edge at zero; the row is wider than the cap, and the
    /// difference is gutter on the **left**.
    private var blockOrigin: CGFloat {
        max(0, bounds.width - layout.size.width)
    }

    // MARK: - Tile layers

    /// One layer per tile, reused across relayouts so a width change moves them
    /// rather than replacing them — replacing would drop the picture already in
    /// `contents` and make every resize a fresh set of decodes.
    private func rebuildTileLayers() {
        guard let host = layer else { return }

        while tileLayers.count > layout.tiles.count {
            tileLayers.removeLast().removeFromSuperlayer()
        }
        while tileLayers.count < layout.tiles.count {
            let tile = CALayer()
            // A sublayer added by hand runs implicit animations where a view's
            // backing layer does not. Left on, a cached picture would cross-fade
            // into place on every recycle and a resize would animate every tile.
            tile.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            tile.contentsGravity = .resizeAspectFill
            tile.masksToBounds = true
            tile.mask = CAShapeLayer()
            host.addSublayer(tile)
            tileLayers.append(tile)
        }

        let dx = blockOrigin
        let scale = window?.backingScaleFactor ?? 2
        for (index, tile) in layout.tiles.enumerated() {
            let frame = tile.frame.offsetBy(dx: dx, dy: 0)
            let layer = tileLayers[index]
            layer.frame = frame
            layer.contentsScale = scale
            // The mask is in the layer's own space, so it is the tile's shape at
            // the origin rather than the frame it sits at.
            if let mask = layer.mask as? CAShapeLayer {
                mask.path = Self.roundedPath(
                    in: CGRect(origin: .zero, size: frame.size),
                    outerCorners: tile.outerCorners)
            }
        }
    }

    /// Cached pictures land **without** a fade; arriving ones fade.
    ///
    /// That distinction is the difference between scrolling back over a picture
    /// and having it flicker at you. Telegram carries the same one as a parameter
    /// on its content views, `approximateSynchronousValue`.
    private func loadTiles() {
        let generation = self.generation
        for (index, url) in urls.enumerated() {
            guard index < tileLayers.count else { break }

            if let cached = MediaImageStore.shared.cachedImage(for: url) {
                apply(cached, to: index, fading: false)
                continue
            }

            tileLayers[index].contents = nil
            MediaImageStore.shared.loadImage(for: url) { [weak self] image in
                guard let self, self.generation == generation else { return }
                guard let image else {
                    self.failed.insert(index)
                    self.needsDisplay = true
                    return
                }
                self.apply(image, to: index, fading: true)
            }
        }
    }

    private func apply(_ image: NSImage, to index: Int, fading: Bool) {
        guard index < tileLayers.count else { return }
        let layer = tileLayers[index]
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard fading else { return }
        // `opacity` rather than `contents`: the plate is drawn underneath by this
        // view, so fading the whole layer in reveals it, where a `contents`
        // transition would dissolve against nothing.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeDuration
        layer.add(fade, forKey: "fade")
    }

    // MARK: - Drawing

    /// Only the plates, and the mark on a tile that has nothing to show. The
    /// pictures are on layers above this.
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let dx = blockOrigin
        for (index, tile) in layout.tiles.enumerated() {
            let frame = tile.frame.offsetBy(dx: dx, dy: 0)
            guard frame.intersects(dirtyRect) else { continue }

            context.saveGState()
            context.addPath(Self.roundedPath(in: frame, outerCorners: tile.outerCorners))
            context.clip()
            context.setFillColor(Self.plateColor.cgColor)
            context.fill(frame)
            context.restoreGState()

            if failed.contains(index) { drawFallback(in: frame) }
        }
    }

    /// Centred, at a fixed size rather than a fraction of the tile: it says "there
    /// is no picture here", which is the same statement whatever shape the tile
    /// came out.
    private func drawFallback(in frame: CGRect) {
        let side: CGFloat = 28
        guard frame.width > side, frame.height > side,
            let symbol = NSImage(
                systemSymbolName: Self.fallbackSymbol,
                accessibilityDescription: "Image unavailable")
        else { return }

        let tinted = symbol.withSymbolConfiguration(
            .init(pointSize: side, weight: .regular)
                .applying(.init(paletteColors: [NSColor.secondaryLabelColor])))
        tinted?.draw(
            in: CGRect(
                x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side))
    }

    /// The tile's outline, with `outerRadius` on the corners the mosaic marked as
    /// the group's own and `innerRadius` everywhere else.
    ///
    /// Tangent arcs rather than a rounded-rect convenience because the four radii
    /// differ; the traversal is Telegram's, re-labelled for a flipped view where
    /// `minY` is the top edge rather than the bottom.
    private static func roundedPath(in rect: CGRect, outerCorners: MosaicLayout.Corners) -> CGPath {
        func radius(_ corner: MosaicLayout.Corners) -> CGFloat {
            outerCorners.contains(corner) ? outerRadius : innerRadius
        }

        let path = CGMutablePath()
        let minX = rect.minX
        let midX = rect.midX
        let maxX = rect.maxX
        let minY = rect.minY
        let midY = rect.midY
        let maxY = rect.maxY

        path.move(to: CGPoint(x: minX, y: midY))
        path.addArc(
            tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: midX, y: minY),
            radius: radius(.topLeft))
        path.addArc(
            tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: midY),
            radius: radius(.topRight))
        path.addArc(
            tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: midX, y: maxY),
            radius: radius(.bottomRight))
        path.addArc(
            tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: midY),
            radius: radius(.bottomLeft))
        path.closeSubpath()
        return path
    }

    // MARK: - The press

    /// A press is a click on the tile it went down in and came back up in.
    ///
    /// Tracked across the pair rather than acted on at `mouseDown`, so a drag
    /// that starts on a picture and ends somewhere else opens nothing — the same
    /// rule `BlockView` applies to a link, and the reason both feel like buttons
    /// rather than like tripwires.
    private var pressedTile: Int?

    public override func mouseDown(with event: NSEvent) {
        pressedTile = tileIndex(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        defer { pressedTile = nil }
        let index = tileIndex(at: convert(event.locationInWindow, from: nil))
        guard let index, index == pressedTile else { return }
        onActivate?(index, layout.tiles[index].frame.offsetBy(dx: blockOrigin, dy: 0))
    }

    private func tileIndex(at point: CGPoint) -> Int? {
        let inBlock = CGPoint(x: point.x - blockOrigin, y: point.y)
        return layout.tiles.firstIndex { $0.frame.contains(inBlock) }
    }

    // MARK: - The still the flight carries

    /// What tile `index` currently looks like on screen: cropped the way the
    /// mosaic cropped it, rounded the way its own corners are rounded.
    ///
    /// For `MediaOverlayWindow`'s crossfade, which needs the *source's*
    /// appearance and cannot derive it — the corner radii differ per tile
    /// depending on where in the group it landed, and the crop is the layout's
    /// decision rather than the picture's. Rasterising what is already there
    /// settles both without either crossing the seam as data.
    ///
    /// `cacheDisplay` does capture the tile layers as well as this view's own
    /// drawing — measured, and the opposite would have been a quiet class of
    /// blank-looking stills.
    public func snapshot(ofTile index: Int) -> NSImage? {
        guard index >= 0, index < layout.tiles.count else { return nil }
        let frame = layout.tiles[index].frame.offsetBy(dx: blockOrigin, dy: 0)
        guard frame.width > 0, frame.height > 0,
            let rep = bitmapImageRepForCachingDisplay(in: frame)
        else { return nil }
        cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        return image
    }
}
