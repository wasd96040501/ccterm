import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.glob` — one rounded
/// card listing matched filenames (monospaced, newline-joined),
/// optionally followed by an "… truncated" trailer line inside the
/// same card. Uses `TextCardSection`'s shared chrome so the visual
/// tier matches the rest of the tool-group child bodies.
///
/// The truncation trailer ships as part of the same attributed
/// string rather than as a separate card — it reads as a single
/// "this list was clipped" hint glued to the bottom row, not as a
/// distinct chrome block.
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct GlobChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: GlobChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> GlobChildLayout {
        var specs: [TextCardSection.Spec] = []
        if !child.filenames.isEmpty || child.truncated {
            specs.append(.init(
                text: "",
                attributed: buildAttributed(
                    filenames: child.filenames,
                    truncated: child.truncated)))
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return GlobChildLayout(
            containerRect: container, sections: sections)
    }

    /// Assemble the card's attributed string: `\n`-joined filenames
    /// in `labelColor`, optionally trailed by "… truncated" in
    /// `secondaryLabelColor` (12pt regular system font matches the
    /// old SwiftUI block's chrome line).
    nonisolated private static func buildAttributed(
        filenames: [String], truncated: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = BlockStyle.codeBlockFont
        if !filenames.isEmpty {
            let joined = filenames.joined(separator: "\n")
                .trimmingTrailingWhitespace
            result.append(NSAttributedString(string: joined, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        if truncated {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont,
                ]))
            }
            let trailerFont = NSFont.systemFont(ofSize: 11, weight: .regular)
            result.append(NSAttributedString(
                string: "… truncated",
                attributes: [
                    .font: trailerFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
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
