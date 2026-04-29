import AppKit

/// Immutable code-block layout — pure function of `(code, maxWidth)`.
///
/// Two-band container: a 32pt **header** band carrying the copy
/// button, separated by a 1pt hairline from a body band that holds
/// the verbatim monospaced source. Container corner is the
/// "structural" tier (6pt) — code is data/precision, not personal
/// voice, so a tighter curve reads as IDE-appropriate.
///
/// The copy button itself is **not drawn here**. `BlockCellView`
/// renders an SF Symbol on top of the layout (with a per-click
/// "checkmark for 1.5s" feedback that's pure cell-local transient
/// state). Layout exposes `copyCenter` / `copyHitRect` only so the
/// cell knows where to paint and where to hit-test.
///
/// `@unchecked Sendable` — same reason as `TextLayout` (embedded
/// `CTLine` references).
struct CodeBlockLayout: @unchecked Sendable {
    let text: TextLayout
    /// Verbatim source — held so the cell's copy handler can pull it
    /// without re-decoding the attributed string.
    let code: String
    /// Container in layout-local coords (y-down). Background paints on
    /// this rect.
    let containerRect: CGRect
    /// Header band in layout-local coords (`y ∈ [0, headerHeight]`).
    /// Hairline divider sits at `headerRect.maxY`.
    let headerRect: CGRect
    /// Top-left of the code region inside the container (below the
    /// header + body top padding).
    let textOriginInLayout: CGPoint
    /// Click target for the copy button — `nil` if the container is
    /// pathologically narrow.
    let copyHitRect: CGRect?
    /// Center for the copy glyph — sits inside the header band,
    /// vertically centered, right-anchored by `codeBlockCopyRightInset`.
    let copyCenter: CGPoint?

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    /// Code blocks have no inline links (verbatim text).
    var links: [TextLayout.LinkHit] { [] }

    /// Header-row hit zone size for the copy button. Sized to fit
    /// inside the 24pt header band — a hit rect taller than the
    /// header would extend into the body, dragging the pointing-hand
    /// cursor onto code text where clicks aren't actually wired.
    nonisolated static let copyHitSize: CGFloat = 20

    nonisolated static func make(code: String, maxWidth: CGFloat) -> CodeBlockLayout {
        guard maxWidth > 0 else {
            return CodeBlockLayout(
                text: .empty, code: code,
                containerRect: .zero, headerRect: .zero,
                textOriginInLayout: .zero,
                copyHitRect: nil, copyCenter: nil,
                totalHeight: 0, measuredWidth: 0)
        }
        let textMaxWidth = max(
            1, maxWidth - 2 * BlockStyle.bubbleHorizontalPadding)
        let attributed = BlockStyle.codeBlockAttributed(code: code)
        let text = TextLayout.make(attributed: attributed, maxWidth: textMaxWidth)

        let headerH = BlockStyle.codeBlockHeaderHeight
        let bodyVPad = BlockStyle.codeBlockBodyVerticalPadding
        let containerHeight = headerH + bodyVPad + text.totalHeight + bodyVPad
        let container = CGRect(x: 0, y: 0, width: maxWidth, height: containerHeight)
        let header = CGRect(x: 0, y: 0, width: maxWidth, height: headerH)
        let textOrigin = CGPoint(
            x: BlockStyle.bubbleHorizontalPadding,
            y: headerH + bodyVPad)

        // Copy button: in-header, vertically centered, right-anchored.
        let half = copyHitSize / 2
        let center = CGPoint(
            x: container.maxX - BlockStyle.codeBlockCopyRightInset - half,
            y: header.midY)
        let copyCenter: CGPoint?
        let copyHit: CGRect?
        if container.width >= copyHitSize + 2 * BlockStyle.codeBlockCopyRightInset {
            copyCenter = center
            copyHit = CGRect(
                x: center.x - half, y: center.y - half,
                width: copyHitSize, height: copyHitSize)
        } else {
            copyCenter = nil
            copyHit = nil
        }

        return CodeBlockLayout(
            text: text, code: code,
            containerRect: container,
            headerRect: header,
            textOriginInLayout: textOrigin,
            copyHitRect: copyHit, copyCenter: copyCenter,
            totalHeight: containerHeight,
            measuredWidth: maxWidth)
    }

    // MARK: - Selection adapter

    /// Selection covers the body code only — header is chrome, not
    /// content. Points landing in the header (or anywhere above the
    /// body region) clamp to char 0 (start of code). Same for points
    /// below the body region (clamp to end), handled by the inner
    /// `TextLayout.characterIndex`'s out-of-bounds clamping plus the
    /// `y - offset.y` translation here.
    var selectionAdapter: SelectionAdapter {
        let inner = text.selectionAdapter
        let offset = textOriginInLayout
        return SelectionAdapter(
            fullRange: inner.fullRange,
            unitRange: inner.unitRange,
            hitTest: { p in
                inner.hitTest(CGPoint(x: p.x - offset.x, y: p.y - offset.y))
            },
            rects: { a, b in
                inner.rects(a, b).map {
                    $0.offsetBy(dx: offset.x, dy: offset.y)
                }
            },
            string: inner.string,
            wordBoundary: inner.wordBoundary)
    }

    // MARK: - Draw

    func draw(in ctx: CGContext, origin: CGPoint) {
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)

        // 1) Rounded background (entire container — both header and body).
        ctx.saveGState()
        let containerPath = CGPath(
            roundedRect: containerAtScreen,
            cornerWidth: BlockStyle.structuralCornerRadius,
            cornerHeight: BlockStyle.structuralCornerRadius,
            transform: nil)
        ctx.setFillColor(BlockStyle.codeBlockBackgroundColor.cgColor)
        ctx.addPath(containerPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 2) Header overlay — second translucent fill clipped to the
        //    container's rounded shape so the top corners follow the
        //    outer curve. Composes with the body fill underneath to
        //    yield a uniform "one tier darker" header band.
        ctx.saveGState()
        ctx.addPath(containerPath)
        ctx.clip()
        ctx.setFillColor(BlockStyle.codeBlockHeaderOverlayColor.cgColor)
        ctx.fill(headerRect.offsetBy(dx: origin.x, dy: origin.y))
        ctx.restoreGState()

        // 3) Hairline divider between header and body.
        ctx.saveGState()
        let dividerY = origin.y + headerRect.maxY
        ctx.setFillColor(BlockStyle.codeBlockDividerColor.cgColor)
        ctx.fill(CGRect(
            x: containerAtScreen.minX,
            y: dividerY,
            width: containerAtScreen.width,
            height: 1))
        ctx.restoreGState()

        // 4) Code body text.
        text.draw(in: ctx, origin: CGPoint(
            x: origin.x + textOriginInLayout.x,
            y: origin.y + textOriginInLayout.y))

        // The copy glyph itself is dispatched by `BlockCellView` via
        // `drawCopyGlyph(in:origin:checked:)` after this method
        // returns. Layout owns the visual recipe (symbol, tint,
        // size); cell owns the trigger (its transient `copiedAt`
        // state) — see the helper below.
    }

    /// Renders the copy glyph at `copyCenter` (offset by `origin`). The
    /// `checked` parameter swaps `doc.on.doc` ↔ `checkmark` for the
    /// post-click feedback flash. Cell decides when to call this; this
    /// method owns symbol name / tint / size / draw orientation so
    /// future visual tweaks land in one place.
    func drawCopyGlyph(in ctx: CGContext, origin: CGPoint, checked: Bool) {
        guard let center = copyCenter else { return }
        let centerInRow = CGPoint(
            x: center.x + origin.x, y: center.y + origin.y)

        let name = checked ? "checkmark" : "doc.on.doc"
        // Both states use the same muted tint — the glyph swap is the
        // feedback signal, an additional color shift would over-
        // emphasize a transient flash.
        let tint: NSColor = .secondaryLabelColor
        let weight: NSFont.Weight = checked ? .semibold : .regular
        let baseConfig = NSImage.SymbolConfiguration(
            pointSize: 11, weight: weight)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
        let config = baseConfig.applying(colorConfig)
        guard let symbol = NSImage(systemSymbolName: name,
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return }

        let size = symbol.size
        let rect = CGRect(
            x: centerInRow.x - size.width / 2,
            y: centerInRow.y - size.height / 2,
            width: size.width,
            height: size.height)

        // The cell view is flipped; pushing a graphics context with
        // `flipped: true` lets `NSImage.draw(in:respectFlipped:)`
        // composite the symbol upright.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: ctx, flipped: true)
        symbol.draw(in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
