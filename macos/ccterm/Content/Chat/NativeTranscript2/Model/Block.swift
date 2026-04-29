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
        case .paragraph, .list:
            return (top: 6, bottom: 6)
        case .image, .table:
            return (top: 8, bottom: 8)
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
    nonisolated static let tableCornerRadius: CGFloat = 6

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
