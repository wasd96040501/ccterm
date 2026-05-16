import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.askUserQuestion` —
/// one rounded card listing every Q&A pair. Question lines are
/// `semibold` body size; the answer (when present) follows on the
/// next line in secondary tint. Pending answers render as
/// `awaiting answer…` (italic, even more muted) so a still-pending
/// row reads as distinct from "answered with empty string."
///
/// ```
/// ╭──────────────────────────────────────────────╮
/// │  Which framework should we use?              │
/// │  NavigationSplitView                         │
/// │                                              │
/// │  Should the sidebar be collapsible?          │
/// │  awaiting answer…                            │
/// ╰──────────────────────────────────────────────╯
/// ```
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct AskUserQuestionChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: AskUserQuestionChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> AskUserQuestionChildLayout {
        var specs: [TextCardSection.Spec] = []
        if !child.items.isEmpty {
            specs.append(
                .init(
                    text: "",
                    attributed: buildAttributed(items: child.items)))
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return AskUserQuestionChildLayout(
            containerRect: container, sections: sections)
    }

    nonisolated private static func buildAttributed(
        items: [AskUserQuestionChild.Item]
    ) -> NSAttributedString {
        let bodyFont = BlockStyle.paragraphFont
        let questionFont = NSFont.systemFont(
            ofSize: bodyFont.pointSize, weight: .semibold)
        let answerFont = bodyFont

        let questionAttrs: [NSAttributedString.Key: Any] = [
            .font: questionFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let answerAttrs: [NSAttributedString.Key: Any] = [
            .font: answerFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // Pending answer slot — italic + tertiary tint so the row
        // reads as "still waiting" without a chrome separator.
        let pendingDescriptor = answerFont.fontDescriptor
            .withSymbolicTraits(.italic)
        let pendingFont =
            NSFont(
                descriptor: pendingDescriptor,
                size: answerFont.pointSize) ?? answerFont
        let pendingAttrs: [NSAttributedString.Key: Any] = [
            .font: pendingFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let newlineAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont]

        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(
                    NSAttributedString(
                        string: "\n\n",
                        attributes: newlineAttrs))
            }
            result.append(
                NSAttributedString(
                    string: item.question, attributes: questionAttrs))
            result.append(
                NSAttributedString(
                    string: "\n",
                    attributes: newlineAttrs))
            if let answer = item.answer?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !answer.isEmpty
            {
                result.append(
                    NSAttributedString(
                        string: answer, attributes: answerAttrs))
            } else {
                result.append(
                    NSAttributedString(
                        string: String(localized: "awaiting answer…"),
                        attributes: pendingAttrs))
            }
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
