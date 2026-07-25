# Markdown

Reusable AppKit component. Two halves that share one model:

1. **Parse** — GFM markdown source → block IR (via the swift-markdown
   `Markdown` package).
2. **Render** — one **`NSView` subclass per block kind** (paragraph /
   heading / list / table / code / quote / rule / image / user bubble /
   attachments), each drawing an immutable, off-main measure it was
   handed, with character-level text selection inside any container.

From an adopter's point of view this is not a rendering engine: it is a
set of block views plus the geometry needed to select text across them.
You put them in your own `NSTableView` / `NSStackView` / window.

Owns no app state: it imports no `Session` / feature type, and no code
path reaches back into `Content/Chat/Transcript` or `Services/Session`.
Hosts import Markdown; Markdown imports no feature.

## Imports

`AppKit` / `Foundation` / `CoreText` (measure + draw), `Markdown`
(parser), `CryptoKit` (`StableBlockID` hashing), and `SwiftUI` — used
**only** by `SyntaxTheme`, which returns a SwiftUI `Color` that callers
bridge with `NSColor(...)`. No `AgentSDK`, no app/session/feature
imports. The component does depend on the sibling `Components/Diff` and
on `Models/SyntaxToken` (both same-target).

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
├── Layout/                       measure primitives shared across kinds
│   ├── TextLayout.swift          Core Text typeset (used directly by paragraph / heading, embedded by the rest)
│   └── CopyChrome.swift          copy-button primitive (id + hitRect + draw); shared with Components/Diff
├── Selection/
│   └── SelectionAdapter.swift    SelectionAdapter + SelectionRange + LayoutPosition + SearchableRegion
└── View/                         one folder per block kind
    ├── MarkdownBlockView.swift   base class: layer cache, centered column, selection band, cursor + click
    ├── HitAction.swift           what a click does (openURL / copy / host intents)
    ├── InteractiveHit.swift      (rect, action) hot zone
    ├── Paragraph/MarkdownParagraphView.swift
    ├── Heading/MarkdownHeadingView.swift
    ├── CodeBlock/{MarkdownCodeBlockView, CodeBlockLayout}.swift
    ├── List/{MarkdownListView, ListLayout}.swift
    ├── Table/{MarkdownTableView, TableLayout}.swift
    ├── Blockquote/{MarkdownBlockquoteView, BlockquoteLayout}.swift
    ├── ThematicBreak/{MarkdownThematicBreakView, ThematicBreakLayout}.swift
    ├── Image/{MarkdownImageView, ImageLayout}.swift
    ├── UserBubble/{MarkdownUserBubbleView, UserBubbleLayout}.swift
    └── UserAttachments/{MarkdownUserAttachmentsView, UserAttachmentsLayout}.swift
```

A kind's folder holds its view **and** the measure only that view draws.
`Layout/` holds the two measures more than one kind uses.

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

## Measures

- One immutable `XxxLayout` value per kind — a **pure function of
  `(content, width)`** with no hover / selection / animation state and no
  stored `var`. Each is **off-main-safe** (`nonisolated static make`) and
  exposes `totalHeight` / `measuredWidth` / `draw(in:origin:)`.
- Core Text line breaking is a function of width, so a measure is only
  valid at the width it was made for. A host cache must key on
  `(id, width)`; a width change is a miss, not a patch.
- **There is no type erasing a measure to a common layout type** — no
  `RowLayout` enum, no layout protocol. Each view knows only its own
  measure; anything a host needs across kinds (height, selection
  geometry) it reads per kind and stores in its own value.

## Views

- Every block view is a plain `NSView` subclass of `MarkdownBlockView` —
  **not** `NSTableCellView`. `tableView(_:viewFor:row:)` returns `NSView?`
  already, so staying a plain view is what makes the same class usable in
  a stack view or standalone.
- The base class owns only the kind-independent machinery: `wantsLayer` +
  `.onSetNeedsDisplay` bitmap cache, the centered content column
  (`contentOrigin` centers `contentWidth` in `bounds`, and `draw(_:)`
  clips to it), the selection band under the glyphs, cursor rects, and
  click dispatch over `interactiveHits`. Subclasses override
  `contentHeight` / `measuredWidth` / `selectionAdapter` /
  `interactiveHits` / `iBeamRect` / `drawBackplate` / `drawContent`.
- A view is **dumb**: its only data entry point is
  `configure(_ measure:width:)`. It does not typeset — the host makes the
  measure (so it can do it off-main and cache it across view reuse) and
  hands it in.
- Names carry the `Markdown` prefix so they never read as their AppKit
  namesakes (`MarkdownTableView` ≠ `NSTableView`, `MarkdownImageView` ≠
  `NSImageView`).
- `HitAction` is closed: `openURL` / `copy` are handled by the base view;
  `openUserBubbleSheet` / `openImagePreview` are host intents the base
  view ignores.

## Selection

- The component provides **per-row geometry only**: `SelectionAdapter`
  (struct + closures) exposes point→character index, range→rects,
  range→text, and searchable regions. `SelectionRange` / `LayoutPosition`
  are the position/range types (`LayoutPosition` still carries `.diff` /
  `.textCard` cases from richer bodies).
- The **cross-view selection engine and the container live in the
  adopter**, not here — the same split TextKit uses, where the layout
  manager owns the algorithm and views only answer geometry. Selection
  state is a stable `(row id, char offset)`; draw rects come from the
  visible view, copied text from the model.

## Constraints

- **Highlighting is injected, not owned.** `CodeBlockLayout` /
  `BlockStyle.codeBlockAttributed` accept optional pre-computed
  `[SyntaxToken]`; absent → plain. The async tokenizer / highlight store
  lives in the adopter. `SyntaxTheme` is a pure scope→color map.
- **Measures are stateless and pure.** Any per-row UI state (selection,
  fold, status) is a host concern passed in at draw time, never stored on
  a measure.
- **No live/host machinery here.** Streaming, tool-call bodies,
  fold/status state, sheet presentation, and the table/scroll host live in
  adopters — not in this component.
- **Stable ids drive identity.** `Block.id` / row ids are caller-supplied,
  derived from position, never from a content hash.
- **Measures are derived, never authoritative.** A host cache entry is
  always safe to drop and recompute; a width mismatch is a self-healing
  miss.
- **Diff geometry is shared with `Components/Diff`.** `BlockStyle`'s diff
  constants, `TextLayout` and `CopyChrome` are used by
  `Components/Diff` (`DiffLayout` / `DiffBlock` / `GutterSpec`); the two
  components are co-dependent, not independently vendored.

## Adopter integration

1. Build blocks: `MarkdownToBlocks.blocks(source:idPrefix:)`; assign row
   ids via `StableBlockID.derive(...)`.
2. Per row, typeset once and cache by `(id, width)`: dispatch
   `Block.Kind → XxxLayout.make(...)`. Because the measures have no
   common type, the cache is one dictionary per kind — see
   `Content/Chat/Transcript/Store/TranscriptLayoutCache.swift` for a
   worked example, including the off-main batch.
3. Answer `heightOfRow` from the cached measure's `totalHeight`; in
   `viewFor`, switch on the kind to pick the view class and hand it the
   cached measure via `configure(_:width:)`.
4. Selection: own a coordinator that reads each row's
   `selectionAdapter`; forward the mouse-drag gesture and `copy(_:)` /
   `selectAll(_:)`.
5. The view centers its own content column, so a host row can span the
   full width; the typeset width itself (`clampedLayoutWidth` net of
   `blockHorizontalPadding`) is the host's single chokepoint. Row
   padding, live-resize refill, and the table/scroll host are adopter
   responsibilities — a measure only ever sees a `maxWidth`.
