import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.bash` — renders the
/// command + optional `stdout` / `stderr` as a vertical stack of
/// rounded sub-cards via `TextCardSection`. All glyphs use the
/// system monospaced font (same size as paragraph text, matching
/// codeblock body so a bash card and a fenced code block read at
/// one tier). `stderr` cards use `.systemRed` foreground; everything
/// else uses `.labelColor`.
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
/// `selectionAdapter` — but today the adapter only routes `.diff(...)`
/// positions, so Bash cards are non-selectable. Adding selection means
/// extending `LayoutPosition` with a `.bash(childIndex:section:char:)`
/// case and threading it through the adapter.
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
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> BashChildLayout {
        var specs: [TextCardSection.Spec] = []
        specs.append(.init(text: child.command))
        if let stdout = child.stdout {
            specs.append(.init(text: stdout))
        }
        if let stderr = child.stderr {
            specs.append(.init(text: stderr, color: .systemRed))
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
