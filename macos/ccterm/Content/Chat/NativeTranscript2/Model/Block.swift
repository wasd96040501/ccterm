import AppKit
import Foundation
import SwiftUI

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
        /// right corner. Syntax highlighting is async — the cold render
        /// shows plain text; `Transcript2HighlightStorage` fills tokens
        /// in the background and triggers a single-row reload, after
        /// which `BlockStyle.codeBlockAttributed` produces a colored
        /// attributed string.
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
        /// Grouped tool calls (today: a batch of file edits). One row
        /// owns the group header + every item header + every expanded
        /// item body. Three independently-foldable layers:
        ///
        /// 1. The group itself — chevron flips the entire item list.
        /// 2. Each item — chevron flips a single file's hunk body.
        /// 3. Hunk body — a `codeBlock`-style rounded card with the
        ///    diff drawn inside (gutter + sign + content).
        ///
        /// Group, item, and hunk fold flags share the
        /// `Transcript2Coordinator.foldStates: [UUID: Bool]` dict —
        /// `ToolGroupBlock.id` keys the group flag, `Item.id` keys
        /// per-item. Sparse: absent = the layer's default
        /// (`false`, i.e. folded). A diff used to be a top-level
        /// `Block.Kind` case; it has been folded into
        /// `ToolGroupBlock.Item` because every real-world diff arrives
        /// inside a tool-result envelope.
        case toolGroup(ToolGroupBlock)
    }
}

/// Grouped tool calls. The group renders as a single row containing:
///
/// 1. A group header (title + chevron) at the top.
/// 2. When the group is expanded, one stacked entry per `children`,
///    each rendered by a per-kind `ToolGroupChildLayout`.
///
/// `Child` is a closed enum — new child kinds plug in by adding a
/// `case` here, a struct payload, and a `ToolGroupChildLayout` arm
/// (and one arm in `ToolGroupChildHighlight` if the child needs
/// async highlight). No protocol / no runtime registration table —
/// the compiler enforces exhaustiveness across the four switches.
///
/// Every `Child` exposes a stable `id` so per-child fold flags persist
/// in `Transcript2Coordinator.foldStates` independently (toggling
/// file 2's expansion doesn't reset file 1's).
struct ToolGroupBlock: Equatable, Sendable {
    /// Title shown when the group is `.running` **and folded** — the
    /// progressive fragment of the *last* tool in the group (e.g.
    /// `"Reading foo.swift"`). Mirrors
    /// `GroupEntry.activeTitle` on the SessionHandle2 side.
    let activeTitle: String
    /// Title shown when the group is `.running` **and expanded** — the
    /// aggregated progressive phrase (e.g.
    /// `"Reading 3 files · Searching 1 pattern"`). Mirrors
    /// `GroupEntry.expandedActiveTitle`. When running, the expanded
    /// form is the more informative read because the user has the
    /// children laid out anyway.
    let expandedActiveTitle: String
    /// Title shown when the group is not running — the aggregated
    /// past-tense phrase (e.g. `"Read 3 files · Searched 1 pattern"`).
    /// Used for `.completed` / `.failed` / `.cancelled` regardless of
    /// fold state, because the children have stopped moving.
    let completedTitle: String
    let children: [Child]

    init(activeTitle: String,
         expandedActiveTitle: String,
         completedTitle: String,
         children: [Child]) {
        self.activeTitle = activeTitle
        self.expandedActiveTitle = expandedActiveTitle
        self.completedTitle = completedTitle
        self.children = children
    }

    /// Pick the right title for the current `(status, fold)` pair.
    /// Single-source-of-truth for the three-state logic so layouts
    /// and any future consumers don't reimplement the switch.
    func resolvedTitle(status: ToolStatus, isExpanded: Bool) -> String {
        switch status {
        case .running:
            return isExpanded ? expandedActiveTitle : activeTitle
        case .completed, .failed, .cancelled:
            return completedTitle
        }
    }

    enum Child: Equatable, Sendable {
        case fileEdit(FileEditChild)
        case read(ReadChild)
        case bash(BashChild)
        case grep(GrepChild)
        case glob(GlobChild)
        case webFetch(WebFetchChild)
        case webSearch(WebSearchChild)
        case askUserQuestion(AskUserQuestionChild)
        case agent(AgentChild)
        /// Catch-all for tool kinds without a tailored child layout
        /// (Skill / Cron* / Send* / Todo* / Enter*/Exit* mode toggles
        /// / Task ops / unknown). Header-only — no expandable body.
        case generic(GenericChild)

        /// Stable identity used as a fold-state key and as the
        /// highlight scope discriminator.
        var id: UUID {
            switch self {
            case .fileEdit(let c): return c.id
            case .read(let c): return c.id
            case .bash(let c): return c.id
            case .grep(let c): return c.id
            case .glob(let c): return c.id
            case .webFetch(let c): return c.id
            case .webSearch(let c): return c.id
            case .askUserQuestion(let c): return c.id
            case .agent(let c): return c.id
            case .generic(let c): return c.id
            }
        }

        /// Header text for the given runtime `status` — `.running`
        /// pulls each payload's progressive form (`activeLabel`,
        /// e.g. `"Editing Sources/Greeter.swift"`); every other
        /// status pulls the past-tense form (`label`, e.g.
        /// `"Edit Sources/Greeter.swift"`). The Bridge fills both
        /// fields from `ToolUse.activeFragment` /
        /// `ToolUse.completedFragment` so the two forms are pre-
        /// computed when the child enters the transcript.
        ///
        /// Centralising on one method (parameterised by status)
        /// keeps `ToolGroupLayout` from re-implementing the switch
        /// at every header build.
        func headerLabel(for status: ToolStatus) -> String {
            switch status {
            case .running:
                return activeLabel
            case .completed, .failed, .cancelled:
                return label
            }
        }

        /// Past-tense / completed-form label — also the value used
        /// for `.failed` and `.cancelled` because those are terminal
        /// states that follow the same "tool has stopped moving"
        /// semantics as `.completed`.
        var label: String {
            switch self {
            case .fileEdit(let c): return c.label
            case .read(let c): return c.label
            case .bash(let c): return c.label
            case .grep(let c): return c.label
            case .glob(let c): return c.label
            case .webFetch(let c): return c.label
            case .webSearch(let c): return c.label
            case .askUserQuestion(let c): return c.label
            case .agent(let c): return c.label
            case .generic(let c): return c.label
            }
        }

        /// Progressive form — used only when the child's status is
        /// `.running`. Bridge feeds this from `ToolUse.activeFragment`.
        var activeLabel: String {
            switch self {
            case .fileEdit(let c): return c.activeLabel
            case .read(let c): return c.activeLabel
            case .bash(let c): return c.activeLabel
            case .grep(let c): return c.activeLabel
            case .glob(let c): return c.activeLabel
            case .webFetch(let c): return c.activeLabel
            case .webSearch(let c): return c.activeLabel
            case .askUserQuestion(let c): return c.activeLabel
            case .agent(let c): return c.activeLabel
            case .generic(let c): return c.activeLabel
            }
        }

        /// `true` when this child has an expandable body. Drives
        /// `ToolGroupLayout`'s decision to draw a chevron + register
        /// a fold hit on the header. Header-only kinds (`read`,
        /// `generic`) return `false` so the header reads as a static
        /// label rather than offering a no-op chevron.
        var hasExpandableBody: Bool {
            switch self {
            case .fileEdit, .bash, .grep, .glob, .webFetch, .webSearch,
                 .askUserQuestion, .agent:
                return true
            case .read, .generic: return false
            }
        }
    }
}

// Child payload structs (`FileEditChild`, `ReadChild`, etc.) and
// their auxiliary types (`DiffBlock`, etc.) live next to their
// renderers under `Layout/ToolGroupChildren/<Kind>/`. Keeping the
// payload next to its layout makes new child-kind work
// (data + layout + highlight) self-contained inside one folder,
// rather than threading through `Block.swift`.

/// Runtime status for a tool-call surface (a `toolGroup` host block
/// or one of its children). Pushed in through
/// `Transcript2Controller.setToolStatus(id:status:)` as the CLI
/// progresses; the value lives in `Transcript2Coordinator.statusStates`
/// — a sparse dict keyed by `Block.id` (group level) or `Child.id`
/// (child level), absent = `.completed`.
///
/// Status is **not** carried inside `Block.Kind` because:
/// - Status changes are far more frequent than content changes; routing
///   them through `Change.update` would needlessly evict highlight
///   tokens, drop selection, and force callers to rebuild the
///   `Block.Kind` payload each time.
/// - Multiple foldable surfaces (group + each child) share one row;
///   per-surface dispatch wants a separate sparse keyspace, mirroring
///   how `foldStates` keys the same id space.
///
/// `ToolGroupLayout` reads a snapshot at layout-build time and folds
/// the value into the per-header colour palette. Adding a new visual
/// rule = extend `ToolGroupLayout.titleColor(for:hovered:)` and
/// `chevronTint(for:hovered:)`.
enum ToolStatus: Equatable, Sendable {
    /// Default visible state — past-tense label, secondary-label
    /// colour, chevron at idle alpha. Matches the dict's absent
    /// reading so untracked tools render as today.
    case completed
    /// Tool is currently executing. Renders the header in the
    /// hover-tier brighter colour so the row reads as "live"
    /// without needing a spinner.
    case running
    /// Tool produced an error. Header + chevron paint in
    /// `systemRed`. `message` is reserved for future inline error
    /// labelling and currently has no visual effect.
    case failed(message: String?)
    /// Tool was cancelled or interrupted. Header dims one tier
    /// below `.completed` so cancelled rows visually de-emphasise
    /// in a busy transcript.
    case cancelled
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
    /// a section break, a smaller bottom keeps the heading glued to the
    /// content it owns. Heading bottom scales with level (h1 6 / h2 4 /
    /// h3-6 2) so the perceived gap below a heavier heading isn't dwarfed
    /// by the heading's visual mass — same 6pt below a 26pt h1 and below
    /// an 18pt h3 reads as "cramped" vs "tight" respectively. Combined
    /// with paragraph `top: 6`, the resulting heading→p gaps are 12 / 10 /
    /// 8 pt, all ≤ p↔p 12pt so proximity still glues the heading to its
    /// body, and all ≥ 0.4em of the heading's font size for breathing.
    /// Top/bottom ratio stays ~4–5:1 across levels so "above is break,
    /// below is owned" reads uniformly.
    nonisolated static func blockPadding(
        for kind: Block.Kind
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .heading(let level, _):
            let clamped = max(1, min(6, level))
            switch clamped {
            case 1: return (top: 24, bottom: 6)
            case 2: return (top: 16, bottom: 4)
            default: return (top: 10, bottom: 2)
            }
        case .paragraph, .list, .blockquote:
            // Blockquote sits in the soft-edged tier with paragraphs —
            // it has no container chrome, only a left bar, so it should
            // share paragraphs' rhythm rather than the harder 8/8 used
            // for visible-bordered blocks.
            return (top: 6, bottom: 6)
        case .image, .table, .codeBlock, .toolGroup:
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

    /// Background fill — Xcode "Default" canvas tone with a light-mode
    /// nudge for separation: `#F5F5F7` light / `#1F1F24` dark. Dark uses
    /// the editor's `DVTSourceTextBackground` verbatim (already darker
    /// than the chat window). Light shifts off pure `#FFFFFF` so the
    /// card edge is visible against an otherwise white transcript —
    /// `#F5F5F7` is the same off-white Apple's developer docs use for
    /// inline samples, so it still reads as "Xcode-adjacent."
    nonisolated static let codeBlockBackgroundColor: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x1F / 255.0, green: 0x1F / 255.0, blue: 0x24 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
    }

    /// Verbatim source → monospaced attributed string. Whitespace and
    /// newlines preserved; no inline parsing.
    ///
    /// Syntax highlighting is opt-in via `tokens`: when non-nil, walks
    /// the token list and emits per-segment foreground colors via
    /// `SyntaxTheme.color(for:scheme:)`. The colors are wrapped in a
    /// dynamic `NSColor(name:dynamicProvider:)` so a single attributed
    /// string tracks light/dark appearance without rebuild.
    ///
    /// Plain (`tokens == nil`) is the cold-render path used until
    /// `Transcript2HighlightStorage` finishes its async tokenize pass.
    nonisolated static func codeBlockAttributed(
        code: String, tokens: [SyntaxToken]?
    ) -> NSAttributedString {
        let font = codeBlockFont
        if let tokens, !tokens.isEmpty {
            let result = NSMutableAttributedString()
            for token in tokens {
                let scope = token.scope
                let color = NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                    let scheme: ColorScheme = match == .darkAqua ? .dark : .light
                    return NSColor(SyntaxTheme.color(for: scope, scheme: scheme))
                }
                result.append(NSAttributedString(string: token.text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            }
            return result
        }
        return NSAttributedString(string: code, attributes: [
            .font: font,
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

    /// Header chrome label / glyph color. `secondaryLabel` so the band
    /// reads as chrome rather than competing with the body's syntax
    /// colors.
    nonisolated static let codeBlockHeaderForeground: NSColor = .secondaryLabelColor

    /// Header label / glyph point size. 11pt matches the SF Symbol
    /// weight calibration `codeBlockHeaderHeight` was chosen for.
    nonisolated static let codeBlockHeaderFontSize: CGFloat = 11

    /// Left inset for the language label inside the header. Aligned
    /// with `bubbleHorizontalPadding` so the label sits in the same
    /// vertical column as the body code beneath it — reads as a single
    /// flush left edge running the full block.
    nonisolated static var codeBlockHeaderLeftInset: CGFloat { bubbleHorizontalPadding }

    /// Right inset for the copy button hit zone. Anchored at the
    /// corner-radius pivot so the hit rect's right edge lands exactly
    /// where the rounded corner begins — the glyph itself (smaller than
    /// the hit zone) then floats just inside the curve, hugging the
    /// edge as the copy icon should as chrome.
    nonisolated static var codeBlockCopyRightInset: CGFloat { structuralCornerRadius }
    /// Hairline divider color between header and body.
    nonisolated static let codeBlockDividerColor: NSColor = .separatorColor

    // MARK: - Tool header geometry
    //
    // Shared header style for `toolGroup` rows. Used at two tiers:
    // ① the group header (group title + chevron) at the row top, and
    // ② each item header (file path + chevron) inside the expanded
    // group. Both tiers share one set of constants so the row reads as
    // a uniform stack — same height / font / color / chevron size, no
    // icon, no extra inset on top of the row's standard horizontal
    // padding. Identical to the old `NativeTranscript.GroupComponent`
    // theme values: 12pt medium / `secondaryLabel` / 8pt chevron /
    // 6pt title↔chevron gap.

    /// Tool-header row height — group header and item header both use
    /// this. Matches `codeBlockHeaderHeight` so a header band tucked
    /// against a code block downstream reads at one tier.
    nonisolated static let toolHeaderHeight: CGFloat = 24

    /// Title typography — 12pt medium / `secondaryLabel`, matching the
    /// old `GroupComponent`.
    nonisolated static var toolHeaderFont: NSFont {
        NSFont.systemFont(ofSize: 12, weight: .medium)
    }
    nonisolated static var toolHeaderForeground: NSColor {
        .secondaryLabelColor
    }

    /// Chevron edge length — matches old `GroupComponent`'s 8pt glyph
    /// so the disclosure triangle reads as a small directional hint,
    /// not a button.
    nonisolated static let toolHeaderChevronSize: CGFloat = 8

    /// Stroke width for the chevron's two-segment `>` path. 1.4pt
    /// matches the old `GroupSideCar.chevronLayer.lineWidth`.
    nonisolated static let toolHeaderChevronLineWidth: CGFloat = 1.4

    /// Chevron alpha — idle / hover. Same values as the old
    /// `theme.groupChevronIdleAlpha / HoverAlpha`. Hover brightening
    /// is the primary visual hover affordance (alongside the title
    /// flipping to `.labelColor`).
    nonisolated static let toolHeaderChevronIdleAlpha: CGFloat = 0.35
    nonisolated static let toolHeaderChevronHoverAlpha: CGFloat = 0.85

    /// Hover-state title colour. Idle = `toolHeaderForeground`
    /// (`.secondaryLabelColor`); hover swaps to the brighter
    /// `.labelColor` so the active row reads as "primed".
    nonisolated static var toolHeaderHoverForeground: NSColor {
        .labelColor
    }

    /// Title ↔ chevron horizontal gap.
    nonisolated static let toolHeaderChevronGap: CGFloat = 6

    /// Hit-rect outset around `[title.minX, chevron.maxX]` — gives the
    /// header a friendlier click target than the bare glyphs.
    nonisolated static let toolHeaderHitPadding: CGFloat = 6

    /// Vertical gap between adjacent item headers inside an expanded
    /// group, and between an item header and its expanded body. Matches
    /// the old `GroupComponent.groupChildSpacing` value so the gestalt
    /// "these belong together" pull stays the same.
    nonisolated static let toolHeaderChildSpacing: CGFloat = 4

    /// Fold-transition duration shared by the row-height animation
    /// (`Coordinator.toggleFold`'s `NSAnimationContext` group), the
    /// chevron rotation animation, the entry-frame slide, and the
    /// cell's cross-fade transition — all driven from
    /// `BlockCellView.beginFoldTransition`. Kept on one constant so
    /// the row height, the chevron, the entry slide, and the appearing
    /// content all finish on the same beat.
    nonisolated static let foldAnimationDuration: CFTimeInterval = 0.22

    // MARK: - Diff body geometry
    //
    // The hunks panel inside an expanded tool-group item. Drawn as a
    // `codeBlock`-style rounded card — same corner radius, body
    // background, divider color — so a diff body and a fenced code
    // block sit at one structural tier.

    /// Body monospaced font for diff lines. Same as `codeBlockFont` so
    /// gutter / sign / content all share one cap-height.
    nonisolated static var diffBodyFont: NSFont { codeBlockFont }

    /// Spacing between the gutter character cells and the sign column
    /// /content. `0` matches the old `NativeDiffView` (which fed a
    /// space-padded gutter string directly into NSTextStorage); the
    /// vertical column separator is purely the gutter's background-fill
    /// edge.
    nonisolated static let diffGutterInternalPadding: CGFloat = 0

    /// Hairline column divider between gutter and sign/content area —
    /// gives the diff a "two-column" reading. Same color as the header
    /// divider so the chrome reads as one piece.
    nonisolated static var diffColumnDividerColor: NSColor { codeBlockDividerColor }

    /// Background under the inter-hunk separator row (`···`).
    nonisolated static var diffSeparatorBackground: NSColor {
        DiffColors.dynamicSeparatorBg
    }
    nonisolated static var diffSeparatorForeground: NSColor {
        DiffColors.dynamicSeparatorFg
    }

    /// Container background tint behind every line — DiffColors' table
    /// background. Slightly darker than the surrounding chat surface so
    /// the line backgrounds read against it.
    nonisolated static var diffContainerBackground: NSColor {
        DiffColors.dynamicTableBg
    }

    /// Gutter line-number foreground.
    nonisolated static var diffGutterForeground: NSColor {
        DiffColors.dynamicGutterText
    }

    /// Total horizontal padding inside the body band (left of gutter,
    /// right of content). 0 to match NativeDiffView: the gutter / sign /
    /// content backgrounds extend edge-to-edge of the container.
    nonisolated static let diffBodyHorizontalPadding: CGFloat = 0

    /// Vertical padding between the header's bottom edge and the first
    /// body line — matches `codeBlockBodyVerticalPadding` but symmetric
    /// to the bottom for a diff. We don't pad inside the body itself;
    /// the line backgrounds extend the full body band.
    nonisolated static let diffBodyVerticalPadding: CGFloat = 0

    /// Breathing room inside the rounded card above the first diff line
    /// and below the last. Keeps glyphs from visually attaching to the
    /// card's top/bottom rounded edges. The line-background fills (per
    /// line) sit *inside* this band so the first/last lines still pick
    /// up their add/del tint right up to the inner edge — only the
    /// glyph baseline is pushed in by `diffInnerVerticalPadding`.
    nonisolated static let diffInnerVerticalPadding: CGFloat = 2

    /// Add / del sign colors — used both for the `+ -` glyphs in the
    /// sign column and for per-line backgrounds resolved off `DiffColors`.
    nonisolated static var diffSignAddForeground: NSColor {
        DiffColors.dynamicSignAdd
    }
    nonisolated static var diffSignDelForeground: NSColor {
        DiffColors.dynamicSignDel
    }

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

    /// Inline-code foreground. Matches `SyntaxTheme`'s
    /// `identifier.function` teal (the tint used for `hljs-title
    /// function_` and bare `hljs-title` inside code blocks — i.e. the
    /// shade a function declaration name like `setFocused` renders in)
    /// so an inline `code` reference reads in the same teal hue family
    /// as function names inside fenced code blocks, one notch lighter
    /// than the deeper class/struct/enum teal. Dynamic NSColor —
    /// `.cgColor` resolves against the cell's effective appearance at
    /// draw time, so light / dark switching is automatic.
    nonisolated static let inlineCodeColor: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(srgbRed: 0x67 / 255.0, green: 0xb7 / 255.0, blue: 0xa4 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x31 / 255.0, green: 0x6d / 255.0, blue: 0x74 / 255.0, alpha: 1.0)
    }

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
                attrs[.foregroundColor] = inlineCodeColor
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
