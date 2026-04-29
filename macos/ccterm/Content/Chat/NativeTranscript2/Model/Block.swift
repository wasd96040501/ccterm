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
    }
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

    /// Vertical padding above/below each block's content within its row.
    nonisolated static let blockVerticalPadding: CGFloat = 4
    /// Horizontal padding inside the row.
    nonisolated static let blockHorizontalPadding: CGFloat = 16

    /// Cap for image height — wide-and-tall sources don't dominate the viewport.
    nonisolated static let imageMaxHeight: CGFloat = 360

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
