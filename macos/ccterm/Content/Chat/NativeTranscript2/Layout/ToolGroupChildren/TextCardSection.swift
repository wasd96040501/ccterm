import AppKit

/// Shared sub-card layout primitive for tool-group child bodies that
/// want to stack one or more rounded text cards vertically (Bash,
/// Grep, Glob, WebFetch, WebSearch, AskUserQuestion, Agent…).
///
/// One `TextCardSection` is one rounded card containing wrapped
/// monospaced glyphs at a given foreground colour. Caller supplies
/// the per-section `(text, color)` specs and the body geometry
/// (`originX/Y`, `maxWidth`); `build` returns the laid-out sections
/// plus the body's total height so callers can populate their
/// `containerRect`.
///
/// Why a value-typed primitive rather than a protocol or base class:
/// the only thing every consumer agrees on is the rounded-card
/// chrome + monospaced glyph column. Anything beyond that
/// (icons, multi-column layouts, prefix glyphs) belongs to the
/// specific child layout — keeping this primitive pure-value means a
/// child can use it for some sections and inline its own draw for
/// others without inheritance gymnastics.
///
/// `@unchecked Sendable`: holds `CTLine` references via the embedded
/// `TextLayout` (same posture as `BlockStyle` text-side layout
/// primitives).
struct TextCardSection: @unchecked Sendable {

    // MARK: - Style tier (shared across consumer layouts)

    /// Tight 6pt corner curve — matches `BlockStyle.structuralCornerRadius`
    /// so a sub-card sits at the same tonal tier as code blocks /
    /// diff cards / tables.
    static let cornerRadius: CGFloat = BlockStyle.structuralCornerRadius
    /// Horizontal inset between the card edge and the glyph column.
    static let horizontalPadding: CGFloat = 12
    /// Vertical inset between the card top/bottom and the first /
    /// last glyph baseline band.
    static let verticalPadding: CGFloat = 8
    /// Gap between adjacent cards inside one body stack.
    static let sectionSpacing: CGFloat = 6
    /// Background fill — reuses the diff card background so every
    /// tool-group child body reads at the same tonal level.
    static var backgroundColor: NSColor { BlockStyle.diffContainerBackground }

    /// Card rect in layout-local coords.
    let cardRect: CGRect
    /// Top-left origin for the `TextLayout`'s draw call, in
    /// layout-local coords (`cardRect.minX + hPad`, `cardRect.minY + vPad`).
    let textOrigin: CGPoint
    let text: TextLayout

    /// One section spec — body text + glyph colour. `attributes` is
    /// the escape hatch for callers that want to override the
    /// monospaced default (e.g. mixed `.semibold` titles + `.regular`
    /// body inside one section). When `nil`, `(font: codeBlockFont,
    /// color: color)` is used.
    struct Spec {
        let text: String
        let color: NSColor
        /// Optional fully-formed attributed string. When non-nil,
        /// overrides `text` + `color` (callers that pre-built an
        /// `NSAttributedString` use this; simple callers pass
        /// `(text, color)` only).
        let attributed: NSAttributedString?
        /// Per-section vertical padding override. `nil` uses
        /// `verticalPadding`. Used by sections that need tighter
        /// chrome (e.g. a single-line label card) without affecting
        /// the body-wide gap rhythm.
        let verticalPadding: CGFloat?
        /// Extra inset to the left of the text column for a caller-
        /// drawn chrome glyph (the bash prompt `$` lives here). The
        /// text origin shifts right by this amount and the wrap
        /// width shrinks accordingly; the caller is responsible for
        /// painting whatever sits in the reserved column.
        let leadingIndent: CGFloat

        init(
            text: String, color: NSColor = .labelColor,
            attributed: NSAttributedString? = nil,
            verticalPadding: CGFloat? = nil,
            leadingIndent: CGFloat = 0
        ) {
            self.text = text
            self.color = color
            self.attributed = attributed
            self.verticalPadding = verticalPadding
            self.leadingIndent = leadingIndent
        }
    }

    /// Lay out the supplied specs as a vertical stack starting at
    /// `(originX, originY)`. Returns the section list (one entry per
    /// non-empty spec) plus the stack's total height. Empty specs
    /// (after trimming trailing whitespace) are skipped — the
    /// resulting card list never contains zero-height cards.
    ///
    /// `(totalHeight == 0)` is the "no sections survived" outcome —
    /// caller treats it like a folded child (skip the body, no
    /// container).
    nonisolated static func build(
        specs: [Spec],
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> (sections: [TextCardSection], totalHeight: CGFloat) {
        guard maxWidth > 0 else { return ([], 0) }
        let hPad = horizontalPadding
        let font = BlockStyle.codeBlockFont

        var sections: [TextCardSection] = []
        var y = originY

        for spec in specs {
            let vPad = spec.verticalPadding ?? verticalPadding
            let textWidth = max(1, maxWidth - 2 * hPad - spec.leadingIndent)
            let attr: NSAttributedString
            if let preset = spec.attributed {
                attr = preset
            } else {
                let trimmed = spec.text.trimmingTrailingWhitespace
                guard !trimmed.isEmpty else { continue }
                attr = NSAttributedString(
                    string: trimmed,
                    attributes: [
                        .font: font,
                        .foregroundColor: spec.color,
                    ])
            }
            guard attr.length > 0 else { continue }
            let textLayout = TextLayout.make(
                attributed: attr, maxWidth: textWidth)
            guard textLayout.totalHeight > 0 else { continue }
            let cardH = textLayout.totalHeight + 2 * vPad
            let cardRect = CGRect(
                x: originX, y: y, width: maxWidth, height: cardH)
            let textOrigin = CGPoint(
                x: originX + hPad + spec.leadingIndent, y: y + vPad)
            sections.append(
                TextCardSection(
                    cardRect: cardRect,
                    textOrigin: textOrigin,
                    text: textLayout))
            y += cardH + sectionSpacing
        }

        // Trailing gap shouldn't count toward body height.
        if !sections.isEmpty { y -= sectionSpacing }
        let height = max(0, y - originY)
        return (sections, height)
    }

    /// Paint the rounded card fill for every section in `sections`.
    /// Called from the consumer's `drawBackplate` so the band sits
    /// under any selection rect the cell paints on top later.
    nonisolated static func drawBackplates(
        _ sections: [TextCardSection],
        in ctx: CGContext, origin: CGPoint
    ) {
        guard !sections.isEmpty else { return }
        let bg = backgroundColor.cgColor
        let r = cornerRadius
        ctx.saveGState()
        ctx.setFillColor(bg)
        for section in sections {
            let rect = section.cardRect.offsetBy(dx: origin.x, dy: origin.y)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: r, cornerHeight: r,
                transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Paint the glyph column for every section in `sections`.
    nonisolated static func draw(
        _ sections: [TextCardSection],
        in ctx: CGContext, origin: CGPoint
    ) {
        for section in sections {
            section.text.draw(
                in: ctx,
                origin: CGPoint(
                    x: origin.x + section.textOrigin.x,
                    y: origin.y + section.textOrigin.y))
        }
    }
}

extension String {
    /// Drops trailing whitespace + newlines without touching leading
    /// indentation. `String.trimmingCharacters` strips both sides;
    /// shell tool output regularly has meaningful indentation in
    /// front of `stdout` rows.
    var trimmingTrailingWhitespace: String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            guard self[prev].isWhitespace else { break }
            end = prev
        }
        return String(self[..<end])
    }
}
