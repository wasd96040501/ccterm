import AppKit

/// One tool-group child's expanded body: the per-kind body (`Kind`)
/// plus an optional **uniform error card** composited below it.
///
/// The error card is the single, tool-agnostic way a failed
/// `tool_result` surfaces its message — a red monospaced
/// `TextCardSection` (+ copy chrome) appended under whatever the
/// per-kind body produced (or on its own, for header-only kinds). It
/// lives here, at the dispatch layer, rather than inside each per-kind
/// layout so the rendering path stays uniform: `make` builds it once,
/// and every accessor below composes it in. Per-kind layout files stay
/// untouched.
///
/// Exposes the uniform shape `ToolGroupLayout` consumes:
///
/// - `totalHeight` — body's full height (header is owned by
///   `ToolGroupLayout`, this is body + error card only).
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
/// 3. This file — add the matching `Kind` enum `case`, then three
///    switch arms (`totalHeight`, `draw`, `drawBackplate`). Add a
///    fourth in the static `Kind.make(...)` factory at the bottom.
///
/// The error card needs no per-kind work — it composes uniformly in
/// `ToolGroupChildLayout.make`.
///
/// Highlight is the parallel story — see
/// `ToolGroupChildHighlight.requests(for:)`.
struct ToolGroupChildLayout: @unchecked Sendable {
    /// Per-kind body dispatch. Holds whichever child-specific layout
    /// value the kind required.
    enum Kind: @unchecked Sendable {
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

        /// Height of just the per-kind body, in points. `0` when the
        /// body is empty (folded, header-only kind, or no result yet).
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

        func drawBackplate(
            in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect?
        ) {
            switch self {
            case .fileEdit(let l):
                l.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
            case .read(let l):
                l.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
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

        func draw(
            in ctx: CGContext, origin: CGPoint,
            hoveredCopyId: UUID?,
            flashingCopyIds: Set<UUID>,
            dirtyRect: CGRect?
        ) {
            switch self {
            case .fileEdit(let l):
                l.draw(in: ctx, origin: origin, dirtyRect: dirtyRect)
            case .read(let l):
                l.draw(in: ctx, origin: origin, dirtyRect: dirtyRect)
            case .bash(let l):
                l.draw(
                    in: ctx, origin: origin,
                    hoveredCopyId: hoveredCopyId,
                    flashingCopyIds: flashingCopyIds)
            case .grep(let l): l.draw(in: ctx, origin: origin)
            case .glob(let l): l.draw(in: ctx, origin: origin)
            case .webFetch(let l): l.draw(in: ctx, origin: origin)
            case .webSearch(let l): l.draw(in: ctx, origin: origin)
            case .askUserQuestion(let l): l.draw(in: ctx, origin: origin)
            case .agent(let l): l.draw(in: ctx, origin: origin)
            case .generic(let l): l.draw(in: ctx, origin: origin)
            }
        }

        var copyChromes: [CopyChrome] {
            switch self {
            case .bash(let l): return l.copyChromes
            case .fileEdit(let l): return l.body.copy.map { [$0] } ?? []
            case .read(let l): return l.body?.copy.map { [$0] } ?? []
            case .grep, .glob, .webFetch, .webSearch,
                .askUserQuestion, .agent, .generic:
                return []
            }
        }

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

        var diffBody: DiffLayout? {
            switch self {
            case .fileEdit(let l): return l.body
            case .read(let l): return l.body
            default: return nil
            }
        }
    }

    let kind: Kind
    /// Uniform red error card composited below the per-kind body when the
    /// child's `tool_result` was an error. A single red monospaced
    /// `TextCardSection`, already positioned in layout-local coords
    /// (`make` places it directly under `kind`'s body, or at the body
    /// origin for header-only kinds). `nil` when the child carried no
    /// error.
    let errorCard: TextCardSection?
    /// Copy affordance for `errorCard` (top-right corner). `nil` when
    /// there is no error card or the card is too narrow to host one.
    let errorCopyChrome: CopyChrome?
    /// Full body height: per-kind body + the error card (and the gap
    /// between them) when present. Computed once in `make` so
    /// `heightOfRow` stays a synchronous cache read.
    let totalHeight: CGFloat

    /// Opaque chrome forwarded by the cell's pre-glyph draw pass. See the
    /// per-kind `Kind.drawBackplate`; the error card's rounded fill is
    /// painted last so a selection band the cell paints later sits on
    /// top of it.
    func drawBackplate(
        in ctx: CGContext, origin: CGPoint, dirtyRect: CGRect? = nil
    ) {
        kind.drawBackplate(in: ctx, origin: origin, dirtyRect: dirtyRect)
        if let errorCard {
            TextCardSection.drawBackplates([errorCard], in: ctx, origin: origin)
        }
    }

    /// Glyph pass. `hoveredCopyId` / `flashingCopyIds` flow in from the
    /// cell so per-card chrome (bash copy icons, the error card's copy
    /// icon) renders hover-bg + checkmark feedback.
    func draw(
        in ctx: CGContext, origin: CGPoint,
        hoveredCopyId: UUID? = nil,
        flashingCopyIds: Set<UUID> = [],
        dirtyRect: CGRect? = nil
    ) {
        kind.draw(
            in: ctx, origin: origin,
            hoveredCopyId: hoveredCopyId,
            flashingCopyIds: flashingCopyIds,
            dirtyRect: dirtyRect)
        if let errorCard {
            TextCardSection.draw([errorCard], in: ctx, origin: origin)
            if let chrome = errorCopyChrome {
                chrome.draw(
                    in: ctx, origin: origin,
                    hovered: hoveredCopyId == chrome.id,
                    flashing: flashingCopyIds.contains(chrome.id))
            }
        }
    }

    /// Layout-emitted copy affordances, in layout-local coords. The error
    /// card's chrome (when present) is appended so `ToolGroupLayout`
    /// registers its hit zone through the same `HitAction.copy` path as
    /// every other card.
    var copyChromes: [CopyChrome] {
        var chromes = kind.copyChromes
        if let errorCopyChrome { chromes.append(errorCopyChrome) }
        return chromes
    }

    /// `TextCardSection` stack underlying this body. Per-kind cards (for
    /// the text-card kinds) followed by the uniform error card as the
    /// trailing section. `ToolGroupLayout.selectionAdapter` threads
    /// `LayoutPosition.textCard(...)` positions through these, so the
    /// error card is selectable + searchable for every kind — including
    /// diff-bearing (`fileEdit` / `read`) and header-only (`generic`)
    /// kinds, whose per-kind body returns `nil` here.
    var textCardSections: [TextCardSection]? {
        var sections = kind.textCardSections ?? []
        if let errorCard { sections.append(errorCard) }
        return sections.isEmpty ? nil : sections
    }

    /// Underlying `DiffLayout` when this child renders a diff card
    /// (`fileEdit` always, `read` once content has landed). Unaffected by
    /// the error card, which is a sibling text card below the diff.
    var diffBody: DiffLayout? { kind.diffBody }

    /// Slot used to derive the error card's `CopyChrome.id`. A high
    /// sentinel so it never collides with a text-card kind's per-section
    /// slots (`0..<sections.count`) under the same child id — bash, for
    /// instance, keeps its command card on slot 0 even on a failed run.
    private static let errorCardCopySlot = Int.max

    /// Factory called by `ToolGroupLayout` when an entry is expanded.
    /// Builds the per-kind body, then appends the uniform error card
    /// directly below it (a `TextCardSection.sectionSpacing` gap when the
    /// body is non-empty; flush at the body origin for header-only
    /// kinds). Folded entries skip this entirely.
    ///
    /// `(originX, originY)` is the top-left corner of the body in
    /// layout-local coords. `maxWidth` is the child's available width
    /// (net of the row's horizontal padding). `highlight` is whatever
    /// `Transcript2HighlightStorage` filled in for this child's id.
    nonisolated static func make(
        child: ToolGroupBlock.Child,
        highlight: HighlightValue?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ToolGroupChildLayout {
        let kind = Kind.make(
            child: child, highlight: highlight,
            originX: originX, originY: originY, maxWidth: maxWidth)

        let bodyHeight = kind.totalHeight
        guard let errorText = child.errorText, !errorText.isEmpty else {
            return ToolGroupChildLayout(
                kind: kind, errorCard: nil, errorCopyChrome: nil,
                totalHeight: bodyHeight)
        }

        // The error card is one more card in the body stack: a
        // `sectionSpacing` gap below the per-kind body, or flush at the
        // body origin when there is no body (header-only kinds).
        let gap = bodyHeight > 0 ? TextCardSection.sectionSpacing : 0
        let (sections, errHeight) = TextCardSection.build(
            specs: [.init(text: errorText, color: .systemRed)],
            originX: originX,
            originY: originY + bodyHeight + gap,
            maxWidth: maxWidth)
        guard let errorCard = sections.first else {
            // Error text trimmed to empty — no card.
            return ToolGroupChildLayout(
                kind: kind, errorCard: nil, errorCopyChrome: nil,
                totalHeight: bodyHeight)
        }
        let chrome = CopyChrome.topRight(
            of: errorCard.cardRect,
            id: CopyChrome.derivedId(base: child.id, slot: errorCardCopySlot),
            text: errorText)
        return ToolGroupChildLayout(
            kind: kind, errorCard: errorCard, errorCopyChrome: chrome,
            totalHeight: bodyHeight + gap + errHeight)
    }
}

extension ToolGroupChildLayout.Kind {
    /// Per-kind dispatch — unpacks the expected `HighlightValue` shape and
    /// calls the matching `XxxChildLayout.make`. Adding a child kind adds
    /// one arm here.
    nonisolated static func make(
        child: ToolGroupBlock.Child,
        highlight: HighlightValue?,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ToolGroupChildLayout.Kind {
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
