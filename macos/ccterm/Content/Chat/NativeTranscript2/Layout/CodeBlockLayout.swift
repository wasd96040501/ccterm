import AppKit

/// Immutable code-block layout — pure function of `(code, language,
/// tokens, maxWidth)`.
///
/// Container: a single rounded rectangle (no header band) hosting the
/// monospaced source. Two chrome affordances **overlay** the top-right
/// corner — they do not reserve vertical space; the code body has
/// symmetric `codeBlockBodyVerticalPadding` top/bottom, and long first
/// lines pass *under* the badge / icon (Slack / Cursor convention).
/// The badge's opaque chip background keeps the label legible against
/// any underlying glyphs.
///
///   ┌──────────────────────────────────────────┐
///   │  func greet(_ na┌─────┐ ┌──┐             │
///   │      print("Hell│swift│ │📋│ \(name)")   │  ← chrome overlay
///   │  }              └─────┘ └──┘             │
///   │                                          │
///   │  func farewell() {                       │
///   │      print("Bye!")                       │
///   │  }                                       │
///   └──────────────────────────────────────────┘
///
/// - **Language badge** (left of the icon): always visible. Apple-
///   design chip (`codeBlockLanguageBadgeBackground`) with a 4pt
///   corner radius; text inside is `secondaryLabel` at
///   `codeBlockHeaderFontSize`.
/// - **Copy icon** (right edge): visible only when the row is hovered
///   — the same cell-margin-gutter convention from
///   `BlockCellView+Gutter.swift`. On icon-hover a rounded
///   background paints behind the glyph; on click the glyph flashes
///   to a checkmark for 1.5s. Geometry uses `BlockStyle.gutterHitSize`
///   so every copy affordance in the product renders as one shape.
///
/// The copy button itself is **not drawn in `draw(in:origin:)`**.
/// `BlockCellView` calls `drawCopyGlyph(...)` after `draw` so the
/// icon paints on top of the body, matching the gutter's late-paint
/// position. Layout exposes `copyCenter` / `copyHitRect` only so the
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
    /// Top-left of the code region inside the container (below the
    /// chrome row reserve).
    let textOriginInLayout: CGPoint

    /// Layout-local y at the vertical center of the chrome row.
    /// `RowLayout.firstLineCenterY` reads this so the cell-margin
    /// gutter aligns with the in-card chrome instead of the first
    /// code glyph — the gutter reads as a sibling of the in-card
    /// copy affordance.
    let chromeRowMidY: CGFloat

    /// Pre-typeset language CTLine + baseline origin — `nil` when the
    /// block has no language or the container is too narrow to fit
    /// badge + icon without intruding into the bubble horizontal
    /// padding column. Drawn in `draw(in:origin:)` directly (chrome,
    /// not selectable).
    let langLine: CTLine?
    let langOriginInLayout: CGPoint
    /// Rounded-chip background rect for the language badge in
    /// layout-local coords. `nil` when `langLine` is `nil`.
    let badgeRect: CGRect?

    /// Click target for the copy button — `nil` if the container is
    /// pathologically narrow.
    let copyHitRect: CGRect?
    /// Center for the copy glyph — sits inside the chrome row,
    /// right-anchored by `codeBlockChromeRightInset`.
    let copyCenter: CGPoint?

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    /// Code blocks have no inline links (verbatim text).
    var links: [TextLayout.LinkHit] { [] }

    /// Hit-zone size for the copy button. Reuses `gutterHitSize`
    /// (18pt) so codeblock + gutter copy affordances share one shape.
    nonisolated static var copyHitSize: CGFloat { BlockStyle.gutterHitSize }

    /// `language` is the info-string from the opening fence (`nil` for
    /// indented blocks); rendered as the chip-styled badge,
    /// lowercased and trimmed. `tokens` is the optional output of
    /// `Transcript2HighlightStorage`: `nil` (no scan yet, or no engine,
    /// or unsupported language) renders plain monospace; non-nil
    /// produces a colored attributed string. Glyph layout is identical
    /// either way — a token swap-in does not change `totalHeight`, so
    /// the coordinator's tokens-filled callback only needs
    /// `reloadData(forRowIndexes:)`, no `noteHeightOfRows`.
    nonisolated static func make(
        code: String, language: String?,
        tokens: [SyntaxToken]?, maxWidth: CGFloat
    ) -> CodeBlockLayout {
        guard maxWidth > 0 else {
            return CodeBlockLayout(
                text: .empty, code: code,
                containerRect: .zero,
                textOriginInLayout: .zero,
                chromeRowMidY: 0,
                langLine: nil, langOriginInLayout: .zero,
                badgeRect: nil,
                copyHitRect: nil, copyCenter: nil,
                totalHeight: 0, measuredWidth: 0)
        }
        let textMaxWidth = max(
            1, maxWidth - 2 * BlockStyle.bubbleHorizontalPadding)
        let attributed = BlockStyle.codeBlockAttributed(code: code, tokens: tokens)
        let text = TextLayout.make(attributed: attributed, maxWidth: textMaxWidth)

        // Chrome (badge + copy icon) is an overlay — it does not
        // reserve vertical space. The code body has symmetric top /
        // bottom padding; long first lines pass *under* the
        // top-right chrome (chip background keeps the badge legible
        // against the underlying glyphs).
        let bodyVPad = BlockStyle.codeBlockBodyVerticalPadding
        let containerHeight = bodyVPad + text.totalHeight + bodyVPad
        let container = CGRect(x: 0, y: 0, width: maxWidth, height: containerHeight)
        let textOrigin = CGPoint(
            x: BlockStyle.bubbleHorizontalPadding,
            y: bodyVPad)

        let chromeTop = BlockStyle.codeBlockChromeTopInset
        let chromeRight = BlockStyle.codeBlockChromeRightInset
        let chromeHeight = BlockStyle.gutterHitSize
        let chromeMidY = chromeTop + chromeHeight / 2

        // Copy icon — right-anchored. Hit rect's right edge sits
        // `chromeRight` from the container's right edge.
        let copyRightEdge = container.maxX - chromeRight
        let copyLeftEdge = copyRightEdge - chromeHeight
        let copyHit: CGRect?
        let copyCenter: CGPoint?
        if copyLeftEdge >= BlockStyle.bubbleHorizontalPadding {
            copyHit = CGRect(
                x: copyLeftEdge, y: chromeTop,
                width: chromeHeight, height: chromeHeight)
            copyCenter = CGPoint(
                x: copyLeftEdge + chromeHeight / 2,
                y: chromeMidY)
        } else {
            copyHit = nil
            copyCenter = nil
        }

        // Language badge — chip to the left of the icon. Baseline math
        // matches `TextLayout`'s flipped textMatrix draw path: in a
        // y-down layout the glyph's visible top is `midY - (ascent +
        // descent) / 2` and the baseline is `top + ascent`, which
        // simplifies to `midY + (ascent - descent) / 2`.
        let langText: String? = {
            guard
                let raw = language?
                    .trimmingCharacters(in: .whitespaces).lowercased(),
                !raw.isEmpty
            else { return nil }
            return raw
        }()
        let langLine: CTLine?
        let langOrigin: CGPoint
        let badgeRect: CGRect?
        if let langText {
            let font = NSFont.systemFont(
                ofSize: BlockStyle.codeBlockHeaderFontSize, weight: .medium)
            let attr = NSAttributedString(
                string: langText,
                attributes: [
                    .font: font,
                    .foregroundColor: BlockStyle.codeBlockHeaderForeground,
                ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let textWidth = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let hpad = BlockStyle.codeBlockLanguageBadgeHorizontalPadding
            let badgeWidth = textWidth + 2 * hpad
            let badgeHeight = chromeHeight
            // Anchor the badge's right edge to the copy icon's left
            // edge (or to the container right inset if there is no
            // icon room — keeps the badge visible on a degenerate
            // narrow row).
            let badgeRightEdge =
                (copyHit != nil)
                ? copyLeftEdge - BlockStyle.codeBlockChromeItemGap
                : container.maxX - BlockStyle.codeBlockChromeRightInset
            let badgeLeftEdge = badgeRightEdge - badgeWidth
            if badgeLeftEdge >= BlockStyle.bubbleHorizontalPadding {
                badgeRect = CGRect(
                    x: badgeLeftEdge, y: chromeTop,
                    width: badgeWidth, height: badgeHeight)
                let baseline = chromeMidY + (ascent - descent) / 2
                langOrigin = CGPoint(x: badgeLeftEdge + hpad, y: baseline)
                langLine = line
            } else {
                badgeRect = nil
                langLine = nil
                langOrigin = .zero
            }
        } else {
            langLine = nil
            langOrigin = .zero
            badgeRect = nil
        }

        return CodeBlockLayout(
            text: text, code: code,
            containerRect: container,
            textOriginInLayout: textOrigin,
            chromeRowMidY: chromeMidY,
            langLine: langLine,
            langOriginInLayout: langOrigin,
            badgeRect: badgeRect,
            copyHitRect: copyHit, copyCenter: copyCenter,
            totalHeight: containerHeight,
            measuredWidth: maxWidth)
    }

    // MARK: - Selection adapter

    /// Selection covers the body code only — chrome is not content.
    /// Points landing above the body region (in the chrome reserve)
    /// clamp to char 0; points below clamp to end. Both clamps are
    /// handled by `TextLayout.characterIndex`'s out-of-bounds rule
    /// plus the `y - offset.y` translation here.
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
            wordBoundary: inner.wordBoundary,
            searchableRegions: inner.searchableRegions)
    }

    // MARK: - Draw
    //
    // Split into two passes so `BlockCellView` can sandwich the
    // selection band between them:
    //
    //   1. `drawBackplate` — opaque card chrome (rounded fill).
    //      Painted *before* selection.
    //   2. selection rects (cell-driven, using `selectionAdapter`).
    //   3. `draw` — language badge + body glyphs. Painted *after*
    //      selection so glyphs land on top of the highlight band,
    //      the same ordering NSTextView uses.
    //
    // Codeblock background is opaque (Xcode editor canvas), so a
    // single-pass `draw` would re-cover the selection band drawn by
    // the cell. Other layouts have either no background or a
    // translucent one, hence `RowLayout.drawBackplate` is a no-op for
    // them.

    /// Card chrome: container fill only. No header band, no
    /// hairline. Painted by `BlockCellView` before the selection
    /// band.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        let containerAtScreen = containerRect.offsetBy(dx: origin.x, dy: origin.y)
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
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        // Language badge — always visible chrome. Chip background
        // first, then the label glyphs on top.
        if let badgeRect, let langLine {
            ctx.saveGState()
            let rect = badgeRect.offsetBy(dx: origin.x, dy: origin.y)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: BlockStyle.codeBlockLanguageBadgeCornerRadius,
                cornerHeight: BlockStyle.codeBlockLanguageBadgeCornerRadius,
                transform: nil)
            ctx.setFillColor(BlockStyle.codeBlockLanguageBadgeBackground.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: origin.x + langOriginInLayout.x,
                y: origin.y + langOriginInLayout.y)
            CTLineDraw(langLine, ctx)
            ctx.restoreGState()
        }

        // Code body text.
        text.draw(
            in: ctx,
            origin: CGPoint(
                x: origin.x + textOriginInLayout.x,
                y: origin.y + textOriginInLayout.y))

        // The copy glyph itself is dispatched by `BlockCellView` via
        // `drawCopyGlyph(...)` after this method returns. Layout owns
        // the visual recipe (symbol, tint, size, hover background);
        // cell owns the trigger (its transient `copiedAt` state +
        // `cellHovered` + `hoveredAction`).
    }

    /// Renders the copy glyph at `copyCenter` (offset by `origin`).
    /// Mirrors the cell-margin gutter:
    ///
    /// - `cellHovered == false` → paint nothing (icon only surfaces
    ///   when the row is the focus of attention).
    /// - `iconHovered == true` → paint a rounded hover background
    ///   behind the glyph (`gutterHoverBackground`).
    /// - `checked == true` → swap `doc.on.doc` ↔ `checkmark` for the
    ///   post-click feedback flash.
    ///
    /// Cell decides when to call this; this method owns symbol name /
    /// tint / size / draw orientation so future visual tweaks land in
    /// one place.
    func drawCopyGlyph(
        in ctx: CGContext, origin: CGPoint,
        cellHovered: Bool, iconHovered: Bool, checked: Bool
    ) {
        guard cellHovered else { return }
        guard let center = copyCenter, let hit = copyHitRect else { return }

        if iconHovered {
            let bg = hit.offsetBy(dx: origin.x, dy: origin.y)
            let path = CGPath(
                roundedRect: bg,
                cornerWidth: BlockStyle.gutterHoverCornerRadius,
                cornerHeight: BlockStyle.gutterHoverCornerRadius,
                transform: nil)
            ctx.setFillColor(BlockStyle.gutterHoverBackground.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        let centerInRow = CGPoint(
            x: center.x + origin.x, y: center.y + origin.y)
        let name = checked ? "checkmark" : "doc.on.doc"
        // Tints mirror the gutter exactly: hover brightens to
        // `gutterHoverForeground`, idle stays at `gutterIdleForeground`.
        let tint: NSColor =
            iconHovered
            ? BlockStyle.gutterHoverForeground
            : BlockStyle.gutterIdleForeground
        let weight: NSFont.Weight = checked ? .semibold : .regular
        let baseConfig = NSImage.SymbolConfiguration(
            pointSize: BlockStyle.gutterSymbolPointSize, weight: weight)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        let config = baseConfig.applying(colorConfig)
        guard
            let symbol = NSImage(
                systemSymbolName: name,
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
        symbol.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
