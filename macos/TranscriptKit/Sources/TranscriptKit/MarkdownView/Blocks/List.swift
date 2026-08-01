import AppKit

/// A bulleted, numbered or task list: a marker column beside a stack of item
/// contents.
///
/// **This is the one type that negotiates.** A stack measures its children
/// independently, so it cannot make `10.` and `9.` line up; the marker column's
/// width is an agreement *between* siblings. So the list renders every marker
/// first, takes the widest, and only then measures each item's content against
/// what is left. The settled number never leaves this function — the same
/// discipline `Blockquote` follows with its indent, applied to a value that had
/// to be computed rather than declared.
///
/// **Markers are drawn, not indexed.** A bullet, an ordinal and a task checkbox
/// occupy zero positions in the selection index space, so dragging across a list
/// copies the items' text and none of the furniture — what a reader expects, and
/// what a browser does.
///
/// An item's content is any `Layout`, so an item holds paragraphs, code blocks,
/// quotes, or another list, without this type knowing which. Nesting is not a
/// mechanism of its own: a sub-list is simply one more block inside its parent
/// item's content.
struct List: Layout {

    enum Marker {
        case bullet
        case ordinal(Int)
        case task(checked: Bool)
    }

    struct Item {
        let marker: Marker
        let content: Layout

        init(marker: Marker, content: Layout) {
            self.marker = marker
            self.content = content
        }
    }

    let items: [Item]

    /// Matches the surrounding body face: a marker set at a different size sits
    /// on a different baseline from the line it belongs to.
    var font: NSFont = .systemFont(ofSize: 14, weight: .regular)
    var color: NSColor = .secondaryLabelColor

    /// Tighter than the gap between two document blocks: the items of one list
    /// are one thought. The same number applies at every nesting depth and
    /// between the blocks *inside* one item, so a list has a single rhythm no
    /// matter how it is shaped.
    var spacing: CGFloat = 6

    /// Just under the body font's cap height. Bigger reads as a button; smaller
    /// fails to register as a control at all.
    var checkboxSize: CGFloat { font.pointSize * 0.95 }

    var checkboxFillColor: NSColor = .controlAccentColor
    var checkboxMarkColor: NSColor = .white

    init(items: [Item]) {
        self.items = items
    }

    func measure(_ width: CGFloat) -> MarkdownBlock {
        // Negotiation, all of it: render every marker, take the widest.
        let markers = items.map { rendered($0.marker) }
        let column = markers.map(\.width).max() ?? 0
        let gap = font.pointSize * 0.5

        return BlockStack(
            items.indices.map { index in
                Row(
                    marker: markers[index],
                    markerColumn: column,
                    gap: gap,
                    content: items[index].content)
            },
            spacing: spacing
        ).measure(width)
    }

    private func rendered(_ marker: Marker) -> Row.Marker {
        switch marker {
        case .task(let checked):
            return .checkbox(
                Checkbox(
                    size: checkboxSize, checked: checked,
                    fill: checkboxFillColor, mark: checkboxMarkColor, border: color))

        case .bullet:
            return .text(text("•"))

        case .ordinal(let n):
            return .text(text("\(n)."))
        }
    }

    private func text(_ string: String) -> MarkdownTextRun {
        .make(
            NSAttributedString(
                string: string, attributes: [.font: font, .foregroundColor: color]),
            width: .greatestFiniteMagnitude)
    }

    /// One item: its marker in the settled column, its content in the remainder.
    private struct Row: Layout {

        enum Marker {
            case text(MarkdownTextRun)
            case checkbox(Checkbox)

            var width: CGFloat {
                switch self {
                case .text(let run): return run.size.width
                case .checkbox(let box): return box.size
                }
            }
        }

        let marker: Marker
        let markerColumn: CGFloat
        let gap: CGFloat
        let content: Layout

        func measure(_ width: CGFloat) -> MarkdownBlock {
            let indent = markerColumn + gap
            let inner = content.measure(max(1, width - indent))
            return Measured(
                marker: marker,
                // Right-aligned in the column, so `9.` and `10.` share a decimal
                // point rather than a left edge.
                markerRightX: markerColumn,
                content: inner,
                indent: indent,
                size: CGSize(width: width, height: inner.size.height))
        }

        struct Measured: MarkdownBlock, @unchecked Sendable {

            let marker: Marker
            let markerRightX: CGFloat
            let content: MarkdownBlock
            let indent: CGFloat
            let size: CGSize

            func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
                let line = firstLine
                switch marker {
                case .text(let run):
                    // Same point size as the body, so sharing a top means
                    // sharing a baseline.
                    run.draw(
                        at: CGPoint(
                            x: origin.x + markerRightX - run.size.width, y: origin.y + line.minY),
                        in: ctx, dirty: dirty)

                case .checkbox(let box):
                    // A drawn shape has no baseline, so it centres on the line
                    // instead — which is what a browser does with a `::marker`
                    // it draws rather than typesets.
                    box.draw(
                        in: CGRect(
                            x: origin.x + markerRightX - box.size,
                            y: origin.y + line.midY - box.size / 2,
                            width: box.size, height: box.size),
                        in: ctx)
                }

                content.draw(at: CGPoint(x: origin.x + indent, y: origin.y), in: ctx, dirty: dirty)
            }

            /// The content's first line box, which is what the marker aligns to.
            /// Read off the content rather than assumed, because how much room a
            /// block gives itself is its own business and not something it
            /// reports.
            private var firstLine: CGRect {
                content.rects(from: 0, to: min(1, content.length)).first
                    ?? CGRect(x: 0, y: 0, width: 0, height: size.height)
            }

            // MARK: - Selection — the content's only; a marker holds no positions

            var length: Int { content.length }

            func index(at point: CGPoint) -> Int {
                content.index(at: CGPoint(x: point.x - indent, y: point.y))
            }

            func rects(from: Int, to: Int) -> [CGRect] {
                content.rects(from: from, to: to).map { $0.offsetBy(dx: indent, dy: 0) }
            }

            func text(from: Int, to: Int) -> String { content.text(from: from, to: to) }
        }
    }
}

/// A task-list checkbox, drawn rather than typeset.
///
/// Every proportion is Material Design's `mdc-checkbox`, scaled from its 18pt
/// box to whatever the body font asks for — a 1:1 port rather than an
/// approximation, because "looks about right" is how a control ends up subtly
/// wrong at one size and badly wrong at another. From `_checkbox-theme.scss`:
/// `$icon-size: 18px`, `$border-width: 2px`, `$mark-stroke-size: 2/15 × 18`; and
/// `border-radius: 2px` from `_checkbox.scss`. The tick is MDC's own path,
/// `M1.73,12.91 8.1,19.28 22.79,4.59`, stated there over a 24-unit viewBox and
/// normalised here.
///
/// Drawn, not written as `☐` / `☑`, for the reason WebKit draws `list-style:
/// disc` with `fillEllipse` instead of emitting a bullet glyph: a character's
/// size and vertical position ride on whatever font resolves it, and the two
/// ballot-box characters do not even share an advance width — so a list would
/// jitter as its items were ticked. `NativeTranscript2` reached the same
/// conclusion and draws its checkbox as a `CGPath`.
struct Checkbox: Sendable {

    let size: CGFloat
    let checked: Bool
    let fill: NSColor
    let mark: NSColor
    let border: NSColor

    // MARK: - Material's proportions, per unit of box size

    private static let borderWidth: CGFloat = 2 / 18
    private static let cornerRadius: CGFloat = 2 / 18
    private static let markStroke: CGFloat = 2 / 15

    /// `M1.73,12.91 8.1,19.28 22.79,4.59` over a 24-unit viewBox.
    private static let markPath: [CGPoint] = [
        CGPoint(x: 1.73 / 24, y: 12.91 / 24),
        CGPoint(x: 8.1 / 24, y: 19.28 / 24),
        CGPoint(x: 22.79 / 24, y: 4.59 / 24),
    ]

    func draw(in rect: CGRect, in ctx: CGContext) {
        let radius = size * Self.cornerRadius
        ctx.saveGState()
        defer { ctx.restoreGState() }

        guard checked else {
            // Unchecked: the border only, inset by half its width so the stroke
            // lands inside the box rather than straddling its edge.
            let width = size * Self.borderWidth
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(width)
            ctx.addPath(
                CGPath(
                    roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
            return
        }

        ctx.setFillColor(fill.cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        ctx.setStrokeColor(mark.cgColor)
        ctx.setLineWidth(size * Self.markStroke)
        ctx.setLineCap(.square)
        ctx.setLineJoin(.miter)
        let points = Self.markPath.map {
            CGPoint(x: rect.minX + $0.x * size, y: rect.minY + $0.y * size)
        }
        ctx.move(to: points[0])
        ctx.addLine(to: points[1])
        ctx.addLine(to: points[2])
        ctx.strokePath()
    }
}
