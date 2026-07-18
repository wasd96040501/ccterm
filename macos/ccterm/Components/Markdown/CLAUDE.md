# Markdown

Reusable AppKit component. Two halves that share one model:

1. **Parse** — GFM markdown source → block IR.
2. **Render** — a block (paragraph / heading / list / table / code / quote /
   rule / image / user bubble / attachments) → an immutable, off-main
   `Layout` value that a host cell self-draws and text-selects inside any
   `NSTableView`.

UI-free of app state: imports only `AgentSDK` / `AppKit` / `Foundation`.
Knows nothing about `Session`, sessions, streaming, tools, or any feature.
The dependency arrow is one-way: features import Markdown; Markdown imports
no feature.

## Structure

```
Components/Markdown/
├── (parser: MarkdownAutolink · MarkdownConvert · MarkdownDocument · MarkdownMath · MarkdownTypes)
├── MarkdownToBlocks.swift        markdown source → [Block]
├── StableBlockID.swift           string → SHA-stable UUID (row id / cache key / selection key)
├── SyntaxTheme.swift             scope → color map (code coloring)
├── Model/
│   ├── Block.swift               render-ready block + BlockStyle typography/geometry constants live at file tail
│   ├── InlineNode.swift          recursive inline IR (text / strong / emphasis / code / link / lineBreak)
│   └── BlockStyle.swift          typography + per-kind geometry constants + attributed builders
├── Layout/
│   ├── RowLayout.swift           type-erased enum over the per-kind layouts + HitAction / InteractiveHit
│   ├── TextLayout.swift          Core Text layout (paragraph / heading)
│   ├── HeaderLayout.swift        title-only header row
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
    └── SelectionAdapter.swift    per-row selection surface (SelectionAdapter + SelectionRange + LayoutPosition)
```

## Model

- `Block` is the render-ready unit: a stable `id: UUID` (caller-supplied,
  never content-hashed) + a `Kind`. `Kind` covers markdown blocks plus
  `userBubble` / `userAttachments`.
- `InlineNode` is the inline IR the block layer holds but does not parse.
- `BlockStyle` is the single home for typography, colors, per-kind padding,
  the centered-column width band (`minLayoutWidth` / `maxLayoutWidth` /
  `clampedLayoutWidth` / `cellOriginX`), and the attributed-string builders.

## Layout

- One immutable `XxxLayout` value per kind. It is a **pure function of
  `(content, width)`** — no hover / selection / animation / fold / status
  input, no stored mutable state.
- Each layout is **off-main-safe** (`nonisolated`): a host may typeset it on
  a background actor. It exposes `totalHeight`, `measuredWidth`, and
  `draw(in:origin:)`.
- `RowLayout` is the type-erased enum the host cell draws through uniform
  APIs — `totalHeight` / `measuredWidth` / `draw` / `drawBackplate` /
  `selectionAdapter` / `interactiveHits` / `iBeamRect`. The host cell never
  switches on the enum.
- Adding a kind = add the `Block.Kind` case, add the `XxxLayout` file, add
  one `RowLayout` case, extend each uniform-API switch.

## Selection

- The component provides **per-row geometry only**: `SelectionAdapter`
  (struct + closures) exposes point→character index, range→rects,
  range→text, and searchable regions. `SelectionRange` / `LayoutPosition`
  are the range types.
- The **cross-row selection engine and the `NSTableView` host live in the
  adopter**, not here. Selection state is a stable `(row id, char offset)`;
  draw rects come from the visible cell, copied text from the model.

## Constraints

- **Highlighting is injected, not owned.** `CodeBlockLayout` /
  `BlockStyle.codeBlockAttributed` accept optional pre-computed
  `[SyntaxToken]`; when absent they render plain. The async tokenizer /
  highlight store lives in the adopter. `SyntaxTheme` is a pure scope→color
  map.
- **No feature vocabulary.** Tool cards, loading pills, streaming diffs,
  fold/status state, session wiring, and sheet presentation are NOT part of
  this component.
- **Layouts are stateless and pure.** Any per-row UI state (selection, fold,
  status) is a host concern, passed in at draw time — never stored on a
  layout.
- **Stable ids drive identity.** `Block.id` / row ids are caller-supplied
  and never derived from a content hash.
- **Layout is derived, never authoritative.** A host's layout cache entry is
  always safe to drop and recompute; a width mismatch is a self-healing
  miss.

## Adopter integration

1. Build blocks: `MarkdownToBlocks.blocks(source:idPrefix:)`; assign row ids
   via `StableBlockID.derive(...)`.
2. Per row: dispatch `Block.Kind → XxxLayout.make(...)`, wrap in a
   `RowLayout`; answer `heightOfRow` from `totalHeight`; paint it in your
   `NSView` cell's `draw(_:)` via `RowLayout.draw`.
3. Selection: own a coordinator that reads `RowLayout.selectionAdapter`;
   forward the mouse-drag gesture and `copy(_:)` / `selectAll(_:)`.
4. Centered column, row padding, live-resize refill, and the table/scroll
   host are all adopter responsibilities — the component stays
   column-agnostic (it only ever sees a `maxWidth` and a caller origin).
