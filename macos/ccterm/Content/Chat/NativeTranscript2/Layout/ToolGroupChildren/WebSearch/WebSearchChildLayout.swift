import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.webSearch` — one
/// rounded card listing every result as a 2–3 line block (title +
/// url, optionally + snippet). Title uses the body font in
/// `semibold`, URL is monospaced muted, snippet runs in body font
/// secondary tint with a soft 3-line ceiling.
///
/// ```
/// ╭──────────────────────────────────────────────╮
/// │  Swift Concurrency — the road to Swift 6     │
/// │  https://swift.org/blog/concurrency          │
/// │  Concise overview of structured concurrency. │
/// │                                              │
/// │  WWDC: Meet async/await                      │
/// │  https://developer.apple.com/videos/wwdc...  │
/// ╰──────────────────────────────────────────────╯
/// ```
///
/// Why one big attributed string per card rather than one card per
/// result: the card chrome itself is decoration; the visual unit the
/// eye scans is "this list of search hits." Stacking one card per
/// hit adds gaps + padding that reads as fragmented. Joining
/// everything into one attributed string keeps the typesetter doing
/// the work via `\n` separators while the chrome stays a single
/// rounded backdrop, matching the old SwiftUI `WebSearchBlock`'s
/// `VStack(spacing: 10)` inside one container.
///
/// `@unchecked Sendable`: holds `CTLine` references via embedded
/// `TextCardSection` values.
struct WebSearchChildLayout: @unchecked Sendable {
    let containerRect: CGRect
    let sections: [TextCardSection]

    var totalHeight: CGFloat { containerRect.height }

    nonisolated static func make(
        child: WebSearchChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> WebSearchChildLayout {
        var specs: [TextCardSection.Spec] = []
        if !child.results.isEmpty {
            specs.append(
                .init(
                    text: "",
                    attributed: buildAttributed(results: child.results)))
        }
        let (sections, height) = TextCardSection.build(
            specs: specs,
            originX: originX, originY: originY,
            maxWidth: maxWidth)
        let container = CGRect(
            x: originX, y: originY, width: maxWidth, height: height)
        return WebSearchChildLayout(
            containerRect: container, sections: sections)
    }

    /// Compose every result's `(title, url, snippet)` triple into one
    /// attributed string separated by inter-result blank lines. The
    /// per-result rhythm is `title\nurl\n(snippet\n)?\n` — the
    /// trailing blank line at the very end is trimmed so the card
    /// doesn't gain a phantom row below the last hit.
    nonisolated private static func buildAttributed(
        results: [WebSearchChild.Result]
    ) -> NSAttributedString {
        let bodyFont = BlockStyle.paragraphFont
        let titleFont = NSFont.systemFont(
            ofSize: bodyFont.pointSize, weight: .semibold)
        let urlFont = NSFont.monospacedSystemFont(
            ofSize: bodyFont.pointSize - 1, weight: .regular)
        let snippetFont = bodyFont

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let urlAttrs: [NSAttributedString.Key: Any] = [
            .font: urlFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let snippetAttrs: [NSAttributedString.Key: Any] = [
            .font: snippetFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let result = NSMutableAttributedString()
        for (index, hit) in results.enumerated() {
            if index > 0 {
                result.append(
                    NSAttributedString(
                        string: "\n\n",
                        attributes: [
                            .font: bodyFont
                        ]))
            }
            result.append(
                NSAttributedString(
                    string: hit.title, attributes: titleAttrs))
            result.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: bodyFont
                    ]))
            result.append(
                NSAttributedString(
                    string: hit.url, attributes: urlAttrs))
            if let snippet = hit.snippet?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !snippet.isEmpty
            {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont
                        ]))
                result.append(
                    NSAttributedString(
                        string: snippet, attributes: snippetAttrs))
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
