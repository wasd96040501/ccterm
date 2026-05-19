import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.bash` — renders the
/// command + optional `stdout` / `stderr` as a vertical stack of
/// rounded sub-cards via `TextCardSection`. All glyphs use the
/// system monospaced font (same size as paragraph text, matching
/// codeblock body so a bash card and a fenced code block read at
/// one tier).
///
/// **Command** is syntax-highlighted as `bash` via
/// `Transcript2HighlightStorage` — same async tokenise pipeline that
/// powers fenced code blocks. The cold-render path falls back to
/// plain `.labelColor`; once tokens arrive, `BashChildHighlight`'s
/// `.tokens` `HighlightValue` lands here and the command card
/// recolors on next layout build.
///
/// **stdout / stderr** are ANSI-aware — SGR escape sequences inside
/// the stream are parsed by `ANSIAttributedBuilder` so terminal
/// colours / bold / dim / underline render the same way as the
/// React-side `BashBlock`. stderr defaults to `.systemRed` for any
/// run that didn't carry its own SGR colour.
///
/// **Chrome** — the command card reserves a left column for a
/// non-selectable `$` prompt glyph, and every card (command / stdout
/// / stderr) hosts a copy-icon overlay at the top-right. Posture
/// mirrors the codeblock chrome from PR #124: the icon is always
/// visible, hover paints a rounded background, click flashes a
/// checkmark for 1.5s. No language badge — bash is implicit.
///
/// ```
/// ┌── containerRect ─────────────────────────────────┐
/// │ ╭───────────────────────────────────────────┌──╮╮│  ← command card
/// │ │ $  make build                             │📋││ │
/// │ ╰─────────────────────────────────────────────╯─╯│
/// │ ╭───────────────────────────────────────────┌──╮╮│  ← stdout card
/// │ │   ** BUILD SUCCEEDED **                   │📋││ │
/// │ ╰─────────────────────────────────────────────╯─╯│
/// │ ╭───────────────────────────────────────────┌──╮╮│  ← stderr card (red)
/// │ │   warning: deprecated API                 │📋││ │
/// │ ╰─────────────────────────────────────────────╯─╯│
/// └──────────────────────────────────────────────────┘
/// ```
///
/// Selection lands inside the body cards via `ToolGroupLayout`'s
/// `selectionAdapter`, which builds per-section regions over the
/// `sections` list and routes `LayoutPosition.textCard(...)`
/// positions through each section's `TextLayout`. The `$` prompt
/// lives outside every section's `TextLayout`, so drag-select on
/// the command card picks up `make build`, never `$ make build`.
/// Drag-select clamps to the section the gesture started in —
/// moving from `command` into `stdout` doesn't extend the selection
/// across the chrome gap.
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct BashChildLayout: @unchecked Sendable {
    /// Body bounds in layout-local coords.
    let containerRect: CGRect
    let sections: [TextCardSection]
    /// `$` prompt glyph baseline origin in layout-local coords.
    /// `nil` when the command card didn't survive `TextCardSection.build`
    /// (e.g. empty trimmed command). Drawn as chrome — not part of any
    /// section's `TextLayout`, so it stays out of selection.
    let promptOrigin: CGPoint?
    /// One copy affordance per surviving card. Order matches
    /// `sections`. `text` is the section's plain content as a
    /// pasteboard-ready string; `hitRect` / `center` are in
    /// layout-local coords. `iconHovered` / `checked` drawing state
    /// flow in from the cell via `draw(...)` parameters.
    let copyButtons: [CopyButton]

    /// Per-card copy affordance — same geometry posture as
    /// `CodeBlockLayout.copyHitRect` / `copyCenter`, repeated for
    /// every sub-card.
    struct CopyButton: @unchecked Sendable {
        let hitRect: CGRect
        let center: CGPoint
        let text: String
    }

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: BashChild,
        commandTokens: [SyntaxToken]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> BashChildLayout {
        let font = BlockStyle.codeBlockFont
        let promptIndent = BlockStyle.bashPromptColumnWidth

        var specs: [TextCardSection.Spec] = []
        // Track which section index, in the post-filter `sections`
        // array, will hold the command card. `nil` when the command
        // string trimmed to empty — no command card, no `$` glyph.
        // `TextCardSection.build` drops empty specs, so we mark via
        // a sentinel string the trimmed command we expect to find in
        // the produced section's content (sections preserve the
        // attributed string we hand them).
        var commandSpecIndex: Int? = nil

        // Command card — syntax-highlighted via hljs `bash` when
        // tokens have landed, plain `.labelColor` otherwise. We pass
        // through `BlockStyle.codeBlockAttributed` (the same builder
        // fenced code blocks use) so dynamic NSColors track light/
        // dark appearance per token scope.
        let trimmedCommand = child.command.trimmingTrailingWhitespace
        if !trimmedCommand.isEmpty {
            commandSpecIndex = specs.count
            specs.append(
                .init(
                    text: trimmedCommand,
                    attributed: BlockStyle.codeBlockAttributed(
                        code: trimmedCommand, tokens: commandTokens),
                    leadingIndent: promptIndent))
        }

        if let stdout = child.stdout {
            let trimmed = stdout.trimmingTrailingWhitespace
            if !trimmed.isEmpty {
                specs.append(
                    .init(
                        text: trimmed,
                        attributed: ANSIAttributedBuilder.attributed(
                            from: trimmed, baseFont: font,
                            baseColor: .labelColor)))
            }
        }
        if let stderr = child.stderr {
            let trimmed = stderr.trimmingTrailingWhitespace
            if !trimmed.isEmpty {
                specs.append(
                    .init(
                        text: trimmed,
                        color: .systemRed,
                        attributed: ANSIAttributedBuilder.attributed(
                            from: trimmed, baseFont: font,
                            baseColor: .systemRed)))
            }
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)

        // `$` prompt glyph baseline — sits in the reserved left column
        // of the command card, aligned to the first text line's
        // baseline. `TextCardSection.build` is order-preserving for
        // non-empty specs, so a non-nil `commandSpecIndex` from above
        // points at the same index in `sections`. Missing first-line
        // metrics is degenerate (empty TextLayout) — bail to `nil`.
        let promptOrigin: CGPoint?
        if let commandSpecIndex,
            commandSpecIndex < sections.count
        {
            let cmdSection = sections[commandSpecIndex]
            if let firstBaseline = cmdSection.text.lineOrigins.first?.y {
                promptOrigin = CGPoint(
                    x: cmdSection.cardRect.minX
                        + TextCardSection.horizontalPadding,
                    y: cmdSection.textOrigin.y + firstBaseline)
            } else {
                promptOrigin = nil
            }
        } else {
            promptOrigin = nil
        }

        // Copy buttons — top-right overlay per card, sized to the
        // gutter hit rect (18pt) and inset 8pt from the card's right
        // / top edges (same chrome posture as `CodeBlockLayout`).
        // Text payload: the section's plain content, ready for the
        // pasteboard.
        let chromeHit = BlockStyle.gutterHitSize
        let chromeInset = BlockStyle.codeBlockChromeRightInset
        let chromeTop = BlockStyle.codeBlockChromeTopInset
        var copyButtons: [CopyButton] = []
        copyButtons.reserveCapacity(sections.count)
        // The pasteboard text for the command card is the trimmed
        // command (without the chrome `$`); for the stdout / stderr
        // cards it's the trimmed stream content. The section's
        // `attributed.string` already carries the same trimmed text
        // we handed to `TextCardSection.build`, so reading it back
        // from the section is the single source of truth.
        for section in sections {
            let cardRect = section.cardRect
            let rightEdge = cardRect.maxX - chromeInset
            let leftEdge = rightEdge - chromeHit
            let hitRect = CGRect(
                x: leftEdge, y: cardRect.minY + chromeTop,
                width: chromeHit, height: chromeHit)
            let center = CGPoint(
                x: leftEdge + chromeHit / 2,
                y: cardRect.minY + chromeTop + chromeHit / 2)
            let text = section.text.attributed.string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            copyButtons.append(
                CopyButton(hitRect: hitRect, center: center, text: text))
        }

        return BashChildLayout(
            containerRect: container, sections: sections,
            promptOrigin: promptOrigin,
            copyButtons: copyButtons)
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.drawBackplates(sections, in: ctx, origin: origin)
    }

    /// `hoveredCopyText` is the text payload of the copy button the
    /// cursor is currently over (`nil` when no bash copy icon is
    /// hovered); `flashingCopyTexts` is the set of texts whose
    /// post-click checkmark window is still open. Both flow in from
    /// the cell via `BlockCellView.hoveredAction` and
    /// `copyFlashByText` — the cell rebuilds the entry subview's
    /// draw closure on every transition so the captured values
    /// stay fresh.
    func draw(
        in ctx: CGContext, origin: CGPoint,
        hoveredCopyText: String?,
        flashingCopyTexts: Set<String>
    ) {
        // Sections (rounded fills already painted by drawBackplate;
        // this is the glyph pass).
        TextCardSection.draw(sections, in: ctx, origin: origin)

        // Prompt glyph — chrome, drawn over the section glyph pass so
        // it never sits under code coloring. Painted with a CTLine
        // typeset at draw time (single short string, no cache
        // pressure).
        if let promptOrigin {
            let attr = NSAttributedString(
                string: BlockStyle.bashPromptGlyph,
                attributes: [
                    .font: BlockStyle.codeBlockFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: origin.x + promptOrigin.x,
                y: origin.y + promptOrigin.y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // Copy icons — one per card. Layout owns the visual recipe;
        // cell decides hover / flash state via the parameters above.
        for button in copyButtons {
            let iconHovered = hoveredCopyText == button.text
            let checked = flashingCopyTexts.contains(button.text)
            Self.drawCopyGlyph(
                in: ctx, origin: origin,
                hit: button.hitRect, center: button.center,
                iconHovered: iconHovered, checked: checked)
        }
    }

    /// Renders one copy glyph. Static helper so the recipe is co-
    /// located with bash's draw pass — same shape as
    /// `CodeBlockLayout.drawCopyGlyph`, repeated here for the
    /// per-card sites (a shared free function would mean exporting
    /// gutter-style chrome constants under a new namespace; the
    /// helper inside the layout is cheaper).
    nonisolated private static func drawCopyGlyph(
        in ctx: CGContext, origin: CGPoint,
        hit: CGRect, center: CGPoint,
        iconHovered: Bool, checked: Bool
    ) {
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
