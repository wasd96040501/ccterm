# Markdown

Reusable AppKit component. Two halves that share one model:

1. **Parse** — GFM markdown source → block IR (via the swift-markdown
   `Markdown` package).
2. **Render** — a block (paragraph / heading / list / table / code / quote /
   rule / image / user bubble / attachments) → an immutable, off-main
   `Layout` value that a host cell self-draws and text-selects inside any
   `NSTableView`.

Owns no app state: it imports no `Session` / feature type, and no code path
reaches back into `Content/Chat/Transcript` or `Services/Session`. Hosts
import Markdown; Markdown imports no feature.

## Imports

`AppKit` / `Foundation` / `CoreText` (layout + draw), `Markdown` (parser),
`CryptoKit` (`StableBlockID` hashing), and `SwiftUI` — used **only** by
`SyntaxTheme`, which returns a SwiftUI `Color` that callers bridge with
`NSColor(...)`. No `AgentSDK`, no app/session/feature imports. The component
does depend on the sibling `Components/Diff` and on `Models/SyntaxToken`
(both same-target).

## Structure

```
Components/Markdown/
├── (parser: MarkdownAutolink · MarkdownConvert · MarkdownDocument · MarkdownMath · MarkdownTypes)
├── MarkdownToBlocks.swift        markdown source → [Block]
├── StableBlockID.swift           positional seed → SHA-stable UUID (row id / cache key / selection key)
├── SyntaxTheme.swift             scope → color map (returns SwiftUI Color)
├── Model/
│   ├── Block.swift               Block + ListBlock + TableBlock + BlockStyle (typography/geometry/attributed builders)
│   └── InlineNode.swift          recursive inline IR (text / strong / emphasis / code / link / lineBreak)
├── Layout/
│   ├── RowLayout.swift           type-erased enum over the per-kind layouts + HitAction / InteractiveHit
│   ├── TextLayout.swift          Core Text layout (paragraph / heading)
│   ├── HeaderLayout.swift        title-only header row (host-built; no Block.Kind of its own)
│   ├── CodeBlockLayout.swift     card + lang badge + CopyChrome + embedded TextLayout + optional token color
│   ├── ListLayout.swift          recursive list, self-drawn markers / checkboxes
│   ├── TableLayout.swift         CSS-like column allocation + self-drawn grid
│   ├── BlockquoteLayout.swift    left bar + embedded TextLayout
│   ├── ThematicBreakLayout.swift hairline rule
│   ├── ImageLayout.swift         aspect-fit
│   ├── UserBubbleLayout.swift    right-aligned bubble + truncation + chevron
│   ├── UserAttachmentsLayout.swift right-aligned thumbnail strip
│   └── CopyChrome.swift          copy-button primitive (id + hitRect + draw)
└── Selection/
    └── SelectionAdapter.swift    SelectionAdapter + SelectionRange + LayoutPosition + SearchableRegion
```

## Model

- `Block` is the render-ready unit: a stable `id: UUID` (caller-supplied,
  never content-hashed) + a `Kind`. `Kind` covers `heading` / `paragraph` /
  `image` / `list` / `table` / `codeBlock` / `blockquote` / `thematicBreak` /
  `userBubble` / `userAttachments`.
- `InlineNode` is the inline IR the block layer holds but does not parse.
- `BlockStyle` (in `Block.swift`) is the single home for typography, colors,
  per-kind padding, the attributed-string builders, **and** the centered
  content-column band (`minLayoutWidth` / `maxLayoutWidth` /
  `clampedLayoutWidth` / `cellOriginX`).

## Layout

- One immutable `XxxLayout` value per kind — a **pure function of
  `(content, width)`** with no hover / selection / animation state and no
  stored `var`. Each is **off-main-safe** (`nonisolated static make`) and
  exposes `totalHeight` / `measuredWidth` / `draw(in:origin:)`.
- `RowLayout` is the type-erased enum the host cell draws through uniform
  APIs — `totalHeight` / `measuredWidth` / `firstLineCenterY` /
  `drawBackplate` / `draw` / `selectionAdapter` / `interactiveHits` /
  `iBeamRect`. The host cell never switches on the enum.
- `RowLayout` cases: `text` / `image` / `list` / `table` / `codeBlock` /
  `blockquote` / `thematicBreak` / `userBubble` / `userAttachments` /
  `header`. Most map 1:1 to a `Block.Kind`; `header` is the exception — a
  host-built title-only row (used e.g. for a group-narration line) with no
  `Block.Kind`.
- `HitAction`: `openURL` / `copy` (handled generically) + `openUserBubbleSheet`
  / `openImagePreview` (intents a host may act on or ignore).

## Selection

- The component provides **per-row geometry only**: `SelectionAdapter`
  (struct + closures) exposes point→character index, range→rects,
  range→text, and searchable regions. `SelectionRange` / `LayoutPosition`
  are the position/range types (`LayoutPosition` still carries `.diff` /
  `.textCard` cases from richer bodies).
- The **cross-row selection engine and the `NSTableView` host live in the
  adopter**, not here. Selection state is a stable `(row id, char offset)`;
  draw rects come from the visible cell, copied text from the model.

## Constraints

- **Highlighting is injected, not owned.** `CodeBlockLayout` /
  `BlockStyle.codeBlockAttributed` accept optional pre-computed
  `[SyntaxToken]`; absent → plain. The async tokenizer / highlight store
  lives in the adopter. `SyntaxTheme` is a pure scope→color map.
- **Layouts are stateless and pure.** Any per-row UI state (selection, fold,
  status) is a host concern passed in at draw time, never stored on a layout.
- **No live/host machinery here.** Streaming, tool-call bodies, fold/status
  state, sheet presentation, and the table/scroll host live in adopters —
  not in this component.
- **Stable ids drive identity.** `Block.id` / row ids are caller-supplied,
  derived from position, never from a content hash.
- **Layout is derived, never authoritative.** A host layout-cache entry is
  always safe to drop and recompute; a width mismatch is a self-healing miss.
- **Diff geometry is shared with `Components/Diff`.** `BlockStyle`'s diff
  constants and `Components/Diff` (`DiffLayout` / `DiffBlock` / `GutterSpec`)
  are used together; the two components are co-dependent, not independently
  vendored.

## Adopter integration

1. Build blocks: `MarkdownToBlocks.blocks(source:idPrefix:)`; assign row ids
   via `StableBlockID.derive(...)`.
2. Per row: dispatch `Block.Kind → XxxLayout.make(...)`, wrap in a
   `RowLayout`; answer `heightOfRow` from `totalHeight`; paint it in your
   `NSView` cell's `draw(_:)` via `RowLayout.draw`.
3. Selection: own a coordinator that reads `RowLayout.selectionAdapter`;
   forward the mouse-drag gesture and `copy(_:)` / `selectAll(_:)`.
4. The centered-column offset comes from `BlockStyle` (`cellOriginX` /
   `clampedLayoutWidth`); row padding, live-resize refill, and the
   table/scroll host are adopter responsibilities — individual layouts see
   only a `maxWidth` and a caller origin.
