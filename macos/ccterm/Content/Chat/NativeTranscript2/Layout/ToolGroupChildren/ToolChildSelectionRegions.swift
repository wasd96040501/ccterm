import AppKit

/// Selection / search region machinery for tool child bodies, shared by
/// the two hosts that render a `ToolGroupChildLayout`:
///
/// - the monolithic `ToolGroupLayout` row (old renderer — one row hosts
///   every child; `childIndex` = position in the group), and
/// - the outline transcript's standalone `ToolBodyLayout` leaf (one row
///   per body; `childIndex` = 0).
///
/// Moved verbatim from `ToolGroupLayout` — the closures, the position
/// cases (`.diff` / `.textCard`), the cross-region clamp, and the
/// search-range == selection-range invariant are all unchanged; only
/// the namespace moved so both hosts build from one implementation.
enum ToolChildSelectionRegions {

    /// One selectable surface inside a body — either a `DiffLayout`
    /// or a single `TextCardSection` card. All closures are pre-bound
    /// to the underlying primitive at build time so the per-kind
    /// switch lives in one place (`regions(childIndex:body:)`) rather
    /// than scattered across every helper.
    struct Region {
        let bandRect: CGRect
        let fullRange: SelectionRange
        let matches: (LayoutPosition) -> Bool
        let hitTest: (CGPoint) -> LayoutPosition
        let rects: (LayoutPosition, LayoutPosition) -> [CGRect]
        let string: (LayoutPosition, LayoutPosition) -> String
        let wordBoundary: (LayoutPosition) -> SelectionRange?
        /// Optional search band exposed via `SelectionAdapter.searchableRegions`.
        /// `nil` when this region has no searchable text (e.g. an empty
        /// diff or zero-length text card). The region's char offsets are
        /// the same UTF-16 space used by `rects` / `string`, so the
        /// search-range == selection-range invariant holds.
        let searchable: SearchableRegion?
    }

    /// Every selectable region of one child body: the diff surface
    /// (fileEdit / read-in-new-file-mode) plus one region per
    /// `TextCardSection` card (per-kind cards + the uniform error card).
    nonisolated static func regions(
        childIndex: Int, body: ToolGroupChildLayout
    ) -> [Region] {
        var out: [Region] = []
        // Diff-bearing kinds expose a `DiffLayout`; selection threads
        // through the diff path. `diffBody` is the single source of
        // truth for "this kind renders a diff."
        if let d = body.diffBody, !d.containerRect.isEmpty {
            out.append(makeDiffRegion(childIndex: childIndex, body: d))
        }
        // Text-card sections: the per-kind cards (bash / grep / …) plus
        // the uniform error card, which `textCardSections` appends as
        // the trailing section for *every* kind — so a failed `fileEdit`
        // or header-only `generic` still gets its error text selectable
        // + searchable. The error card's `.textCard` position never
        // collides with a diff body's `.diff` position (different
        // `LayoutPosition` cases).
        for (sectionIndex, section) in (body.textCardSections ?? []).enumerated() {
            out.append(
                makeTextCardRegion(
                    childIndex: childIndex,
                    sectionIndex: sectionIndex,
                    section: section))
        }
        return out
    }

    /// Assemble a `SelectionAdapter` over a pre-built region list.
    /// Returns `nil` when there is nothing selectable.
    ///
    /// Cmd+A / triple-click target spans the first region only — the
    /// caller's hit-tested position then narrows `unitRange` to the
    /// right region. Mixed-region drags (across two bodies, or across
    /// two sections inside one body) collapse to empty rects / empty
    /// string.
    nonisolated static func adapter(regions: [Region]) -> SelectionAdapter? {
        guard !regions.isEmpty else { return nil }
        let fullRange = regions[0].fullRange

        return SelectionAdapter(
            fullRange: fullRange,
            unitRange: { p in
                region(for: p, in: regions)?.fullRange ?? fullRange
            },
            hitTest: { point in
                // Snap to whichever region's y band contains the
                // point (or, when between regions, the closest one).
                // Empty bodies are filtered out at region-build time,
                // so the snap always lands on a real selectable
                // surface.
                let target =
                    regions.first(where: {
                        point.y >= $0.bandRect.minY
                            && point.y <= $0.bandRect.maxY
                    })
                    ?? regions.min(by: {
                        let d0 = min(
                            abs(point.y - $0.bandRect.minY),
                            abs(point.y - $0.bandRect.maxY))
                        let d1 = min(
                            abs(point.y - $1.bandRect.minY),
                            abs(point.y - $1.bandRect.maxY))
                        return d0 < d1
                    })!
                return target.hitTest(point)
            },
            rects: { a, b in
                guard let region = region(for: a, in: regions),
                    region.matches(b)
                else { return [] }
                return region.rects(a, b)
            },
            string: { a, b in
                guard let region = region(for: a, in: regions),
                    region.matches(b)
                else { return "" }
                return region.string(a, b)
            },
            wordBoundary: { p in
                region(for: p, in: regions)?.wordBoundary(p)
            },
            searchableRegions: {
                // One SearchableRegion per selectable Region. Folded
                // children are absent from `regions` (their body is nil
                // at layout-build time), so their content is NOT in the
                // initial scan.
                regions.compactMap { $0.searchable }
            })
    }

    // MARK: - Region builders

    nonisolated private static func makeDiffRegion(
        childIndex: Int, body: DiffLayout
    ) -> Region {
        // Diff body's full content text, used for the searchable band.
        // `body.contentLength` already accounts for inter-row newlines,
        // so a UTF-16 char offset into `searchText` is the same scalar
        // as a `.diff(childIndex:, char:)` position — no remap needed.
        let searchText =
            body.contentLength > 0
            ? body.string(loChar: 0, hiChar: body.contentLength)
            : ""
        let searchable: SearchableRegion? =
            searchText.isEmpty
            ? nil
            : SearchableRegion(
                text: searchText,
                position: { .diff(childIndex: childIndex, char: $0) })
        return Region(
            bandRect: body.containerRect,
            fullRange: SelectionRange(
                start: .diff(childIndex: childIndex, char: 0),
                end: .diff(childIndex: childIndex, char: body.contentLength)),
            matches: { p in
                if case .diff(let i, _) = p { return i == childIndex }
                return false
            },
            hitTest: { point in
                .diff(childIndex: childIndex, char: body.hitTest(point: point))
            },
            rects: { a, b in
                guard case .diff(_, let ca) = a, case .diff(_, let cb) = b
                else { return [] }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                return body.rects(loChar: lo, hiChar: hi)
            },
            string: { a, b in
                guard case .diff(_, let ca) = a, case .diff(_, let cb) = b
                else { return "" }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                return body.string(loChar: lo, hiChar: hi)
            },
            wordBoundary: { p in
                guard case .diff(_, let c) = p,
                    let word = body.wordBoundary(at: c)
                else { return nil }
                return SelectionRange(
                    start: .diff(childIndex: childIndex, char: word.location),
                    end: .diff(
                        childIndex: childIndex,
                        char: word.location + word.length))
            },
            searchable: searchable)
    }

    /// One `TextCardSection` card. Char positions are UTF-16 indices
    /// into the section's `TextLayout.attributed.string`; rects are
    /// emitted in layout-local coords by offsetting `TextLayout`'s
    /// own rects by the section's `textOrigin`.
    nonisolated private static func makeTextCardRegion(
        childIndex: Int, sectionIndex: Int, section: TextCardSection
    ) -> Region {
        let text = section.text
        let textOrigin = section.textOrigin
        let attributed = text.attributed
        let length = text.length

        let fullRange = SelectionRange(
            start: .textCard(
                childIndex: childIndex,
                sectionIndex: sectionIndex, char: 0),
            end: .textCard(
                childIndex: childIndex,
                sectionIndex: sectionIndex, char: length))

        // Searchable band: U+2028 → \n normalisation matches what
        // `TextLayout.searchableRegions` does, so a query against a
        // multi-line card matches what the eye reads. Char offsets in
        // the normalised string equal `.textCard(... char:)` (both are
        // UTF-16; the replacement is single-unit → single-unit).
        let searchable: SearchableRegion? = {
            guard length > 0 else { return nil }
            let normalised =
                attributed.string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            return SearchableRegion(
                text: normalised,
                position: {
                    .textCard(
                        childIndex: childIndex,
                        sectionIndex: sectionIndex,
                        char: $0)
                })
        }()

        return Region(
            bandRect: section.cardRect,
            fullRange: fullRange,
            matches: { p in
                if case .textCard(let i, let s, _) = p {
                    return i == childIndex && s == sectionIndex
                }
                return false
            },
            hitTest: { point in
                let local = CGPoint(
                    x: point.x - textOrigin.x,
                    y: point.y - textOrigin.y)
                return .textCard(
                    childIndex: childIndex,
                    sectionIndex: sectionIndex,
                    char: text.characterIndex(at: local))
            },
            rects: { a, b in
                guard case .textCard(_, _, let ca) = a,
                    case .textCard(_, _, let cb) = b
                else { return [] }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                guard hi > lo else { return [] }
                let local = text.selectionRects(
                    for: NSRange(location: lo, length: hi - lo))
                return local.map {
                    $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
                }
            },
            string: { a, b in
                guard case .textCard(_, _, let ca) = a,
                    case .textCard(_, _, let cb) = b
                else { return "" }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                guard hi > lo, hi <= attributed.length else { return "" }
                return
                    attributed
                    .attributedSubstring(
                        from: NSRange(location: lo, length: hi - lo)
                    )
                    .string
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
            },
            wordBoundary: { p in
                guard case .textCard(_, _, let c) = p,
                    attributed.length > 0
                else { return nil }
                let clamped = max(0, min(c, attributed.length - 1))
                let word = attributed.doubleClick(at: clamped)
                return SelectionRange(
                    start: .textCard(
                        childIndex: childIndex,
                        sectionIndex: sectionIndex,
                        char: word.location),
                    end: .textCard(
                        childIndex: childIndex,
                        sectionIndex: sectionIndex,
                        char: word.location + word.length))
            },
            searchable: searchable)
    }

    /// Find the region that owns `position`. Returns `nil` when no
    /// region's `matches` accepts the value (caller passed a stale or
    /// foreign position).
    nonisolated private static func region(
        for position: LayoutPosition, in regions: [Region]
    ) -> Region? {
        regions.first(where: { $0.matches(position) })
    }
}
