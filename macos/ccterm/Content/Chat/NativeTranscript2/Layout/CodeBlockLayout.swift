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
/// - **Copy icon** (right edge): always visible. The `CopyChrome`
///   primitive owns symbol / hover bg / tint / flash; this layout
///   only emits one via `CopyChrome.topRight(of:)`.
///
/// The copy button itself is **not drawn in `draw(in:origin:)`**.
/// `BlockCellView` invokes `copy?.draw(...)` after `draw` so the
/// icon paints on top of the body, matching the gutter's late-paint
/// position.
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

    /// The single copy-button affordance for this block — `nil` if
    /// the container is pathologically narrow. Cell hit-tests against
    /// `copy?.hitRect` (via `RowLayout.interactiveHits`) and paints it
    /// via `copy?.draw(...)` after the main glyph pass.
    let copy: CopyChrome?

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    /// Code blocks have no inline links (verbatim text).
    var links: [TextLayout.LinkHit] { [] }

    /// `language` is the info-string from the opening fence (`nil` for
    /// indented blocks); rendered as the chip-styled badge,
    /// lowercased and trimmed. `tokens` is the optional output of
    /// `Transcript2HighlightStorage`: `nil` (no scan yet, or no engine,
    /// or unsupported language) renders plain monospace; non-nil
    /// produces a colored attributed string. Glyph layout is identical
    /// either way — a token swap-in does not change `totalHeight`, so
    /// the coordinator's tokens-filled callback only needs
    /// `reloadData(forRowIndexes:)`, no `noteHeightOfRows`.
    ///
    /// `copyButtonId` keys the post-click flash on `BlockCellView`. The
    /// coordinator passes the host `Block.id`, which is caller-supplied
    /// and stable across re-layouts — so the flash survives token
    /// back-fill / width changes / hover transitions for the same block.
    nonisolated static func make(
        code: String, language: String?,
        tokens: [SyntaxToken]?, copyButtonId: UUID, maxWidth: CGFloat
    ) -> CodeBlockLayout {
        guard maxWidth > 0 else {
            return CodeBlockLayout(
                text: .empty, code: code,
                containerRect: .zero,
                textOriginInLayout: .zero,
                chromeRowMidY: 0,
                langLine: nil, langOriginInLayout: .zero,
                badgeRect: nil,
                copy: nil,
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
        let chromeHeight = BlockStyle.gutterHitSize
        let chromeMidY = chromeTop + chromeHeight / 2

        // Copy icon — right-anchored via the shared `CopyChrome.topRight`
        // factory. Returns `nil` when the container is too narrow to
        // host the chrome past the right inset.
        let copy = CopyChrome.topRight(
            of: container, id: copyButtonId, text: code)
        // Bail again on a "fits inset but not the body padding" edge —
        // codeblock predates the shared factory and used to clamp
        // against `bubbleHorizontalPadding` so the icon never crowded
        // body glyphs on a pathologically narrow row.
        let resolvedCopy: CopyChrome? = {
            guard let copy else { return nil }
            return copy.hitRect.minX >= BlockStyle.bubbleHorizontalPadding
                ? copy : nil
        }()
        let copyLeftEdge =
            resolvedCopy?.hitRect.minX
            ?? (container.maxX - BlockStyle.codeBlockChromeRightInset)

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
                (resolvedCopy != nil)
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
            copy: resolvedCopy,
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
        // `copy?.draw(...)` after this method returns. `CopyChrome`
        // owns the visual recipe (symbol, tint, size, hover background);
        // cell owns the trigger (its transient `copyFlashByActionId`
        // dict + `hoveredAction`).
    }
}
