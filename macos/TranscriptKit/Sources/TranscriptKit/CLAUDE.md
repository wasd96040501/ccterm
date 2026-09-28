# TranscriptKit internals

Invariants of the renderer target. Package-level API rules are in [../../CLAUDE.md](../../CLAUDE.md). Measurements and the reasoning behind a type live in its doc comment; this file lists the rules that span types.

## Rows, blocks, painting

- A `.markdown` / `.userMessage` row is parsed to `MarkdownIR`, built into blocks (`Layout/Blocks/`), stacked by `BlockStack` (which assigns origins and index bases at stacking time), and drawn by `BlockView` onto `SurfaceLayer`s.
- **Directories depend one way: `Layout/` ← `Layout/Blocks/` ← `Markdown/` ← the root.** `Layout/` is the primitives every block and `BlockView` read — including `TextStyle` (the faces and colours shared by markdown and the user bubble) and `TranscriptFindHighlighting`; `Layout/Blocks/` is block geometry and knows no markdown; `Markdown/` lowers the IR into blocks and owns every markdown-only decision — which face a heading or a table header is set in (asked of `TextStyle`), which marker a list item gets and how wide the column is (`MarkdownListBuilder`; `ListRow` only draws it); the root is the view and its collaborators. A type needed by a lower directory moves down; `make arch SCOPE=TranscriptKit/Sources/TranscriptKit` must report no unit cycle.
- A row paints onto `SurfaceLayer` sublayers, not the view's own layer, because CoreAnimation composites `contents` **below** sublayers. Anything that must sit under the glyphs (the hover band) needs the glyphs on a surface above it.
- **`SurfaceLayer.draw(in:)` makes the view's effective appearance current itself.** A sublayer's draw is CoreAnimation's call and gets no appearance; without this a window with its own appearance draws rows in the system's. In-process `cacheDisplay` hides the bug (it sets appearance on the way) — only a window-server capture shows it.
- **Layer colours don't follow appearance.** `NSColor`s in a paint list resolve at draw time, so a repaint fixes them; a `CGColor` on a layer (the hover band) must be re-resolved in `viewDidChangeEffectiveAppearance`, and a hand-added layer's `contentsScale` maintained by hand.
- **The hover band is a `CAShapeLayer`, not a `PaintItem`** — the only thing on its own clock. A paint list has no notion of time; a layer fades on the render server with nothing redrawn. The press tint (8% → 16%) and its geometry (rects inflated 2, corner 4) are Telegram's; each is one constant in `BlockView`.
- A link is anything `link(at:)` answers for — including a truncated user message's More — so band, pointing hand and press-is-a-click are `BlockView`'s one mechanism.

## Selection

- `TextSelection` belongs to the transcript, keyed by row identity and renumbered by every mutation (as the scroll anchor is). Each `BlockView` is handed only its part to draw, the way `NSTableView` sets `isSelected`.
- The first responder is the table (document view), as with `NSTextView`: it takes focus on press, answers `copy:`, drops the selection when focus leaves.
- **Keys:** the table answers only the scrolling commands and passes every other key to the next responder **as the event** — never through `NSTableView`'s `keyDown`, which moves a row selection the transcript doesn't have. That is how a host types into its input while the transcript has focus; there is no API for it.
- A press is tracked to its release in **a tracking loop inside `mouseDown`** (`NSTextView`'s shape). The focus depends on pointer *and* content position, so it is re-read on drag, on a periodic autoscroll tick past an edge, and on scroll-wheel events. Don't dispatch drags to the pressed view: they stop when the hand stops, and the view may already be in the reuse pool.
- Idle cost is zero: binding a row reads its part from four integers; the loop walks visible rows only when the focus moved.
- A capped user message allows selecting into its hidden tail ("copy what I sent"); find does not (below).

## `RowCache`: heights for every row, trees for a few

- Entries are keyed by `TranscriptRow.ID` and trusted only while `(content, width)` matches; a stale entry re-measures rather than rendering wrong. Compare **whole `TranscriptRowContent` values**, not their text — the same string measures differently as `.markdown` vs `.userMessage`.
- **One recipe, on the cache:** `RowCache.Entry.init(measuring:width:reusing:)` is the only place a content case is built and measured — the cache, `PreparedRows.measuring(_:width:)` off-main, a find's walk and Copy all go through it. `TranscriptRowContent` stays a Foundation-only value the host builds; it names no block or memo.
- Every row keeps its height for its lifetime; typeset trees are held up to `RowCache.residentBudget`, least recently drawn evicted first. An evicted row is re-typeset when drawn, rebuilt off-main on a width change, and built-then-dropped by a find.
- `removeRows` / `reloadData` walk the data source to find orphaned entries (`sweepCache()`); acceptable because those operations re-tile everything below anyway.
- An unexplained cost is ours until measured otherwise — check this package's own bookkeeping before blaming `NSTableView`.

## Width changes

- **Mid-drag** (`inLiveResize`, including an `NSSplitView` divider drag) only on-screen rows re-measure.
- **At the end** (`viewDidEndLiveResize`, or any non-drag width change) `beginRemeasuringOffscreenRows(at:)` re-measures on-screen rows inside the pass and hands the rest — only rows that already had an entry — to the cooperative pool. Rules it depends on:
  - **Order outward from the viewport** (`staleRowsOutwardFromViewport(at:)`) and **publish as produced**: the only window a reader can meet is "time to correct the next screenful".
  - **Invalidate each batch's own rows**, then one full `noteHeightOfRows` at the end. `noteHeightOfRows` re-asks inside the call; a full invalidation with most rows uncorrected measures them all on main.
  - **A sliding window of `activeProcessorCount` tasks**, not the whole set queued at once — thousands of runnable children starve the parent job that has to hop to main.
  - **Pace batches by the cost of applying one** (collect ~20× the last apply's cost), not by row count or a fixed time slice.
  - Entries crossing the actor boundary carry their recipe (`RowCache.Body`); without it the first resize after a cold load rebuilds everything.
  - A row scrolled into before its correction lands is left as is; never call `noteHeightOfRows` from inside the table's own layout (re-entrant, measures at two widths).
- **A width change outside a drag must not animate rows** — it opens `mutate`'s suppressed animation group (`ResizeRemeasureTests.testAWidthChangeOutsideADragDoesNotAnimateTheRows`).
- **The content column keeps a margin either side at any width** (`TranscriptCellView.margin`, AppKit's 20pt window margin), so a transcript narrowed by a divider or a window never runs text into its edges. It is the transcript's, not the split's — the split holds any view controller and knows nothing of columns. Not configurable: nothing has needed another value. A `.view` row is inset with the text around it.

## Streaming increments (`MarkdownMemo`)

- Every top-level child is keyed on the IR value it was built from (hence every `MarkdownIR` type is `Hashable`); unchanged children are reused wherever they land, because `BlockStack` assigns positions at stacking time. It's a **memo, not a diff** — no edit script, no block identity.
- Per frame: parse is paid in full (cmark has no incremental entry point, and it's cheap for streaming); shape + typeset only for changed children; **repaint is whole-row** — `BlockView.invalidate()` takes no rect. Before adding partial repaint, check in `make demo-kit` what a partial `setNeedsDisplay` on a growing layer looks like under `contentsGravity`'s default resize.
- `MarkdownGrowthTests` asserts settled blocks aren't re-typeset (via `CTLine` identity).

## Find

- **The search runs in the package** — a hit is a range in a row's flat index space, which exists only once the row is built (`**bold**` contains no `bold` in source). **The find bar is the host's**; only the count crosses (`transcriptView(_:didUpdateFindMatches:isComplete:)`), and `endFind()` reports too, so the host never tracks state twice.
- A hit is `(row identity, range)`. The flat index space doesn't depend on width, so a resize moves highlights with nothing recomputed.
- **A find reads a markdown row's `RowCache` entry on content alone** (`cachedMeasured(for:width:)` with `nil` width) — a stale-width entry searches as well as a fresh one. Capped user messages are the exception: they pass the width, and the find re-walks once a width change settles.
- **Walk in reading order** (not outward from the viewport): "4 of 51" must mean the fourth from the top. The **ordinal is computed on demand** from the selected hit's position, not counted — mutations during the walk would otherwise skew it.
- **The walk survives every `await`:** its cursor lives on the find and is renumbered by mutations; inserted rows behind it pull it back; slices renumbered in flight are retaken; `reloadRows` rows are re-searched on the spot (so streaming answers are found as they stream); `reloadData()` re-walks in place, keeping the current hit if it survived and never scrolling.
- **Landing:** the first hit **at or after the first visible row** is selected (wrapping to the first if all hits are above). A hit already on screen is selected without scrolling; otherwise the **hit** (not its row) is centred.
- **A tree built to search is used and dropped**, never filed in `RowCache` — one ⌘F would otherwise evict the rows on screen.
- **A capped user message is searched only as far as shown:** past the ellipsis every index has the same pen position (zero-width hit), so the truncated last line is excluded whole.
- **`.view` rows join through two seams:** `transcriptView(_:findMatchesOf:inRow:)` (answered from the model, like `heightOfRow`) and `TranscriptFindHighlighting` adopted by the row's view (where a range is drawn; draw its glyphs again) — `NSTextFinderClient`'s shape. The transcript draws everything; `BlockView` adopts the same protocol, so there's one presentation path. Hits in `.view` rows scroll to the row's nearest edge.

### How a find looks

- AppKit's own, measured from `NSTextView`: **light** dims content to 18% black and cuts matches out; **dark** doesn't dim and outlines matches with a 1 px white rule (drawn in light too, so a match on a dark card doesn't read as a hole). The current match is a yellow `findHighlightColor` bubble, slightly larger than its line, shadowed, with its characters redrawn **black** in both appearances. Corner radius 3.
- **`FindOverlayView` is a floating subview of the scroll view, horizontal axis only** (`addFloatingSubview(_:for:)`): AppKit carries it through vertical scrolls with the rows, so a lit match can't swim. It covers the visible rect plus half a screen each way and the scroll view clips it.
- **It pulls, nothing is pushed.** At layout it asks for on-screen rows and their matches; every reason to ask again reaches `needsLayout` (table `tile()` / `layout()` via `TranscriptTableView`, row views added/removed/rebound, find changed, clip moved). It sits after the clip in subview order so it lays out after the rows.
- The bubble pops once when the current match changes (not on scroll or re-layout); Reduce Motion turns it off.
