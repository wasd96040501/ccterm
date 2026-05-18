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
    case read(ReadChildLayout)
    case bash(BashChildLayout)
    case grep(GrepChildLayout)
    case glob(GlobChildLayout)
    case webFetch(WebFetchChildLayout)
    case webSearch(WebSearchChildLayout)
    case askUserQuestion(AskUserQuestionChildLayout)
    case agent(AgentChildLayout)
    case generic(GenericChildLayout)

    /// Height of this child's expanded body, in points. `0` when the
    /// body is empty (typically: the child is folded, or it has no
    /// expandable body in the first place).
    var totalHeight: CGFloat {
        switch self {
        case .fileEdit(let l): return l.totalHeight
        case .read(let l): return l.totalHeight
        case .bash(let l): return l.totalHeight
        case .grep(let l): return l.totalHeight
        case .glob(let l): return l.totalHeight
        case .webFetch(let l): return l.totalHeight
        case .webSearch(let l): return l.totalHeight
        case .askUserQuestion(let l): return l.totalHeight
        case .agent(let l): return l.totalHeight
        case .generic(let l): return l.totalHeight
        }
    }

    /// Opaque chrome forwarded by the cell's pre-glyph draw pass.
    /// Forwards into the body layout so a selection band painted by
    /// the cell sits *on top of* (not under) the card fill.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .fileEdit(let l): l.drawBackplate(in: ctx, origin: origin)
        case .read(let l): l.drawBackplate(in: ctx, origin: origin)
        case .bash(let l): l.drawBackplate(in: ctx, origin: origin)
        case .grep(let l): l.drawBackplate(in: ctx, origin: origin)
        case .glob(let l): l.drawBackplate(in: ctx, origin: origin)
        case .webFetch(let l): l.drawBackplate(in: ctx, origin: origin)
        case .webSearch(let l): l.drawBackplate(in: ctx, origin: origin)
        case .askUserQuestion(let l): l.drawBackplate(in: ctx, origin: origin)
        case .agent(let l): l.drawBackplate(in: ctx, origin: origin)
        case .generic(let l): l.drawBackplate(in: ctx, origin: origin)
        }
    }

    /// Glyph pass.
    func draw(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .fileEdit(let l): l.draw(in: ctx, origin: origin)
        case .read(let l): l.draw(in: ctx, origin: origin)
        case .bash(let l): l.draw(in: ctx, origin: origin)
        case .grep(let l): l.draw(in: ctx, origin: origin)
        case .glob(let l): l.draw(in: ctx, origin: origin)
        case .webFetch(let l): l.draw(in: ctx, origin: origin)
        case .webSearch(let l): l.draw(in: ctx, origin: origin)
        case .askUserQuestion(let l): l.draw(in: ctx, origin: origin)
        case .agent(let l): l.draw(in: ctx, origin: origin)
        case .generic(let l): l.draw(in: ctx, origin: origin)
        }
    }

    /// `TextCardSection` stack underlying this body, when the kind is
    /// rendered as one or more rounded text cards. `nil` for kinds
    /// that don't use that primitive — `fileEdit` / `read` (both diff
    /// bodies, routed through `LayoutPosition.diff`) and `generic`
    /// (header-only). Used by `ToolGroupLayout.selectionAdapter` to
    /// thread `LayoutPosition.textCard(...)` positions through the
    /// section's `TextLayout` without per-kind branches.
    var textCardSections: [TextCardSection]? {
        switch self {
        case .fileEdit, .read, .generic: return nil
        case .bash(let l): return l.sections
        case .grep(let l): return l.sections
        case .glob(let l): return l.sections
        case .webFetch(let l): return l.sections
        case .webSearch(let l): return l.sections
        case .askUserQuestion(let l): return l.sections
        case .agent(let l): return l.sections
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
    /// `highlight` is whatever `Transcript2HighlightStorage` has filled
    /// in for this child's id. Each per-kind branch unpacks the
    /// expected `HighlightValue` shape (`.lineMap` for fileEdit / read,
    /// `.tokens` for bash, …); child kinds that don't use highlight
    /// simply ignore it.
    nonisolated static func make(
        child: ToolGroupBlock.Child,
        highlight: HighlightValue?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ToolGroupChildLayout {
        switch child {
        case .fileEdit(let c):
            let lineMap: [String: [SyntaxToken]]? = {
                if case .lineMap(let m) = highlight { return m }
                return nil
            }()
            return .fileEdit(
                FileEditChildLayout.make(
                    child: c, lineMap: lineMap,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .read(let c):
            let lineMap: [String: [SyntaxToken]]? = {
                if case .lineMap(let m) = highlight { return m }
                return nil
            }()
            return .read(
                ReadChildLayout.make(
                    child: c, lineMap: lineMap,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .bash(let c):
            let tokens: [SyntaxToken]? = {
                if case .tokens(let t) = highlight { return t }
                return nil
            }()
            return .bash(
                BashChildLayout.make(
                    child: c,
                    commandTokens: tokens,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .grep(let c):
            return .grep(
                GrepChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .glob(let c):
            return .glob(
                GlobChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .webFetch(let c):
            return .webFetch(
                WebFetchChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .webSearch(let c):
            return .webSearch(
                WebSearchChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .askUserQuestion(let c):
            return .askUserQuestion(
                AskUserQuestionChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .agent(let c):
            return .agent(
                AgentChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        case .generic(let c):
            return .generic(
                GenericChildLayout.make(
                    child: c,
                    originX: originX, originY: originY,
                    maxWidth: maxWidth))
        }
    }
}
