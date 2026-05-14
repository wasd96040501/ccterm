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
/// ```
/// ┌── containerRect ─────────────────────────────────┐
/// │ ╭──────────────────────────────────────────────╮ │  ← command card
/// │ │  make build                                  │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// │ ╭──────────────────────────────────────────────╮ │  ← stdout card
/// │ │  ** BUILD SUCCEEDED **                       │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// │ ╭──────────────────────────────────────────────╮ │  ← stderr card (red)
/// │ │  warning: deprecated API                     │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// Selection lands inside the body cards via `ToolGroupLayout`'s
/// `selectionAdapter`, which builds per-section regions over the
/// `sections` list and routes `LayoutPosition.textCard(...)`
/// positions through each section's `TextLayout`. Drag-select clamps
/// to the section the gesture started in — moving from `command`
/// into `stdout` doesn't extend the selection across the chrome gap.
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct BashChildLayout: @unchecked Sendable {
    /// Body bounds in layout-local coords.
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: BashChild,
        commandTokens: [SyntaxToken]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> BashChildLayout {
        let font = BlockStyle.codeBlockFont

        var specs: [TextCardSection.Spec] = []

        // Command card — syntax-highlighted via hljs `bash` when
        // tokens have landed, plain `.labelColor` otherwise. We pass
        // through `BlockStyle.codeBlockAttributed` (the same builder
        // fenced code blocks use) so dynamic NSColors track light/
        // dark appearance per token scope.
        let trimmedCommand = child.command.trimmingTrailingWhitespace
        if !trimmedCommand.isEmpty {
            specs.append(.init(
                text: trimmedCommand,
                attributed: BlockStyle.codeBlockAttributed(
                    code: trimmedCommand, tokens: commandTokens)))
        }

        if let stdout = child.stdout {
            let trimmed = stdout.trimmingTrailingWhitespace
            if !trimmed.isEmpty {
                specs.append(.init(
                    text: trimmed,
                    attributed: ANSIAttributedBuilder.attributed(
                        from: trimmed, baseFont: font,
                        baseColor: .labelColor)))
            }
        }
        if let stderr = child.stderr {
            let trimmed = stderr.trimmingTrailingWhitespace
            if !trimmed.isEmpty {
                specs.append(.init(
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
        return BashChildLayout(
            containerRect: container, sections: sections)
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.drawBackplates(sections, in: ctx, origin: origin)
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.draw(sections, in: ctx, origin: origin)
    }
}
