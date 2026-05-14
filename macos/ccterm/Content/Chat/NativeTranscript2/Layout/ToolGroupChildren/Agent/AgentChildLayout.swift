import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.agent` — up to two
/// rounded cards stacked vertically:
///
/// 1. **Progress** — each `progress` entry on its own line, prefixed
///    with `↳ ` in secondary tint. Suppressed when `progress.isEmpty`.
/// 2. **Output** — the sub-agent's final text in body font. Suppressed
///    when `output` is `nil` / empty.
///
/// Both cards share `TextCardSection`'s shared chrome (rounded 6pt
/// card + section spacing) so the body matches Bash / Grep visually.
///
/// ```
/// ┌── containerRect ─────────────────────────────────┐
/// │ ╭──────────────────────────────────────────────╮ │  ← progress card
/// │ │  ↳ Searching documentation…                  │ │
/// │ │  ↳ Found 12 matches                          │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// │ ╭──────────────────────────────────────────────╮ │  ← output card
/// │ │  Found 12 TODO comments across 7 files.      │ │
/// │ ╰──────────────────────────────────────────────╯ │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct AgentChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: AgentChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> AgentChildLayout {
        var specs: [TextCardSection.Spec] = []
        if !child.progress.isEmpty {
            specs.append(.init(
                text: "",
                attributed: buildProgressAttributed(child.progress)))
        }
        if let output = child.output?.trimmingTrailingWhitespace,
           !output.isEmpty
        {
            let attr = NSAttributedString(string: output, attributes: [
                .font: BlockStyle.paragraphFont,
                .foregroundColor: NSColor.labelColor,
            ])
            specs.append(.init(text: "", attributed: attr))
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return AgentChildLayout(
            containerRect: container, sections: sections)
    }

    /// Compose every progress entry as `↳ <text>` on its own line.
    /// Prefix glyph is `secondaryLabel` (same recipe as old
    /// SwiftUI `AgentBlock`'s `arrow.turn.down.right` icon), entry
    /// body is `labelColor`.
    nonisolated private static func buildProgressAttributed(
        _ entries: [String]
    ) -> NSAttributedString {
        let bodyFont = BlockStyle.paragraphFont
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let result = NSMutableAttributedString()
        for (index, raw) in entries.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n",
                                                  attributes: prefixAttrs))
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result.append(NSAttributedString(
                string: "↳ ", attributes: prefixAttrs))
            result.append(NSAttributedString(
                string: trimmed, attributes: textAttrs))
        }
        return result
    }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.drawBackplates(sections, in: ctx, origin: origin)
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        TextCardSection.draw(sections, in: ctx, origin: origin)
    }
}
