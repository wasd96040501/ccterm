import AppKit
import Foundation

/// Render-ready block. `id` is stable identity for diffing — caller assigns.
///
/// `@unchecked Sendable`: `Kind.image` carries `NSImage`, which is mutable
/// in principle. Caller contract: **do not mutate the `NSImage` after passing
/// it to a `Block`.** The layout pipeline extracts an immutable `CGImage`
/// snapshot at `make` time, so internal use is safe regardless.
struct Block: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let kind: Kind

    enum Kind: Equatable, @unchecked Sendable {
        /// `level` is the markdown heading level, 1...6. Out-of-range values
        /// clamp inside `BlockStyle.headingAttributed`.
        case heading(level: Int, inlines: [InlineNode])
        case paragraph(inlines: [InlineNode])
        case image(NSImage)
        /// Wraps the recursive `ListBlock` (a list item can contain a nested
        /// list) — the `Kind` enum stays flat by hiding the recursion in a
        /// dedicated struct.
        case list(ListBlock)
        case table(TableBlock)
        /// Fenced or indented code block. `language` is the info string
        /// from the opening fence (`nil` for indented blocks). `code` is
        /// the verbatim source — newlines preserved, no inline parsing.
        /// Rendered as a rounded container with a copy button in the top-
        /// right corner; syntax highlighting is intentionally out of scope.
        case codeBlock(language: String?, code: String)
        /// CommonMark blockquote. Flat `[InlineNode]` payload — nested
        /// blocks inside a quote (lists, code blocks, nested quotes) are
        /// not modelled; the parser must collapse them to inlines or split
        /// them into separate sibling blocks. Rendered with a left bar
        /// and a rounded muted background.
        case blockquote(inlines: [InlineNode])
        /// `---` thematic break / horizontal rule. No payload — purely
        /// decorative spacer.
        case thematicBreak
        /// User-side message rendered as a right-aligned bubble. Long text
        /// auto-truncates with a tail "…" + a `>` chevron whose click
        /// surfaces the full message in a SwiftUI sheet (presentation
        /// concerns belong on the SwiftUI side; in-cell rendering stays
        /// stateless). Short messages render in full with no chevron.
        case userBubble(text: String)
    }
}

/// Tree-shaped list payload: top-level `ordered` flag + start index + items;
/// each item carries an optional checkbox marker and a sequence of paragraph
/// or nested-list contents. Recursion lives in `Content.list` (`indirect`),
/// matching CommonMark's list-inside-list nesting.
///
/// `startIndex` only matters for ordered lists. Defaults to 1 — the markdown
/// `1.` opener — and counts up monotonically; explicit non-1 starts (`5.`)
/// survive the round-trip.
struct ListBlock: Equatable, Sendable {
    let ordered: Bool
    let startIndex: Int
    let items: [Item]

    init(ordered: Bool, startIndex: Int = 1, items: [Item]) {
        self.ordered = ordered
        self.startIndex = startIndex
        self.items = items
    }

    struct Item: Equatable, Sendable {
        /// `nil` → use the list's bullet/ordered marker for this item;
        /// `false`/`true` → render an unchecked/checked checkbox instead
        /// (markdown task list syntax `- [ ]` / `- [x]`).
        let checkbox: Bool?
        let content: [Content]

        init(checkbox: Bool? = nil, content: [Content]) {
            self.checkbox = checkbox
            self.content = content
        }
    }

    /// `indirect` is on the enum, not the case — the recursion only occurs
    /// in `.list`, but Swift's heap-allocation rule for indirect enums is
    /// per-enum, and one indirect enum is enough.
    indirect enum Content: Equatable, Sendable {
        case paragraph([InlineNode])
        case list(ListBlock)
    }
}

/// GFM-style markdown table: 1 header row + N body rows + per-column
/// alignment. Cells are `[InlineNode]` so links / inline code / emphasis
/// inside cells survive to the renderer.
struct TableBlock: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case none, left, center, right }

    let header: [[InlineNode]]
    let rows: [[[InlineNode]]]
    let alignments: [Alignment]
}

/// Centralized typography + per-row geometry constants.
///
/// Per-kind attributed builders live here (`headingAttributed` /
/// `paragraphAttributed`). There is no `attributed(for: Block)` —
/// non-text kinds (image / table / tool) cannot be reduced to a single
/// `NSAttributedString`, so the layout pipeline switches on `Block.Kind`
/// directly and dispatches to the right primitive.
///
/// Inline emphasis (bold / italic / code / link) is supplied as `[InlineNode]`
/// trees produced by the upstream markdown parser; this layer walks the tree
/// and folds each node's styling into a single `NSAttributedString`. There is
/// no `String`-based overload — callers without a parser wrap raw text as
/// `[.text(s)]`. Keeping a single API removes the "what does `**bold**` do
/// here" ambiguity that two overloads would invite.
enum BlockStyle: Sendable {
    static let paragraphFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    /// Horizontal padding inside the row.
    nonisolated static let blockHorizontalPadding: CGFloat = 16

    /// Per-kind vertical padding (top, bottom) inside each block's row.
    ///
    /// Designed so the **actual visible gap** between adjacent blocks reads
    /// consistent across kinds, rather than letting a single constant land
    /// at one value for soft-edged text and another for hard-edged tables /
    /// images.
    ///
    /// Body kinds (`paragraph`, `list`) carry symmetric 6/6 → 12pt p↔p gap.
    /// Hard-edged kinds (`table`, `image`) carry 8/8 → +2pt over body to
    /// compensate for the leading-illusion gap loss at borders. Headings
    /// are intentionally asymmetric: a wide top (scaled to font size) marks
    /// a section break, a near-zero bottom keeps the heading glued to the
    /// content it owns. The 6pt gap below a heading is contributed entirely
    /// by the following paragraph's `top`, so the rhythm stays uniform
    /// regardless of which heading level precedes the body text.
    nonisolated static func blockPadding(
        for kind: Block.Kind
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .heading(let level, _):
            let clamped = max(1, min(6, level))
            switch clamped {
            case 1: return (top: 24, bottom: 0)
            case 2: return (top: 16, bottom: 0)
            default: return (top: 10, bottom: 0)
            }
        case .paragraph, .list, .blockquote:
            // Blockquote sits in the soft-edged tier with paragraphs —
            // it has no container chrome, only a left bar, so it should
            // share paragraphs' rhythm rather than the harder 8/8 used
            // for visible-bordered blocks.
            return (top: 6, bottom: 6)
        case .image, .table, .codeBlock:
            return (top: 8, bottom: 8)
        case .userBubble:
            // Bubble already carries its own internal vertical padding;
            // the row pad here is the gap between the bubble and the
            // adjacent row's content. 8/8 matches `image`/`table`'s
            // hard-edged spacing tier.
            return (top: 8, bottom: 8)
        case .thematicBreak:
            // Thematic break is a thin line with no glyphs — it needs
            // wider top/bottom breathing room than text-edged kinds so
            // the rule doesn't visually attach to either neighbor.
            return (top: 12, bottom: 12)
        }
    }

    /// Cap for image height — wide-and-tall sources don't dominate the viewport.
    nonisolated static let imageMaxHeight: CGFloat = 360

    // MARK: - List geometry

    /// Vertical gap between adjacent list items at any nesting depth.
    /// Matches the old `MarkdownTheme.l3Item` value — the canonical "items
    /// breathe but don't fall apart" spacing for chat content.
    nonisolated static let listItemSpacing: CGFloat = 6

    /// Same gap, applied between paragraph blocks *inside* one list item
    /// (rare in practice but specified explicitly so multi-paragraph items
    /// don't cling to each other).
    nonisolated static let listIntraItemSpacing: CGFloat = 6

    /// Space between the marker column's right edge and the content's
    /// left edge. ½ em at body size — visually identical to
    /// `MarkdownTheme.MarkdownListMetrics.gap`.
    nonisolated static var listMarkerContentGap: CGFloat {
        paragraphFont.pointSize * 0.5
    }

    /// Checkbox edge length, slightly under cap-height of the body font.
    /// Bigger reads as a button; smaller fails to register as a control.
    nonisolated static var listCheckboxSize: CGFloat {
        paragraphFont.pointSize * 0.95
    }

    nonisolated static let listMarkerColor: NSColor = .secondaryLabelColor
    nonisolated static let listCheckboxCheckedColor: NSColor = .labelColor
    nonisolated static let listCheckboxUncheckedColor: NSColor = .secondaryLabelColor

    /// Bullet glyph "•" rendered at body font weight / size.
    nonisolated static func listBulletMarkerAttributed() -> NSAttributedString {
        NSAttributedString(string: "•", attributes: [
            .font: paragraphFont,
            .foregroundColor: listMarkerColor,
        ])
    }

    /// Ordered marker "N." rendered in monospaced body font so a column of
    /// "1." / "10." / "100." aligns at the dot.
    nonisolated static func listOrderedMarkerAttributed(_ n: Int) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(
            ofSize: paragraphFont.pointSize, weight: .regular)
        return NSAttributedString(string: "\(n).", attributes: [
            .font: font,
            .foregroundColor: listMarkerColor,
        ])
    }

    // MARK: - Table geometry

    nonisolated static let tableCellHorizontalPadding: CGFloat = 8
    nonisolated static let tableCellVerticalPadding: CGFloat = 10
    /// Floor on a column's `min` width. Empty columns / single-glyph columns
    /// would otherwise collapse to a sliver under the CSS-min-content
    /// derivation.
    nonisolated static let tableMinColumnWidth: CGFloat = 40
    /// Tables sit in the "structural" tier — see
    /// `structuralCornerRadius`. A 6pt corner reads as data/grid/IDE
    /// rather than as a soft personal-voice element, matching how
    /// Slack / Discord / Xcode treat their own data containers.
    nonisolated static var tableCornerRadius: CGFloat { structuralCornerRadius }

    nonisolated static let tableBorderColor: NSColor = .separatorColor

    /// Inner row separator. Same width as the outer border but a more muted
    /// color so the body grid reads as one block rather than a busy lattice.
    /// Resolves dynamically with appearance.
    nonisolated static let tableInnerDividerColor: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0, alpha: 0.06)
    }

    /// Header row tint — distinctly deeper than the zebra stripe so the
    /// header reads as a separate band rather than another body row.
    nonisolated static let tableHeaderBackground: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.08)
    }

    /// Subtle stripe applied to odd-indexed body rows. Eye-tracking aid
    /// across long horizontal rows; intentionally near-invisible at a
    /// glance.
    nonisolated static let tableZebraBackground: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.025)
    }

    /// Build a table cell's attributed string. `bold = true` for header
    /// cells. Reuses the inline IR walker so emphasis / code / link inside
    /// cells render the same as in paragraphs.
    nonisolated static func tableCellAttributed(
        inlines: [InlineNode], bold: Bool
    ) -> NSAttributedString {
        let baseFont: NSFont = bold
            ? NSFont.systemFont(ofSize: paragraphFont.pointSize, weight: .semibold)
            : paragraphFont
        let out = NSMutableAttributedString()
        appendInlines(inlines, into: out, base: baseAttributes(font: baseFont))
        return out
    }

    // MARK: - Corner-radius tiers

    /// "Soft" tier — speech / personal voice / emotional. Larger curve
    /// reads as friendly and rounded-organic. Visual-psychology
    /// research (Bar & Neta 2006 et al.): rounded shapes trigger a
    /// "safety / approachability" response distinct from sharp shapes'
    /// "precision / authority" response. Used for chat bubbles where
    /// the metaphor is a speech balloon.
    nonisolated static let softCornerRadius: CGFloat = 14

    /// "Structural" tier — data / code / grid / precision. Tight curve
    /// reads as engineering. Slack / Discord code blocks sit at 4pt;
    /// Notion at 6pt; Xcode panels at 0–4pt. Used for table outer
    /// border and code block container — anywhere the content wants
    /// to read as authoritative / technical rather than personal.
    nonisolated static let structuralCornerRadius: CGFloat = 6

    // MARK: - User bubble geometry

    /// Hard cap on bubble width — keeps long messages from spanning the
    /// full content column and re-establishes a right-side visual weight
    /// (bubble visibly hugs the right edge instead of looking like another
    /// paragraph).
    nonisolated static let userBubbleMaxWidth: CGFloat = 560

    /// Floor on the empty space to the bubble's left when the message is
    /// long enough to wrap — guarantees the bubble never bleeds into the
    /// content column's left edge.
    nonisolated static let bubbleMinLeftGutter: CGFloat = 60

    nonisolated static let bubbleHorizontalPadding: CGFloat = 16
    /// Matched to `bubbleCornerRadius` so the rounded corner's curve
    /// does not geometrically intrude into the text-baseline region —
    /// at `R > V`, top/bottom-line glyphs visually scrape the corner;
    /// at `R == V`, the curve sits flush with the text margin and the
    /// chevron's corner-anchored position lands on a uniform `R` offset
    /// from both the right and bottom edges. Aliased to
    /// `softCornerRadius` since the bubble's corner is the canonical
    /// "soft tier" anchor.
    nonisolated static var bubbleVerticalPadding: CGFloat { softCornerRadius }
    nonisolated static var bubbleCornerRadius: CGFloat { softCornerRadius }

    /// Bubble background — system accent at 15% so the tint shifts with
    /// the user's selected accent color and dark/light appearance.
    nonisolated static let bubbleFillColor: NSColor =
        NSColor.controlAccentColor.withAlphaComponent(0.15)

    /// Lines at and above this count *may* fold (subject to `userBubbleMinHiddenLines`).
    nonisolated static let userBubbleCollapseThreshold: Int = 12
    /// Hide fewer than this many lines reads worse than not folding at
    /// all (the chevron buys nothing). Effective fold lower bound is
    /// `threshold + minHiddenLines`.
    nonisolated static let userBubbleMinHiddenLines: Int = 3

    /// Chevron glyph drawing edge length.
    nonisolated static let chevronSize: CGFloat = 10
    /// Click target edge length — expanded around the glyph rect so a 10pt
    /// chevron is comfortable to hit.
    nonisolated static let chevronHitSize: CGFloat = 20

    /// User bubble plain text → attributed. No inline IR — user input is
    /// raw text, markdown emphasis is not parsed here (that's an assistant-
    /// content concern).
    nonisolated static func userBubbleAttributed(text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: paragraphFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    // MARK: - Code block geometry

    /// Code block uses the system monospaced font at the body font's
    /// point size — picking up SF Mono on system installs and falling
    /// back automatically. Same point size as paragraph text so a code
    /// block sandwiched between paragraphs reads as a sibling, not as
    /// a tonal shift.
    nonisolated static var codeBlockFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: paragraphFont.pointSize, weight: .regular)
    }

    /// Background fill — same tier as inline-code (`secondarySystemFill`).
    /// Multi-line block in the same tone as inline runs, so a paragraph
    /// like "use `fn()` to do X, e.g. \n```\nfn(x)\n```" doesn't
    /// flip-flop tone between the inline mention and the block call.
    nonisolated static var codeBlockBackgroundColor: NSColor { inlineCodeBackgroundColor }

    /// Verbatim source → monospaced attributed string. Whitespace and
    /// newlines preserved; no inline parsing, no syntax highlighting.
    nonisolated static func codeBlockAttributed(code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [
            .font: codeBlockFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// Header band height — sized to a 11pt SF Symbol with a 4–5pt
    /// breathing margin top/bottom. Closer to Discord's compact
    /// 24pt strip than GitHub's chunkier 32–36pt header; chat content
    /// reads better with a low-profile chrome band.
    nonisolated static let codeBlockHeaderHeight: CGFloat = 24

    /// Reuses `tableHeaderBackground` so a code block's header band
    /// reads at the same tonal level as a table's header row —
    /// both are "this strip is chrome, content lives below it". The
    /// color is dynamic-resolving (alpha-on-white in light mode,
    /// alpha-on-black in dark mode), so it composites on top of
    /// `codeBlockBackgroundColor` and tracks appearance without any
    /// hand-tuned hex values.
    nonisolated static var codeBlockHeaderOverlayColor: NSColor { tableHeaderBackground }
    /// Body padding above and below the code text (inside the
    /// container, *below* the header band). Smaller than user
    /// bubble's 14pt — the header already eats the top visual weight,
    /// so 12 around the body keeps the block from reading too tall.
    nonisolated static let codeBlockBodyVerticalPadding: CGFloat = 12
    /// Right inset for the copy button hit zone. Matches
    /// `structuralCornerRadius` so the button optically anchors to the
    /// corner pivot.
    nonisolated static var codeBlockCopyRightInset: CGFloat { structuralCornerRadius + 6 }
    /// Hairline divider color between header and body.
    nonisolated static let codeBlockDividerColor: NSColor = .separatorColor

    // MARK: - Blockquote geometry

    /// Left accent bar. Tuned to the same values the prior renderer
    /// settled on — 4pt bar with a 12pt gap to the text, default
    /// secondary-label color so dark/light tracking is automatic.
    /// Quotes deliberately use **no background fill and no rounded
    /// container** — the bar alone does the "this is set apart"
    /// signaling, matching Slack / Discord / GitHub conventions where
    /// quotes are margin annotations, not standalone containers.
    nonisolated static let blockquoteBarColor: NSColor = .secondaryLabelColor
    nonisolated static let blockquoteBarWidth: CGFloat = 4
    nonisolated static let blockquoteBarGap: CGFloat = 12

    // MARK: - Thematic break geometry

    /// Hairline rule — 1pt at HiDPI, antialiased. Color uses the system
    /// separator so it tracks light/dark.
    nonisolated static let thematicBreakColor: NSColor = .separatorColor
    nonisolated static let thematicBreakHeight: CGFloat = 1

    /// Min/max width of the centered cell — the row spans the full table width
    /// (so the overlay scroller stays at the right edge), but the cell itself
    /// is clamped to this band by `CenteredRowView`. Width passed into
    /// `makeLayout` is also clamped, so the layout cache dedupes resizes
    /// inside the >max region.
    nonisolated static let minLayoutWidth: CGFloat = 460
    nonisolated static let maxLayoutWidth: CGFloat = 780

    nonisolated static func clampedLayoutWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        min(maxLayoutWidth, max(minLayoutWidth, rowWidth))
    }

    /// Horizontal offset from the row's left edge to the centered cell.
    /// `CenteredRowView` and `Transcript2SelectionCoordinator` both go
    /// through this so the doc-coord ↔ layout-local conversion stays in
    /// sync with the visual layout.
    nonisolated static func cellOriginX(forRowWidth rowWidth: CGFloat) -> CGFloat {
        (rowWidth - clampedLayoutWidth(forRowWidth: rowWidth)) / 2
    }

    /// Marker attribute for inline code runs. `CTLineDraw` does not honor
    /// `.backgroundColor`, so we tag the run here and `TextLayout` extracts
    /// per-run rects from the typesetter output to paint the background
    /// itself with line-bounded geometry. Value is unused; presence is the
    /// signal.
    nonisolated static let inlineCodeAttributeKey =
        NSAttributedString.Key("CCTermInlineCode")

    /// Inline-code background. `secondarySystemFill` is the HIG-documented
    /// fill tier for "medium-sized layered shapes" — the next tier down,
    /// `tertiarySystemFill` (for "thin and small layered shapes"), reads as
    /// invisible against typical chat backgrounds; the next up,
    /// `systemFill`, is too heavy. `.secondarySystemFill` is already
    /// dark/light adaptive, so resolution happens automatically at draw
    /// time via `.cgColor`.
    nonisolated static let inlineCodeBackgroundColor: NSColor = .secondarySystemFill

    nonisolated static func paragraphAttributed(inlines: [InlineNode]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendInlines(inlines, into: out, base: baseAttributes(font: paragraphFont))
        return out
    }

    nonisolated static func headingAttributed(level: Int,
                                              inlines: [InlineNode]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendInlines(inlines, into: out, base: baseAttributes(font: headingFont(level: level)))
        return out
    }

    /// h1 26 / h2 22 / h3-h6 18. Markdown's six levels collapse to three
    /// visual tiers — chat content rarely needs deeper than h3, and shrinking
    /// h4-h6 below paragraph size makes them harder to scan than the
    /// preceding paragraph itself, defeating the point of a heading.
    nonisolated static func headingFont(level: Int) -> NSFont {
        let clamped = max(1, min(6, level))
        let size: CGFloat
        switch clamped {
        case 1: size = 26
        case 2: size = 22
        default: size = 18
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    nonisolated private static func baseAttributes(font: NSFont)
        -> [NSAttributedString.Key: Any]
    {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    /// Recursive walker. `base` carries the inherited attributes; each node
    /// derives a child attribute set, recurses, then drops back. Keeps the
    /// builder allocation-light — one `NSAttributedString.append` per leaf.
    nonisolated private static func appendInlines(_ nodes: [InlineNode],
                                                  into out: NSMutableAttributedString,
                                                  base: [NSAttributedString.Key: Any]) {
        for node in nodes {
            switch node {
            case .text(let s):
                out.append(NSAttributedString(string: s, attributes: base))

            case .strong(let children):
                appendInlines(children, into: out,
                              base: withTrait(base, adding: .bold))

            case .emphasis(let children):
                appendInlines(children, into: out,
                              base: withTrait(base, adding: .italic))

            case .strikethrough(let children):
                var attrs = base
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = base[.foregroundColor] ?? NSColor.labelColor
                appendInlines(children, into: out, base: attrs)

            case .code(let s):
                var attrs = base
                attrs[.font] = inlineCodeFont(matching: base[.font] as? NSFont)
                // Marker only — actual fill happens in TextLayout.draw.
                attrs[inlineCodeAttributeKey] = true
                out.append(NSAttributedString(string: s, attributes: attrs))

            case .link(let children, let url):
                var attrs = base
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                appendInlines(children, into: out, base: attrs)

            case .lineBreak:
                // U+2028 line separator: line break inside a paragraph,
                // doesn't reset paragraph-style state. CTTypesetter honors it.
                out.append(NSAttributedString(string: "\u{2028}", attributes: base))
            }
        }
    }

    nonisolated private static func withTrait(_ attrs: [NSAttributedString.Key: Any],
                                              adding trait: NSFontDescriptor.SymbolicTraits)
        -> [NSAttributedString.Key: Any]
    {
        guard let font = attrs[.font] as? NSFont else { return attrs }
        let descriptor = font.fontDescriptor
            .withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        let next = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        var copy = attrs
        copy[.font] = next
        return copy
    }

    /// Inline code uses the system monospaced font at the surrounding text's
    /// point size (or paragraph size when the surrounding font is unknown).
    /// Weight follows the surrounding context so `**`code`**` stays bold.
    nonisolated private static func inlineCodeFont(matching surrounding: NSFont?) -> NSFont {
        let pointSize = surrounding?.pointSize ?? paragraphFont.pointSize
        let weight: NSFont.Weight = {
            guard let f = surrounding,
                  f.fontDescriptor.symbolicTraits.contains(.bold)
            else { return .regular }
            return .semibold
        }()
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
    }
}
