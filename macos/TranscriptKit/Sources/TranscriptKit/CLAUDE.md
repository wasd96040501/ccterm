# TranscriptKit internals

Invariants of the renderer target. Package-level API rules are in [../../CLAUDE.md](../../CLAUDE.md). Measurements and the reasoning behind a type live in its doc comment; this file lists the rules that span types.

## `TranscriptView` and its collaborators

- **`TranscriptView` is an `NSTableView`-shaped façade over an `ExactListView`** — the public API, the row answers (heights, views, binding `BlockView`s), the content width, and the mutations, which it hands to the list. The list owns row geometry, scroll anchoring, motion and re-measuring on a width change (`ExactList/SPEC.md`). Everything else is an internal, non-view collaborator that owns its state and cancels its own `Task`:
  - `ListAdapter` — the list's data source and delegate, forwarded to the transcript (a conformance on the public type would put the list's callbacks on the package's surface).
  - `FindSession` — a find: its state, the walk, `FindOverlayView`.
  - `SelectionTracker` — the text selection and every gesture that changes it (press-to-release loop, context-menu word, Copy).
  - `RemeasureScheduler` — warms `RowCache` off the main actor after a settled width change.
  - `RowCache` — measurements, shared by all of the above.
- **A collaborator talks back through narrow protocols** that `TranscriptView` conforms to — never by naming `TranscriptView`, so no internal type cycles back to it; only the public `dataSource` / `delegate` pair does (the `NSTableView` idiom). `RowDataSource` (`numberOfRows`, `contentWidth`, `row(at:)`, `measuredBlock(for:)`) is what `SelectionTracker`, `RemeasureScheduler` and `FindSession` read; `FindSessionDelegate` is what a find says back (`findDidUpdate`, `scrollFindMatchToVisible`); `ListAdapterOwner` is the list adapter's. The host's delegate is reached only through these.
- **Mutations enter only through `TranscriptView`**, which tells each collaborator what the mutation did (renumber by an insert or removal, keep by identity after a sweep, re-search reloaded rows) inside the same call.

## Rows, blocks, painting

- A `.markdown` / `.userMessage` row is parsed to `MarkdownIR`, built into blocks (`Layout/Blocks/`), stacked by `BlockStack` (which assigns origins and index bases at stacking time), and drawn by `BlockView` (root directory) onto `SurfaceLayer`s.
- **Directories depend one way: `Layout/` ← `Layout/Blocks/` ← `Markdown/` ← the root.** `Layout/` is the primitives every block and `BlockView` read — including `TextStyle` (the faces and colours shared by markdown and the user bubble) and `MeasuredContainerBlock` (a wrapper's text queries, translated by its content origin) — and holds no `NSView`; `BlockView` and `BlockViewDelegate` sit in the root; `Layout/Blocks/` is block geometry and knows no markdown; `Markdown/` lowers the IR into blocks and owns every markdown-only decision — which face a heading or a table header is set in (asked of `TextStyle`), which marker a list item gets and how wide the column is (`MarkdownListBuilder`; `ListRow` only draws it); the root is the view and its collaborators. A type needed by a lower directory moves down; `make arch SCOPE=TranscriptKit/Sources/TranscriptKit` must report no unit cycle.
- A row paints onto `SurfaceLayer` sublayers, not the view's own layer, because CoreAnimation composites `contents` **below** sublayers. Anything that must sit under the glyphs (the hover band) needs the glyphs on a surface above it.
- **`SurfaceLayer.draw(in:)` makes the view's effective appearance current itself.** A sublayer's draw is CoreAnimation's call and gets no appearance; without this a window with its own appearance draws rows in the system's. In-process `cacheDisplay` hides the bug (it sets appearance on the way) — only a window-server capture shows it.
- **Layer colours don't follow appearance.** `NSColor`s in a paint list resolve at draw time, so a repaint fixes them; a `CGColor` on a layer (the hover band) must be re-resolved in `viewDidChangeEffectiveAppearance`, and a hand-added layer's `contentsScale` maintained by hand.
- **The hover band is a `CAShapeLayer`, not a `PaintItem`** — the only thing on its own clock. A paint list has no notion of time; a layer fades on the render server with nothing redrawn. The press tint (8% → 16%) and its geometry (rects inflated 2, corner 4) are Telegram's; each is one constant in `BlockView`.
- `BlockView` reports clicks, hovers and its context menu to one weak `BlockViewDelegate` — the transcript, set when the view is created, never per bind; the view hands itself back and the transcript resolves its row.
- A link is anything `link(at:)` answers for — including a truncated user message's More — so band, pointing hand and press-is-a-click are `BlockView`'s one mechanism.

## Selection

- `TextSelection` belongs to the transcript — held by `SelectionTracker`, which owns it and every gesture that changes it — keyed by row identity and renumbered by every mutation (as the scroll anchor is). Each `BlockView` is handed only its part to draw, the way `NSTableView` sets `isSelected`.
- The first responder is the list's document view, as with `NSTextView`: it takes focus on press, answers `copy:`, drops the selection when focus leaves.
- **Keys:** the host is offered every command first (`transcriptView(_:doCommandBy:)`, through the list's `listView(_:doCommandBy:)`); of the rest the list answers only the scrolling commands and passes every other key to the next responder **as the event**. That is how a host types into its input while the transcript has focus; there is no API for it.
- A press is tracked to its release in **a tracking loop inside `mouseDown`** (`NSTextView`'s shape). The focus depends on pointer *and* content position, so it is re-read on drag, on a periodic autoscroll tick past an edge, and on scroll-wheel events. Don't dispatch drags to the pressed view: they stop when the hand stops, and the view may already be in the reuse pool.
- Idle cost is zero: binding a row reads its part from four integers; the loop walks visible rows only when the focus moved.
- A capped user message allows selecting into its hidden tail ("copy what I sent"); find does not (below).

## `RowCache`: heights for every row, trees for a few

- Entries are keyed by `TranscriptRow.ID` and trusted only while `(content, width)` matches; a stale entry re-measures rather than rendering wrong. Compare **whole `TranscriptRowContent` values**, not their text — the same string measures differently as `.markdown` vs `.userMessage`.
- **One recipe, on the cache:** `RowCache.Entry.init(measuring:width:reusing:)` is the only place a content case is built and measured — the cache, `PreparedRows.measuring(_:width:)` off-main, a find's walk and Copy all go through it. `TranscriptRowContent` stays a Foundation-only value the host builds; it names no block or memo.
- Every row keeps its height for its lifetime; typeset trees are held up to `RowCache.residentBudget`, least recently drawn evicted first. An evicted row is re-typeset when drawn, rebuilt off-main on a width change, and built-then-dropped by a find.
- `removeRows` / `reloadData` walk the data source to find orphaned entries (`sweepCache()`); acceptable because those operations move every row below anyway.
- An unexplained cost is ours until measured otherwise — check this package's own bookkeeping before blaming the list.

## Width changes

- **The list re-measures; the transcript warms the answers.** On any width change — a window, a divider drag, a split opening — the list measures the rows it has prepared inside the pass that changed the width and the rest on idle turns (ExactList W3, W5), asking `heightOfRow`, which the transcript answers from `RowCache`.
- **`RemeasureScheduler` makes those answers lookups.** Once the width settles — at `viewDidEndLiveResize` for a drag, never sixty times inside it; at once otherwise — it re-measures the stale entries off the main actor and files them in `RowCache`. It tells the list nothing: a row the list reaches first is measured on main, correctly, at one row's cost. Rules it depends on:
  - **Order outward from the viewport**, the order the list's own idle re-measure walks in, and **file as produced**.
  - **A sliding window of `activeProcessorCount` tasks**, not the whole set queued at once — thousands of runnable children starve the task collecting their results.
  - Entries crossing the actor boundary carry their recipe (`RowCache.Entry`); without it the first resize after a cold load rebuilds everything.
  - A newer width cancels a run, and a batch measured at a width that has moved on is dropped.
- **A width change never animates rows** — the list commits its re-measures without motion, and a change of the content-width bounds notes every row in a group of duration 0 (`ResizeRemeasureTests.testAWidthChangeOutsideADragDoesNotAnimateTheRows`).
- **The content column keeps a margin either side at any width** (`TranscriptCellView.margin`, AppKit's 20pt window margin), so a transcript narrowed by a divider or a window never runs text into its edges. It is the transcript's, not the split's — the split holds any view controller and knows nothing of columns. Not configurable: nothing has needed another value. A `.view` row is inset with the text around it.

## Streaming increments (`MarkdownMemo`)

- Every top-level child is keyed on the IR value it was built from (hence every `MarkdownIR` type is `Hashable`); unchanged children are reused wherever they land, because `BlockStack` assigns positions at stacking time. It's a **memo, not a diff** — no edit script, no block identity.
- Per frame: parse is paid in full (cmark has no incremental entry point, and it's cheap for streaming); shape + typeset only for changed children; **repaint is whole-row** — `BlockView.invalidate()` takes no rect. Before adding partial repaint, check in `make demo-kit` what a partial `setNeedsDisplay` on a growing layer looks like under `contentsGravity`'s default resize.
- `MarkdownGrowthTests` asserts settled blocks aren't re-typeset (via `CTLine` identity).

## Find

- **`FindSession` owns a find** — its state, the walk's `Task` (cancelled by a newer find or a refresh) and `FindOverlayView`; `TranscriptView` forwards its public find API there and tells it what each mutation did.
- **The search runs in the package** — a hit is a range in a row's flat index space, which exists only once the row is built (`**bold**` contains no `bold` in source). **The find bar is the host's**; only the count crosses (`transcriptView(_:didUpdateFindMatches:isComplete:)`), and `endFind()` reports too, so the host never tracks state twice.
- A hit is `(row identity, range)`. The flat index space doesn't depend on width, so a resize moves highlights with nothing recomputed.
- **A find reads a markdown row's `RowCache` entry on content alone** (`cachedMeasured(for:width:)` with `nil` width) — a stale-width entry searches as well as a fresh one. Capped user messages are the exception: they pass the width, and the find re-walks once a width change settles.
- **Walk in reading order** (not outward from the viewport): "4 of 51" must mean the fourth from the top. The **ordinal is computed on demand** from the selected hit's position, not counted — mutations during the walk would otherwise skew it.
- **The walk survives every `await`:** its cursor lives on the find and is renumbered by mutations; inserted rows behind it pull it back; slices renumbered in flight are retaken; `reloadRows` rows are re-searched on the spot (so streaming answers are found as they stream); `reloadData()` re-walks in place, keeping the current hit if it survived and never scrolling.
- **Landing:** the first hit **at or after the first visible row** is selected (wrapping to the first if all hits are above). A hit already on screen is selected without scrolling; otherwise the **hit** (not its row) is centred.
- **A tree built to search is used and dropped**, never filed in `RowCache` — one ⌘F would otherwise evict the rows on screen.
- **A capped user message is searched only as far as shown:** past the ellipsis every index has the same pen position (zero-width hit), so the truncated last line is excluded whole.
- **`.view` rows are not searched.** The walk still yields an element for one, filed with no matches and without measuring, so it never stops at a `.view` row; a host's view is neither searched nor highlighted. The find draws only against `BlockView`.

### How a find looks

- AppKit's own, measured from `NSTextView`: **light** dims content to 18% black and cuts matches out; **dark** doesn't dim and outlines matches with a 1 px white rule (drawn in light too, so a match on a dark card doesn't read as a hole). The current match is a yellow `findHighlightColor` bubble, slightly larger than its line, shadowed, with its characters redrawn **black** in both appearances. Corner radius 3.
- **`FindOverlayView` is a floating subview of the list, horizontal axis only** (`addFloatingSubview(_:for:)`): AppKit carries it through vertical scrolls with the rows, so a lit match can't swim. It covers the visible rect plus half a screen each way and the scroll view clips it.
- **It pulls, nothing is pushed.** At layout it asks for on-screen rows and their matches; every reason to ask again reaches `needsLayout` (`setNeedsFindLayout()`: row views mounted, removed or rebound, the find changed, the clip moved). It sits after the clip in subview order so it lays out after the rows.
- The bubble pops once when the current match changes (not on scroll or re-layout); Reduce Motion turns it off.
