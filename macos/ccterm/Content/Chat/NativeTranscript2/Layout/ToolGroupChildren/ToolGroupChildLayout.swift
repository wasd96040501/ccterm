import AppKit

/// Type-erased dispatch over per-kind tool-group child body layouts.
/// Holds whichever child-specific layout value the kind required, and
/// exposes the uniform shape `ToolGroupLayout` consumes:
///
/// - `totalHeight` — body's full height (header is owned by
///   `ToolGroupLayout`, this is body only).
/// - `drawBackplate(in:origin:)` — opaque chrome under glyphs.
/// - `draw(in:origin:)` — glyphs + decoration.
///
/// ### Adding a new child kind
///
/// Three edits, all compiler-checked:
///
/// 1. `Block.ToolGroupBlock.Child` — add an `enum case` with the
///    payload struct.
/// 2. `Layout/ToolGroupChildren/XxxChildLayout.swift` — implement
///    `make(...)` returning a value, plus `totalHeight` / `draw` /
///    `drawBackplate`. Keep the per-kind file focused — no cross-
///    case branches here.
/// 3. This file — add the matching enum `case`, then three switch
///    arms (`totalHeight`, `draw`, `drawBackplate`). Add a fourth in
///    the static `make(...)` factory at the bottom.
///
/// Highlight is the parallel story — see
/// `ToolGroupChildHighlight.requests(for:)`.
enum ToolGroupChildLayout: @unchecked Sendable {
    case fileEdit(FileEditChildLayout)

    /// Height of this child's expanded body, in points. `0` when the
    /// body is empty (typically: the child is folded, or it has no
    /// expandable body in the first place).
    var totalHeight: CGFloat {
        switch self {
        case .fileEdit(let l): return l.totalHeight
        }
    }

    /// Opaque chrome forwarded by the cell's pre-glyph draw pass.
    /// Forwards into the body layout so a selection band painted by
    /// the cell sits *on top of* (not under) the card fill.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .fileEdit(let l): l.drawBackplate(in: ctx, origin: origin)
        }
    }

    /// Glyph pass.
    func draw(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .fileEdit(let l): l.draw(in: ctx, origin: origin)
        }
    }

    /// Factory called by `ToolGroupLayout` when an entry is expanded.
    /// Folded entries skip this entirely — the layout's `body` field
    /// stays `nil` and no per-kind work runs.
    ///
    /// `(originX, originY)` is the top-left corner of the body card
    /// in layout-local coords (the same coord space `draw` consumes).
    /// `maxWidth` is the child's available width — already net of the
    /// row's horizontal padding.
    ///
    /// `lineMap` is whatever `Transcript2HighlightStorage` has filled
    /// in for this child's id; child kinds that don't use line-map
    /// highlight simply ignore it.
    nonisolated static func make(
        child: ToolGroupBlock.Child,
        lineMap: [String: [SyntaxToken]]?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ToolGroupChildLayout {
        switch child {
        case .fileEdit(let c):
            return .fileEdit(FileEditChildLayout.make(
                child: c, lineMap: lineMap,
                originX: originX, originY: originY,
                maxWidth: maxWidth))
        }
    }
}
