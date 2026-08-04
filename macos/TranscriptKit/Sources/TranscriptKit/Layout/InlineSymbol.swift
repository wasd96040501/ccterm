import AppKit
import CoreText

/// An SF Symbol occupying a position in a line of text — the link glyph before a
/// destination, the picture glyph standing in for an image.
///
/// **Not an `NSTextAttachment`.** Attachments are TextKit's, and nothing here
/// goes through TextKit: the typesetter is `CTTypesetter`, which ignores them.
/// Core Text's equivalent is a `CTRunDelegate` — one character in the string,
/// U+FFFC, whose advance the delegate reports — and that is what this is. The
/// consequence worth knowing is that the symbol **is** a character: it takes one
/// position in the index space, a drag runs over it, and `TypesetText` is what
/// keeps it from reaching the pasteboard.
///
/// ## Where the numbers come from
///
/// Every SF Symbol image publishes an `alignmentRect`: a box whose bottom edge is
/// the symbol's own baseline. Scaling the artwork until that box is a chosen
/// height, and seating its bottom on the text's baseline, places a symbol without
/// a single fudge factor — all that is left to pick is the height.
///
/// **Size: the x-height, not the cap height.** Matching cap height is what
/// Apple's own point-size configuration does (`link` at 12 / 14 / 20pt reports
/// alignment heights of 8.5 / 10.0 / 14.0 against cap heights of 8.46 / 9.86 /
/// 14.09), and it produces an icon around `1.3em` — right for a symbol standing
/// on its own beside a label, too heavy for one sitting mid-sentence. The web
/// settled smaller: GitHub's octicons are `1em`, Material's `1.125em`. Scaling
/// the alignment box to the x-height lands there — `link`'s canvas comes out
/// 13.9pt at 14pt text — from the symbol's own metrics rather than by taste.
///
/// **Position: the middle of the capitals, not the baseline.** This is the part
/// that does not follow from the alignment rect, and the measurement that says so
/// is worth keeping. Rendering `H · symbol · H` and reading the ink back, Apple's
/// own inline symbols centre on 4.88pt above the baseline at 14pt, against an
/// `H` whose own centre is 4.94 — dead centre of the capital band. Seating the
/// alignment box on the baseline reproduces that *only at the size Apple drew it
/// for*: shrink the artwork around a bottom-edge anchor and its mass slides down
/// with it, which measured −1.0pt for `link` and −1.25pt for `photo` and reads
/// exactly as low as it sounds.
///
/// So the anchor is the cap band's centre. That is `vertical-align: middle` taken
/// against capitals rather than the x-height CSS actually uses — the thing
/// `csswg-drafts#4707` exists to ask for — and it is where Telegram lands from a
/// different direction, centring inline items on the whole line box
/// (`TextNode.addEmbeddedItem`, ~4.3pt above the baseline at this size).
///
/// The artwork's canvas is larger than the alignment box on every side, and it is
/// drawn at its full size: the padding is part of the symbol's design, and
/// cropping to the alignment box would clip the parts of a glyph meant to sit
/// above the capitals or below the baseline.
///
/// ## Why the proportions are recorded rather than read
///
/// `alignmentRect` is a property of an `NSImage`, and a symbol is built while
/// *measuring*, which the package promises runs off the main actor
/// (`OffMainMeasureTests`). So the two numbers per symbol are written down in
/// `Design` and checked against the live image by a test that runs on main —
/// which is the arrangement that keeps the measuring path free of AppKit image
/// loading without letting the constants drift.
struct InlineSymbol {

    /// One symbol's published proportions, in the units of its own artwork.
    ///
    /// Both fields are read straight off `NSImage(systemSymbolName:)`;
    /// `InlineSymbolTests` asserts they still match. Adding a symbol means adding
    /// a case here and a line to that test — not reading the image at measure
    /// time.
    struct Design: Equatable {
        let name: String

        /// The artwork's own size.
        let canvas: CGSize

        /// The image's `alignmentRect`, in AppKit's bottom-left-origin image
        /// space: `minY` is how far the artwork extends below the baseline, and
        /// `height` is the cap height it wants to match.
        let alignment: CGRect

        static let link = Design(
            name: "link",
            canvas: CGSize(width: 17, height: 17),
            alignment: CGRect(x: 0, y: 3.5, width: 16.5, height: 9))

        static let image = Design(
            name: "photo",
            canvas: CGSize(width: 18, height: 14),
            alignment: CGRect(x: 0, y: 2.5, width: 18, height: 9))
    }

    let design: Design

    /// The artwork's box at this font's size — larger than the alignment box,
    /// because the canvas is.
    let box: CGSize

    /// The band the artwork is centred on: capitals, measured from the baseline.
    let capHeight: CGFloat

    /// How far the artwork's left edge sits **before** the pen — zero for every
    /// symbol used here, kept because `alignmentRect.minX` is free to be
    /// otherwise and a silent assumption is worse than a multiplication.
    let leadingInset: CGFloat

    /// What the symbol claims horizontally: the alignment box's width, which is
    /// the ink, not the canvas. Padding the artwork carries for its own reasons
    /// is not space the line has to give it.
    let inkWidth: CGFloat

    /// Space between the glyph and whatever follows it. Part of the advance the
    /// run delegate reports, so it survives line breaking rather than being a gap
    /// someone has to remember to add.
    ///
    /// A quarter of the point size — what Material Design puts between an inline
    /// icon and its label, and within a hair of the 4-on-16 GitHub uses.
    let trailingGap: CGFloat

    /// The line box the symbol claims: the surrounding font's own. Reporting the
    /// artwork's instead would make a line holding a link taller than the same
    /// line without one, and reporting nothing would collapse a line that holds
    /// only a symbol.
    let ascent: CGFloat
    let descent: CGFloat

    let color: NSColor

    /// The whole advance this symbol claims in a line.
    var advance: CGFloat { inkWidth + trailingGap }

    init(_ design: Design, font: NSFont, color: NSColor) {
        // The one scale factor in the type: everything else is this times a
        // number the symbol published.
        let scale = font.xHeight / design.alignment.height

        self.design = design
        self.box = CGSize(
            width: design.canvas.width * scale, height: design.canvas.height * scale)
        self.capHeight = font.capHeight
        self.leadingInset = design.alignment.minX * scale
        self.inkWidth = design.alignment.width * scale
        self.trailingGap = (font.pointSize * 0.25).rounded()
        self.ascent = font.ascender
        self.descent = -font.descender
        self.color = color
    }

    // MARK: - As text

    /// The one-character run this symbol occupies: U+FFFC, a `CTRunDelegate`
    /// reserving the advance, and the symbol itself for whoever draws it.
    ///
    /// `font` is carried too, so that the run has a face to fall back on if the
    /// delegate is ever absent and the placeholder has to be laid out as an
    /// ordinary character.
    func attributedString(font: NSFont) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .inlineSymbol: self]
        if let delegate = runDelegate() {
            attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] = delegate
        }
        return NSAttributedString(string: String(Self.placeholder), attributes: attributes)
    }

    /// U+FFFC OBJECT REPLACEMENT CHARACTER — what every text system uses to mean
    /// "something that is not a glyph sits here", and what `TypesetText` strips
    /// back out on the way to the pasteboard.
    static let placeholder: Character = "\u{FFFC}"

    private func runDelegate() -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { Unmanaged<Metrics>.fromOpaque($0).release() },
            getAscent: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().ascent },
            getDescent: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().descent },
            getWidth: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().width })

        // The one manual lifetime in the package: Core Text holds the payload as
        // an opaque pointer, so it is retained here and released by the `dealloc`
        // callback above when the delegate itself goes.
        let metrics = Metrics(ascent: ascent, descent: descent, width: advance)
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque())
    }

    private final class Metrics {
        let ascent: CGFloat
        let descent: CGFloat
        let width: CGFloat

        init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
            self.ascent = ascent
            self.descent = descent
            self.width = width
        }
    }

    // MARK: - Drawing

    /// Where the artwork goes, given the pen position and baseline the line
    /// broke to — in the **flipped** coordinates everything else here uses.
    ///
    /// The whole placement, in one expression, and the reason it is here rather
    /// than at the call site: `ShapedText` knows where the line's baseline landed
    /// and nothing else about symbols.
    func frame(pen: CGFloat, baseline: CGFloat) -> CGRect {
        CGRect(
            x: pen - leadingInset,
            // Centred on the capital band — `baseline - capHeight / 2` is that
            // band's middle in the y-down space everything here is stated in.
            y: baseline - capHeight / 2 - box.height / 2,
            width: box.width,
            height: box.height)
    }

    /// Draws the glyph into `rect`, which `frame(pen:baseline:)` produced and
    /// which the artwork fills exactly — no fitting, no centring, because the
    /// rectangle was derived from the artwork's own proportions.
    ///
    /// Rasterised now rather than at measure time, and tinted by the `NSColor`
    /// rather than baked: both follow from the appearance being a draw-time fact.
    /// A light/dark flip repaints (`BlockView.viewDidChangeEffectiveAppearance`)
    /// and the symbol resolves again, the same way every other colour here does.
    func draw(in rect: CGRect, into ctx: CGContext) {
        // Snapped to whole device pixels first, and the bitmap asked for *after*,
        // so that the size rendered is the size drawn. A bitmap landing on a half
        // pixel is resampled across two, which reads as the whole glyph being out
        // of focus — text escapes this because glyphs are rendered per position,
        // and an image is not.
        let snapped = ctx.convertToUserSpace(ctx.convertToDeviceSpace(rect).integral)
        guard let image = Self.rasterized(design: design, size: snapped.size, color: color) else {
            return
        }

        ctx.saveGState()
        // A `CGImage` is sampled bottom-up. Undoing the flip over the symbol's own
        // box — rather than over the whole context — keeps the arithmetic local.
        ctx.translateBy(x: 0, y: snapped.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(
            image,
            in: CGRect(x: snapped.minX, y: 0, width: snapped.width, height: snapped.height))
        ctx.restoreGState()
    }

    /// Symbols are few and repeat on every line that holds a link, so the
    /// rasterisation is cached. The appearance is part of the key because the
    /// colour was resolved into the bitmap; `NSCache` rather than a dictionary
    /// because this is reached from `draw(_:)` and it evicts under pressure on
    /// its own.
    ///
    /// Drawn into a bitmap of a stated pixel size rather than asked for with
    /// `cgImage(forProposedRect:)`.
    ///
    /// That call takes the rect as a *hint*: for a symbol it hands back the
    /// artwork's natural representation and leaves the caller to scale it, which
    /// is a resample of a small bitmap up to retina — visibly soft, and the whole
    /// reason this does the rendering itself. Here the context's scale factor is
    /// pixels-over-points, so `draw(in:)` rasterises the vector artwork at
    /// exactly the density it will be composited at.
    private static func rasterized(
        design: Design, size: CGSize, color: NSColor
    ) -> CGImage? {
        // Three, not two: the cache is keyed on the *point* size, and a window
        // dragged onto a retina display would otherwise keep a 1× entry. Symbols
        // are a handful of small bitmaps either way.
        let pixels = CGSize(
            width: (size.width * 3).rounded(.up), height: (size.height * 3).rounded(.up))
        guard pixels.width > 0, pixels.height > 0 else { return nil }

        let key =
            "\(design.name)|\(pixels.width)x\(pixels.height)|\(color)"
            + "|\(NSAppearance.currentDrawing().name.rawValue)"
        if let hit = cache.object(forKey: key as NSString) { return hit }

        guard
            let image = NSImage(systemSymbolName: design.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])),
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        // Before the context is built, not after: the rep's point size against
        // its pixel count is what sets the context's scale, and a context made
        // first captures the default — one point per pixel — leaving the artwork
        // drawn into a third of the bitmap.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let rendered = rep.cgImage else { return nil }
        cache.setObject(rendered, forKey: key as NSString)
        return rendered
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        // A handful of symbols across two appearances and a few sizes. The limit
        // is a backstop against a caller minting dynamic colours per parse, not a
        // budget anything here is expected to reach.
        cache.countLimit = 64
        return cache
    }()
}

extension NSAttributedString.Key {

    /// Carries the `InlineSymbol` that the U+FFFC under it stands for.
    ///
    /// Separate from `kCTRunDelegateAttributeName`, which Core Text owns and
    /// which reports geometry but hands nothing back at draw time — the delegate
    /// answers "how much room", this answers "what goes in it".
    static let inlineSymbol = NSAttributedString.Key("TranscriptKitInlineSymbol")
}
