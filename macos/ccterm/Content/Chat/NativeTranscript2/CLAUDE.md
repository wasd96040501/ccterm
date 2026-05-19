# NativeTranscript2

Self-drawn `NSTableView`-backed chat transcript. Each row is a `Block`; layout is a pure function of `(block, width, state)`, computed once per `(id, width)` and memoized in `Coordinator.layoutCache`.

> **Load-bearing performance contract.** Section 2 below codifies the techniques that keep the transcript at 60fps under 10k+ blocks. Each item lists what it costs to break it. **Any change that weakens or removes one of these items requires explicit user confirmation before implementation** — do not silently "simplify", refactor away, or replace with a SwiftUI/AppKit equivalent. If a change appears to need one of these relaxed, stop and ask.

## 1. Architecture

```
SwiftUI: NativeTranscript2View (NSViewRepresentable)
   │
   ├─ makeCoordinator → Transcript2Coordinator (NSTableViewDataSource/Delegate)
   │
   └─ makeNSView →
      Transcript2ScrollView (NSScrollView, .never, responsive)
         └─ Transcript2ClipView (NSClipView, .never)
            └─ Transcript2TableView (NSTableView, negative-width clamp)
               └─ BlockCellView (NSView, override draw(_:), .onSetNeedsDisplay)
```

`Transcript2Coordinator.blocks: [Block]` is the single source of truth — no `rows` mirror, no parallel diff structure. Mutation enters via `Controller.Change` (`.insert(after:blocks:)` / `.remove(ids:)` / `.update(id:kind:)`) and dispatches to `apply` (sync, lazy layout) or `applyInBackground` (off-main precompute then a single main hop).

## 2. Performance contract

Every item below is load-bearing for either scroll FPS, layout-pass cost, or memory churn. Cited file:line is authoritative; the description summarizes. **Changing any of these requires user confirmation.**

### 2.1 Why `NSTableView`, not `List` / `LazyVStack`

`NSTableView` calls `heightOfRow(row:)` synchronously. The coordinator answers from `layoutCache` ([Transcript2Coordinator.swift:934](Transcript2Coordinator.swift:934)) or computes synchronously on miss ([:557](Transcript2Coordinator.swift:557)); no estimated heights, no async height resolution. SwiftUI `List` / `LazyVStack` cannot pre-compute heights synchronously without either blocking (defeats laziness) or estimating (visible jumps on scroll-in). **Cost of replacing**: either freeze on cold load while heights resolve, or jitter on every scroll as estimates resolve to real heights.

### 2.2 Cell layer policy: `wantsLayer + .onSetNeedsDisplay`

`BlockCellView` ([BlockCellView.swift:199-200](AppKit/BlockCellView.swift:199)) caches its CGContext-drawn bitmap in a CALayer. During scroll the GPU composites the cached bitmap with zero `draw(_:)` calls; `draw(_:)` only re-runs after explicit `needsDisplay = true`. **Cost of switching to `.never`**: redraw every visible cell every frame during scroll (thousands of glyphs typeset per frame; UI freezes on 200+ row transcripts). **Cost of switching to `.onDemand`**: redraws on every structural change including hover.

### 2.3 ScrollView / ClipView layer policy `.never` + responsive scrolling

`Transcript2ScrollView.isCompatibleWithResponsiveScrolling = true` ([:11](AppKit/Transcript2ScrollView.swift:11)) plus `.never` on both the scroll view ([:79-80](AppKit/Transcript2ScrollView.swift:79)) and clip view ([Transcript2ScrollView.swift:76-82](AppKit/Transcript2ScrollView.swift:76)). These views own no pixels — only composite children. **Cost of removing `isCompatibleWithResponsiveScrolling`**: AppKit falls back to synchronous `drawRect` during scroll, blocking the event loop per frame. **Cost of dropping `.never`**: a redundant `drawRect` pass per scroll tick on a view with nothing to draw.

### 2.4 Layout cache: `[UUID: CachedLayout]`, no LRU

`layoutCache: [UUID: CachedLayout { width, layout }]` ([Transcript2Coordinator.swift:163-168](Transcript2Coordinator.swift:163)) is keyed by block id; the width lives inside the entry. Cache evicts only on `.update` / `.remove` (point invalidation via `removeCachedLayout(for:)` [:547](Transcript2Coordinator.swift:547)). On `.insert`, layouts populate lazily through `layout(for:width:)` ([:557](Transcript2Coordinator.swift:557)) or eagerly through `applyInBackground` / `refillLayoutCache`. **Cost of an LRU**: eviction logic + hit-rate variance for nothing — transcript size is bounded (≤ 10k blocks typical), the dict cost is dominated by id lookup.

### 2.5 Pure off-main layout via `nonisolated static makeLayout`

`Transcript2Coordinator.makeLayout(for:width:highlights:folds:statuses:)` ([:579-584](Transcript2Coordinator.swift:579)) is `nonisolated static`. It takes snapshot dicts (highlights / folds / statuses) captured on MainActor before the detached task starts; the off-main loop has no actor hops inside its per-block iteration. **Cost of making it `MainActor`**: every detached layout pass becomes a stream of main-actor hops, serializing with UI work and destroying the parallelism that backs `applyInBackground` / `refillLayoutCache`.

### 2.6 `applyInBackground` (fire-and-forget) for large prepends

For loadInitial Phase 2 and other large structural changes, `applyInBackground` ([:292-344](Transcript2Coordinator.swift:292)) computes layouts on a detached `userInitiated` Task, then a single main hop installs them and runs the structural change inside `withScrollAdjustment`. **Untracked, non-cancellable on purpose** — row-mutation is dataSource critical-path work; `Change.insert` resolves anchors by id at apply time, so landing is robust against any `apply`s in between. **Cost of making it sync**: 100+ ms freeze on every cold-load Phase 2 prepend.

### 2.7 `refillLayoutCache` post-resize prefetch + `mutationCounter` guard

After `viewDidEndLiveResize`, `refillLayoutCache` ([:866](Transcript2Coordinator.swift:866)) prefetches layouts for off-screen rows on a detached task, then under `.saveVisible(.visualTop)` installs them and runs `noteHeightOfRows`. `mutationCounter` ([:253](Transcript2Coordinator.swift:253), [:913](Transcript2Coordinator.swift:913)) drops the entire onMain block if any `apply` ran during the task — running `saveVisible` against AppKit's stale (deferred-re-query) heights would jitter the anchor row. **Cost of dropping the counter**: visible anchor jumps when an `apply` interleaves with a resize-prefetch. **Cost of dropping the prefetch**: off-screen rows lazy-layout one-at-a-time as user scrolls in, producing jank.

### 2.8 Live-resize bounds work to visible rows only

`tableFrameDidChange` ([:796](Transcript2Coordinator.swift:796)) checks `inLiveResize`; during live resize it only invalidates rows in `tableView.visibleRect` ([:819-822](Transcript2Coordinator.swift:819)). Off-screen layouts stay stale until `refillLayoutCache` runs. **Cost of invalidating all rows during live resize**: O(N) layout passes per frame against rows the user can't see — drag-resize becomes unresponsive on long transcripts.

### 2.9 Negative-width clamp on `setFrameSize`

`Transcript2TableView.setFrameSize` clamps width and height to ≥ 0 ([:34-39](AppKit/Transcript2TableView.swift:34)). AppKit briefly sends negative widths during scroller layout. **Cost of dropping**: "Invalid view geometry" warnings and undefined frame state during the scroller-layout window.

### 2.10 `invalidate(rows:)` suppresses implicit animations during reload

`invalidate(rows:)` ([:848-862](Transcript2Coordinator.swift:848)) wraps `reloadData(forRowIndexes:) + noteHeightOfRows` inside `NSAnimationContext.duration = 0 + allowsImplicitAnimation = false + CATransaction.setDisableActions(true)`. Without suppression, `noteHeightOfRows` animates row reposition while cell redraw is synchronous — during fast resize, cells paint at new height while the row below is mid-animation at the old y; visually rows overlap. **Cost of dropping suppression**: ghosting during fast window resize.

### 2.11 Granular `insertRows` / `removeRows` / `reloadData(forRowIndexes:)`; never `reloadData()`

All structural changes route through `applyStructuralChange` ([:348-410](Transcript2Coordinator.swift:348)) wrapped in `beginUpdates` / `endUpdates` ([:257-261](Transcript2Coordinator.swift:257)). `reloadData()` (no args) is banned — it would dump `layoutCache` semantics by re-running `viewFor` for every row, re-typesetting every paragraph at scroll cost. **Cost of one `reloadData()`**: O(N) typeset passes + full cell-reuse churn.

### 2.12 Highlight back-fill skips `noteHeightOfRows`

`handleHighlightDidFill` ([:418-425](Transcript2Coordinator.swift:418)) calls only `removeCachedLayout(for:) + reloadData(forRowIndexes:)`. Tokens change color, never glyph positions or line breaks. **Cost of adding `noteHeightOfRows`**: AppKit re-queries `heightOfRow` for the changed row and every following row (O(N) layout passes per fill).

### 2.13b Search highlights bypass `Change.update`

`Transcript2SearchCoordinator` keeps hits in a sparse `[UUID: [Int]]`-indexed
dict (sibling to `selection`). On scan / nav, only the affected cells are
asked to repaint via `markCellSearchDirty(blockId:)`, which sets
`BlockCellView.searchHighlights` and triggers `needsDisplay = true`. There
is no `Change.update`, no `noteHeightOfRows`, no `reloadData(forRowIndexes:)` —
search overlay only changes paint, never glyph metrics or row height. **Cost
of routing through `Change.update`**: every keystroke would drop selection,
re-schedule syntax tokens, and force `noteHeightOfRows` over every changed
row — search-as-you-type turns into a frame-budget killer.

### 2.13 Status updates bypass `Change.update`

`Coordinator.setStatus(id:)` writes `statusStates[id]`, evicts the host's cached layout, and runs a single-row `reloadData(forRowIndexes:)`. It does NOT route through `Change.update`. **Cost of routing through `Change.update`**: rebuild of `Block.Kind`, drop of selection, drop of highlight tokens, and an unnecessary `noteHeightOfRows` (status changes color, not height).

### 2.14 `cacheLayouts` anti-poison check

`cacheLayouts(_:width:)` ([:540-545](Transcript2Coordinator.swift:540)) skips writes when the cache already has a fresh entry at the same width. An inflight background task that completes after a sync `apply` evicted + lazy-refilled the entry would otherwise overwrite the authoritative fresh layout with its older snapshot. **Cost of dropping the check**: cache poisoning under interleaved `apply` + `applyInBackground` / `refillLayoutCache` traffic.

### 2.15 Generation guard in `Transcript2HighlightStorage`

`schedule` / `drop` bump `inflightGen[blockId]`; a job compares generations on completion and discards on drift. **Cost of dropping**: an `.update` that replaces `oldCode` with `newCode` lets the in-flight job for the old version write back, painting stale tokens onto current content.

### 2.16 Shimmer overlay: CALayer + CTLine + subpixel `xOffset` + image cache

[BlockCellView+SubviewPlan.swift:193-405](AppKit/BlockCellView+SubviewPlan.swift:193) and the `ShimmerLayerSet` class ([:585-710](AppKit/BlockCellView+SubviewPlan.swift:585)). Three load-bearing techniques:

- The overlay glyph bitmap is rendered with a sub-pixel `xOffset` ([:267](AppKit/BlockCellView+SubviewPlan.swift:267), [:404](AppKit/BlockCellView+SubviewPlan.swift:404)) so overlay glyphs and cell-bitmap glyphs share the same sub-pixel position. **Cost of dropping**: visible glyph smear / "double image" as the stripe sweeps.
- The rendered bitmap is keyed by `imageKey(title, font, appearance, scale, xOffset, bottomPadding, size)` ([:635](AppKit/BlockCellView+SubviewPlan.swift:635)) and skipped on equality. **Cost of dropping**: 15–50 µs `CTLine` raster on every reconcile (hover transition, sibling row change).
- `viewDidChangeBackingProperties` propagates `contentsScale` and invalidates cached bitmaps. **Cost of dropping**: stale rasterizations linger when dragging between Retina/non-Retina displays.

### 2.17 `CenteredRowView` row-reuse key

`CenteredRowView` is a no-op `NSTableRowView` subclass paired with the identifier `"BlockRow"` in `rowViewForRow` ([:942-953](Transcript2Coordinator.swift:942)). The row view does no layout — centering happens in `BlockCellView.layoutOrigin`. Its purpose is to give NSTableView a stable reuse key for row views. **Cost of removing**: NSTableView allocates fresh row views per scroll tick.

### 2.18 Lazy `heightOfRow` + identity-stable `Block.id`

`Block.id: UUID` is caller-supplied, never derived from content hash. The cache, diff, selection, highlight scope, fold state, and status state are all keyed by it. **Cost of content-hashed ids**: identical consecutive messages collapse to one row; selection and highlight scope drift across content-equivalent updates; `.update` events flood the cache and selection paths spuriously.

## 3. Invariants

### 3.1 Data and state

- **Single source of truth** is `Transcript2Coordinator.blocks: [Block]`. No `rows` mirror, no parallel diff structure. The only sync invariant is layout↔data, mediated by `layoutCache: [UUID: CachedLayout]`.
- **Stable ids drive identity.** `Block.id: UUID` is caller-supplied. Never derive ids from content hashes — identical consecutive messages would collide and selection/highlight scope would drift across content-equivalent updates.
- **Layout is a pure function**: `Self.makeLayout(for:width:highlights:folds:statuses:)` is `nonisolated static`. Cache entries are derived, not authoritative — `removeCachedLayout(for:)` is always safe; `heightOfRow` lazy-recomputes on miss.
- **Two mutation entry points only.** `apply(_:scroll:)` (sync, lazy layout, incremental updates) and `applyInBackground(_:scroll:)` (off-main precompute, single main hop, large prepends). Both dispatch to `applyStructuralChange` per `Change` enum. No third channel; do not add a `pendingBlocks` side path.

### 3.2 Coordinator-held row state

Row state (fold flags, status, …) lives on `Coordinator` as **sparse dictionaries** (absent = default). It is NOT stored on `Block.Kind` associated values, for two reasons:

- State must survive `.update` events on content (a content tweak must not undo the user's expand preference).
- State must survive `RowLayout` rebuilds. Layout is a pure function of `(block, width, state)`; state is an *input*, not a stored field.

Layouts therefore stay stateless. Adding a new stateful behavior = a new sparse-dict field on the coordinator, threaded through `makeLayout` into the relevant `XxxLayout.make` parameter.

Current sparse dicts:

| Dict | Key | Default | Drives |
|---|---|---|---|
| `Coordinator.foldStates: [UUID: Bool]` | `Block.id` or `Child.id` | `false` (folded) | Collapsed↔expanded body shape. `userBubble` does not use this (it uses "hard truncate + sheet" instead). |
| `Coordinator.statusStates: [UUID: ToolStatus]` | `Block.id` (group) or `Child.id` (child) | `.completed` | Header color + shimmer overlay. |
| `search.hits: [Hit]` + derived `hitsByBlock: [UUID: [Int]]` | `Block.id` | absent (no hits) | Yellow / orange-yellow search overlays. State is **paint-only** — no metric change. See §2.13b. |

Keyspace is shared: `foldStates[childId]` and `statusStates[childId]` both work — top-level `Block.id` keys the group, `Child.id` keys a child.

Mutation entry points:
- `Coordinator.toggleFold(id:)` — flips the flag, then inside an animation group calls `noteHeightOfRows` + `reloadData(forRowIndexes:)`.
- `Transcript2Controller.setToolStatus(id:status:)` → `Coordinator.setStatus(id:)` → `removeCachedLayout(for: hostBlockId)` + a single-row `reloadData(forRowIndexes:)`. Skips `noteHeightOfRows` (status changes color only, never height) and bypasses `Change.update` (which would drop highlight + drop selection and force the caller to rebuild `Block.Kind`).
- `Transcript2Controller.runSearch(_:)` / `nextSearchHit()` / `previousSearchHit()` / `endSearch()` → `Transcript2SearchCoordinator`. Mutation path is paint-only: writes the per-block hit set, asks `Coordinator.markCellSearchDirty(blockId:)` to push the new specs to visible cells. No `reloadData`, no `noteHeightOfRows`, no `Change.update`. Nav auto-runs `Coordinator.expandForSearchHit(blockId:)` + `scrollBlockIntoView(blockId:)` so a hit in a folded child becomes visible.

### 3.3 Tool group status visuals

Status is folded into `ToolGroupLayout.Header.status` at `make` time. `drawHeader` and `subviewPlan` resolve color and shimmer through three helpers: `titleColor(for:hovered:)`, `chevronTint(for:hovered:)`, `wantsShimmer(for:)`. New status visual rules go in these helpers only.

**Color rule:** `.running` uses identical title and chevron colors to `.completed`. The running affordance is the shimmer overlay (`SubviewPlan.Shimmer`), never a brighter color tier — a color-tier change produces a brightness pop on running↔completed transitions.

**Shimmer is an additive overlay, not a mask.** A mask-based version dims AA glyph edges. The implementation:

- `drawHeader` always paints the base title in the secondary color into the cell bitmap.
- The overlay is a `CALayer` carrying a `labelColor` text bitmap with an `[α=0,1,0]` mask gradient — it adds `labelColor` pixels only where the stripe falls. Base text stays fully opaque and sharp.
- The overlay layer frame is pixel-aligned in the cell reconciler using the host's backing scale.
- The bitmap is rendered via `CTLine` + `xOffset` to inject subpixel offset so overlay glyphs and cell-bitmap glyphs share the same subpixel position (no "double image" smear as the stripe sweeps).
- On hover, overlay opacity is forced to zero (base already paints in `labelColor`).
- `viewDidChangeBackingProperties` propagates `contentsScale` to every sublayer and invalidates cached glyph bitmaps, so dragging across displays leaves no stale rasterizations.

**SubviewPlan payload:** `SubviewPlan.Chevron` carries a resolved `strokeColor` + `alpha` (status + hover folded in). `SubviewPlan.Shimmer` carries `textRect` + title + font + hovered`; highlight color, sweep speed, gradient locations, and pixel alignment live inside the cell reconciler. The cell stays state-enum-free.

### 3.4 Structural change dispatch

The `Change` enum (emitted by `Transcript2Controller`) is the only shape `applyStructuralChange` ([Transcript2Coordinator.swift:348-410](Transcript2Coordinator.swift:348)) consumes. There is no diff algorithm in the coordinator — the controller declares the operation, the coordinator runs it.

| Case | NSTableView call | Cache effect |
|---|---|---|
| `.insert(after, blocks)` | `insertRows(at:withAnimation:[.effectFade])` | None (lazy lookup on next `viewFor` / `heightOfRow`) |
| `.remove(ids)` | `removeRows(at:withAnimation:[.effectFade])` | `removeCachedLayout(for: id)` + `selection.dropEntry` + `highlightStorage.drop` + remove from `foldStates` / `statusStates` |
| `.update(id, kind)` | `reloadData(forRowIndexes:) + noteHeightOfRows(withIndexesChanged:)` | `removeCachedLayout` + `highlightStorage.drop` + `highlightStorage.schedule(new)` + `selection.dropEntry` |

All mutations run inside `beginUpdates` / `endUpdates` ([Transcript2Coordinator.swift:257-261](Transcript2Coordinator.swift:257)). Never `reloadData()` (see §2.11).

## 4. Layout boundaries

`XxxLayout` is an immutable value capturing the width-dependent geometry needed to (a) report a row's height to `NSTableView` and (b) draw the block's main body. Derived from a particular block payload, the current width, and (optionally) coordinator-held state.

Code belongs in a `Layout` only if all three are true:

1. Pure function of width? (Deterministic input → output, no hover/selection/animation awareness.)
2. Row-body content? (Would changing it change row height? If yes → Layout. If no → cell decoration.)
3. Must be computed before `draw`? (`heightOfRow` returns synchronously — no ad-hoc layout at draw time.)

**State is an input to the layout function, not a stored field**: `make(input, width, state) -> Layout`.

### Layout vs. CellView

| Layout owns | CellView owns |
|---|---|
| Glyph positions / image rects / table-cell content | Row padding, corner radius, shadows, loading placeholders |
| Anything that **changes row height** | Anything purely decorative (does not affect height) |
| A description of subviews / sublayers the cell needs to host (`SubviewPlan`) | Reconciling subviews / sublayers against the current plan |

### Dispatching across layouts

`enum RowLayout` wraps each concrete `XxxLayout` and exposes a uniform `totalHeight` / `measuredWidth` / `draw(in:origin:)`. The cell never inspects the enum — it just calls `layout.draw`.

Adding a new layout kind = one new `RowLayout` case + one line in each of the three switches.

### AppKit decorations on self-drawn cells

`BlockCellView` mostly uses `override draw(_:)`, but not as a single bitmap. Some animations and interactions can't be expressed in `CGContext` and need real AppKit decorations:

| Decoration | Type | Why not self-draw |
|---|---|---|
| Chevron rotation | `CAShapeLayer` sublayer | `transform.rotation.z` + `CABasicAnimation` is one line; self-drawing would redraw every frame. |
| Slidable inline body | `NSView` subview (layer-backed) | Multiple body slabs on one row need to slide past each other during fold transitions. Only `view.animator().frame` expresses that; a single bitmap can only crossfade. |

**Layouts declare decorations via `subviewPlan`.** `RowLayout` exposes `subviewPlan(origin:hoveredAction:selection:flashingCopyIds:) -> SubviewPlan`. Layouts that need none return an empty plan; only the ones that need decorations (today: `toolGroup`) return non-empty. `SubviewPlan` is a **struct + closures** — same shape as `SelectionAdapter`, never a protocol. The cell doesn't know which layout produced the plan; it runs the generic reconciler. `flashingCopyIds` carries the cell's per-button checkmark-feedback state (keyed by `CopyChrome.id`) into each entry's `draw` closure so the chrome on bash sub-cards / diff cards stays in sync without a separate dispatch path.

**Never use a protocol to mark "which layout needs decorations".** Enum dispatch gives exhaustiveness checking; protocols let you forget an implementation on some case.

**Extending `SubviewPlan`:**
- New decoration category (today: chevron / entry / shimmer) → add a field on `SubviewPlan` + a reconcile arm in `BlockCellView+SubviewPlan.swift`.
- Letting another layout emit decorations → add an arm in `RowLayout.subviewPlan` and implement `subviewPlan(...)` in that layout's own file.

## 5. Adding a new block kind

Add a `case` to `enum Block.Kind`. Then:

1. Decide whether you need a new `Layout` type (re-run the three checks in §4).
2. Add a `Transcript2Coordinator.makeLayout` arm ([Transcript2Coordinator.swift:579](Transcript2Coordinator.swift:579)): dispatch on `block.kind` to the matching `XxxLayout.make`, wrap in the matching `RowLayout` case. The function is `nonisolated static` (off-main precompute requirement, §2.5) — any new arm must remain actor-free; capture per-block snapshot data from the supplied `highlights` / `folds` / `statuses` dicts.
3. If it's a new layout type: add `Layout/XxxLayout.swift` and a case to the `RowLayout` enum.

Dispatch per kind inside `makeLayout`. Do not add an umbrella `BlockStyle.attributed(for: Block)` helper — block kinds don't share an attributed-string shape and non-text blocks would break it.

### Implemented examples

#### `.heading` / `.paragraph` → `TextLayout`

`case .heading(level: Int, inlines: [InlineNode])` / `case .paragraph(inlines: [InlineNode])` use `BlockStyle.headingAttributed(level:inlines:)` / `paragraphAttributed(inlines:)`, which fold inline IR into an `NSAttributedString`. There is no `String` overload — callers without a parser wrap manually as `[.text(s)]`.

`InlineNode` is the recursive inline IR (text / strong / emphasis / code / link / lineBreak), produced by the upstream Markdown parser. The block layer holds it but does not parse it.

#### `.image` → `ImageLayout`

`case .image(NSImage)` → aspect-fit with a `maxHeight` fallback.

#### `.toolGroup` → `ToolGroupLayout`

One row hosts the entire tool group.

**Group header** (24pt) sits at the top of the row: title + chevron on the right. Title is 12pt medium `secondaryLabel`; chevron is 8pt; title↔chevron gap is 6pt. No icon. No inset (layout-local `x=0`; the row's horizontal padding comes from `layoutOrigin.x` on the cell).

**Child headers** use the exact same constants (`BlockStyle.toolHeader*`). Spacing between consecutive child headers, and between the group header and the first child header, is `toolHeaderChildSpacing = 4pt`.

**Chevron path** — two self-drawn line segments forming `>` (`lineWidth = 1.4`, round caps/joins). Never substitute an SF Symbol. Idle alpha = 0.35, hover alpha = 0.85. Folded → `rotation = 0` (pointing right); expanded → `rotation = π/2` (pointing down).

**Chevron visual-center compensation** — `visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)`. The chevron's `centre.y` adds this offset on top of `midY` so it aligns with the title's x-height midline (without it the chevron drifts visually above the title).

**Hover highlight** — `BlockCellView` tracks hit via `NSTrackingArea` (`.mouseMoved` + `.mouseEnteredAndExited` + `.activeInKeyWindow` + `.inVisibleRect`) and passes the resolved `HitAction` to `RowLayout.draw(in:origin:hoveredAction:)`. `ToolGroupLayout.draw` matches `.toggleFold(id)` against each header's `foldId`; matching headers swap title to `.labelColor` and chevron alpha to the hover value. Other layouts ignore `hoveredAction`.

**Expanded body** — under an opened child header: a 4pt gap, then a `codeBlock`-style rounded rect (fill = `diffContainerBackground`, corner = `structuralCornerRadius`). `ToolGroupChildLayout` dispatches to the per-kind layout file.

**Fold-state routing** — the `UUID` in `HitAction.toggleFold(UUID)` can be either the group host's `Block.id` (group header) or a `Child.id` (child header). `Coordinator.toggleFold(id:)` must search both `blocks.firstIndex(where: { $0.id == id })` and `children.contains(where: { $0.id == id })` across every tool group to locate the host row. Searching only top-level blocks leaves child-header clicks dead.

**Three-state labels (group + child)** — `ToolGroupBlock` holds three titles (`activeTitle` / `expandedActiveTitle` / `completedTitle`). `group.resolvedTitle(status:isExpanded:)` is the single source of truth:

| Status | Folded | Expanded |
|---|---|---|
| `.running` | `activeTitle` (in-progress final child) | `expandedActiveTitle` (aggregate progressive form) |
| `.completed` / `.failed` / `.cancelled` | `completedTitle` (aggregate past form) | `completedTitle` |

Children mirror this: each payload exposes `label` (past form) and `activeLabel` (progressive form). `Child.headerLabel(for: ToolStatus)` chooses — `.running` → `activeLabel`, otherwise → `label`. The bridge (`MessageEntryBlockBuilder` + `ToolUseToChild`) populates **both** labels; the layout switches in place using `statusStates[id]`, never via `Change.update`. The source of the three titles is `GroupEntry (in `Session/MessageEntry.swift`).activeTitle` / `expandedActiveTitle` / `completedTitle` (corresponding to `activeCountPhrase` / `completedCountPhrase`). For a single-tool group, use `ToolUse.activeFragment` / `completedFragment` directly — do not route through `activeCountPhrase(1)`, which would blur "Reading foo.swift" into "Reading 1 file".

**Adding a new child kind:**

1. Create `Layout/ToolGroupChildren/<Kind>/<Kind>Child.swift` with the payload struct (must expose `id` / `label` / `activeLabel`; `id` drives fold state and highlight scope, `label` is the past form, `activeLabel` is the progressive form; `Child.headerLabel(for: ToolStatus)` selects). In `Block.swift`, add the enum case and one arm to each of the `id` / `label` / `activeLabel` / `hasExpandableBody` switches.
2. Create `Layout/ToolGroupChildren/<Kind>/<Kind>ChildLayout.swift` implementing `make / totalHeight / draw / drawBackplate`. For multi-sub-card bodies, reuse `TextCardSection.build / drawBackplates / draw` rather than reimplementing sub-card geometry.
3. Add the case to `ToolGroupChildLayout` plus four switch arms (`totalHeight`, `drawBackplate`, `draw`, `make`).
4. Header-only kinds (`.generic`, plus `.read` until its tool_result lands): `hasExpandableBody = false`, layout `totalHeight == 0`, empty `draw` and `drawBackplate`. `ToolGroupLayout` skips chevron drawing and skips registering the fold hit automatically.
5. If async highlighting is needed, add a case to `ToolGroupChildHighlight.requests(for:)` that returns a `Plan`.
6. If the body should be selectable (`selectionAdapter`):
   - Bodies built on `TextCardSection` (bash / grep / glob / webFetch / webSearch / askUserQuestion / agent) are zero-effort — `ToolGroupChildLayout.textCardSections` already exposes the section list, and `ToolGroupLayout.selectionAdapter.buildRegions` produces one `LayoutPosition.textCard(childIndex:sectionIndex:char:)` region per section. Extend `LayoutPosition` only if your new kind isn't built on `TextCardSection`: add a concrete case and route it through a `buildRegions` arm.
   - Selection granularity is section-local (drags that cross sections clamp to the start section). Cross-child drags clamp the same way. `fileEdit` is the lone exception: it uses `LayoutPosition.diff(childIndex:char:)` because `DiffLayout` strips its own gutter and sign columns and can't share `TextLayout`'s path.

**Implemented child kinds** (each in its own `Layout/ToolGroupChildren/<Kind>/` subdirectory):

| Kind | Body |
|---|---|
| `generic` | Header-only (no chevron) |
| `read` | New-file diff card (`DiffLayout` with `oldString == nil` — gutter line numbers, no `+/-` chrome). Header-only until the tool_result lands and carries text. |
| `fileEdit` | Diff card (`DiffLayout` + per-line highlight) |
| `bash` | Command / stdout / stderr — three monospaced sub-cards; stderr in red |
| `grep` | Filenames + optional content preview, two sub-cards |
| `glob` | Filenames + optional "… truncated" tail, single card |
| `webFetch` | Response body, single card (plain text) |
| `webSearch` | Results list (title semibold / url monospace / snippet) |
| `askUserQuestion` | Q&A list (semibold question + answer / "awaiting answer…") |
| `agent` | Progress card (`↳ ` prefix) + output card |

**No protocols.** Enum dispatch gives exhaustiveness checking; protocols let you forget an implementation in some file.

**Child header text uses the payload's `label`, not the raw file path.** `FileEditChild` carries both `label` (display, e.g. "Edit Sources/Greeter.swift", past form) and `filePath` (for language detection in highlighting). When a group is expanded, children always show their completed form; the running affordance is reflected on the group title.

**Async highlighting** — scope = `Transcript2HighlightScope.toolGroupChild(itemId: child.id)`. Each child decides the `HighlightValue` shape. `fileEdit` uses per-unique-line `.lineMap`; the key is the raw line content. Line metrics don't depend on tokens, so `onDidFill` is a `reloadData(forRowIndexes:)` only — no `noteHeightOfRows`.

**New-file mode (`oldString == nil`)** — `.add` lines render as `.context` (no `+` sign, no add background); gutter line numbers + token highlight are preserved. The output reads as a "line-numbered code view", not a "diff with everything added".

**Selection** — `fileEdit` and `read` (when expanded) use `LayoutPosition.diff(childIndex:char:)`; the other seven kinds (bash / grep / glob / webFetch / webSearch / askUserQuestion / agent) use `LayoutPosition.textCard(childIndex:sectionIndex:char:)` with per-card granularity. `generic` is header-only with nothing to select.

#### `.userBubble` → `UserBubbleLayout`

`case .userBubble(text: String)`. Right-aligned bubble; long text hard-truncates at `userBubbleCollapseThreshold` lines, the last line trims with `CTLineCreateTruncatedLine` + an ellipsis, and a `>` chevron sits inside the padding. Selection clamps to the prefix lines — the truncated tail is not selectable. **The layout is fully stateless** and has no fold flag. Chevron `mouseDown` → `Coordinator.requestUserBubbleSheet(id:)` → routes through the `onUserBubbleSheetRequested` closure to `Transcript2Controller.pendingUserBubbleSheet` (`@Observable`) → SwiftUI's `.sheet(item:)` shows the full content (`Text.textSelection(.enabled)` for copy).

This is the **only legal SwiftUI escape hatch** from the NSView loop: `.sheet(item:)` is a presentation primitive that must be owned by SwiftUI. In-cell rendering, hit testing, and selection stay entirely inside NSView.

## 6. File layout

```
NativeTranscript2/
├── Model/
│   └── Block.swift                  Block data + font/inset constants + bubble / chevron / code / diff geometry constants
├── Layout/
│   ├── TextLayout.swift             Core Text layout result (immutable + draw)
│   ├── ImageLayout.swift            Aspect-fit + draw (NSImage carries the bitmap)
│   ├── ListLayout.swift             Recursive list with self-drawn markers / checkboxes
│   ├── TableLayout.swift            CSS-like min/max column allocation + self-drawn grid
│   ├── UserBubbleLayout.swift       Right-aligned bubble + chevron + fade mask + selection clamp
│   ├── CodeBlockLayout.swift        Floating top-right chrome (lang badge + CopyChrome) + embedded TextLayout body + async token coloring
│   ├── CopyChrome.swift             Reusable copy-button primitive (id + hitRect + center + text + draw) — codeblock / bash / diff all emit one of these
│   ├── BlockquoteLayout.swift       Left bar + embedded TextLayout
│   ├── ThematicBreakLayout.swift    Single hairline
│   ├── ToolGroupLayout.swift        Tool group row (group header + child headers + expanded body); dispatches into ToolGroupChildLayout
│   ├── ToolGroupChildren/           Per-kind tool-group child layouts (payload + layout colocated)
│   │   ├── ToolGroupChildLayout.swift     Enum dispatch for totalHeight / draw / drawBackplate + `make` factory
│   │   ├── ToolGroupChildHighlight.swift  Per-kind highlight requests + finalize
│   │   ├── TextCardSection.swift          Shared geometry + draw helpers for multi-card sub-bodies
│   │   ├── FileEdit/                      Diff body (header + body)
│   │   │   ├── FileEditChild.swift            Payload struct
│   │   │   ├── FileEditChildLayout.swift      Thin wrapper that calls DiffLayout
│   │   │   ├── FileEditChildHighlight.swift   Per-unique-line highlight requests + finalize
│   │   │   ├── DiffBlock.swift                Diff payload (old/new + derived hunks)
│   │   │   └── DiffLayout.swift               Hunks body (`codeBlock`-style rounded rect with per-line gutter / sign / content)
│   │   ├── Read/                          New-file diff body: ReadChild (+ content) + ReadChildLayout wraps DiffLayout, ReadChildHighlight schedules per-unique-line tokens
│   │   ├── Generic/                       Header-only fallback: GenericChild + GenericChildLayout (totalHeight = 0)
│   │   ├── Bash/                          Command + stdout + stderr, three sub-cards
│   │   ├── Grep/                          Filenames + content preview, two sub-cards
│   │   ├── Glob/                          Filenames + optional "… truncated" tail, single card
│   │   ├── WebFetch/                      Response body, single card (plain text)
│   │   ├── WebSearch/                     Results list, single card (title / url / snippet)
│   │   ├── AskUserQuestion/               Q&A list, single card
│   │   └── Agent/                         Progress + output, two sub-cards
│   ├── SelectionAdapter.swift       Selection-facing API (per-layout, struct + closures)
│   ├── SubviewPlan.swift            Chevron + entry-subview decoration plan (per-layout, same shape as SelectionAdapter)
│   └── RowLayout.swift              Enum dispatch (text / image / list / table / userBubble / codeBlock / blockquote / thematicBreak / toolGroup)
├── AppKit/
│   ├── Transcript2ScrollView.swift  NSScrollView + NSClipView subclasses
│   ├── Transcript2TableView.swift   NSTableView subclass (negative-width clamp)
│   ├── CenteredRowView.swift        Row-view placeholder subclass (no-op body); exists so NSTableView.makeView has a stable row-reuse key
│   ├── BlockCellView.swift          Self-drawn cell: layoutOrigin.x = cellOriginX + blockHorizontalPadding for centering + layout.draw + link/chevron hit testing + selection + hover tracking
│   └── BlockCellView+SubviewPlan.swift  Reconciles the chevron sublayer and entry subview against the layout's SubviewPlan; ToolGroupEntryView also lives here
├── Transcript2Coordinator.swift          DataSource/Delegate + diff + per-kind dispatch + chevron sheet request routing
├── Transcript2Controller.swift           Imperative command channel (apply / loadInitial / search)
├── Transcript2SelectionCoordinator.swift Cross-row selection algorithm (reads layout.selectionAdapter)
├── Transcript2SearchCoordinator.swift    In-transcript ⌘F scan + nav + per-cell highlight push
└── NativeTranscript2View.swift      SwiftUI bridge (updateNSView is a no-op) + Preview
```

Dependencies only flow downward: `NativeTranscript2View → Coordinator → AppKit/ → Layout/ → Model/`.

## 6.5 Search

`Transcript2SearchCoordinator` (next to `Transcript2SelectionCoordinator`)
owns the in-transcript search state. Same pattern: state lives here,
per-cell paint is derived, affected cells are reseated via
`Coordinator.markCellSearchDirty(blockId:)`. Sibling to selection — the
two compose at draw time, search highlights composite over the selection
band.

The host UI is SwiftUI's built-in `.searchable` modifier attached to
`ChatHistoryView`, with `placement: .toolbar`. The native `NSSearchField`
lands in the window toolbar's trailing slot; there are no prev / counter
/ next chrome items — the user navigates with `Return` (next match, via
`.onSubmit(of: .search)`) and `Shift+Return` (previous, via
`.onKeyPress(keys: [.return], phases: .down)` inspecting
`KeyPress.modifiers`). Always visible; no open / close cycle. ⌘F (via
`AppCommands` → `TranscriptSearchBus.requestFocus()`) flips the
`.searchFocused`-bound `@FocusState` and hands keyboard focus to the
field without changing visibility.

The transcript itself runs flush to the window's top edge while the
search field sits inside the toolbar band. That requires three modifiers
acting together: `.windowStyle(.hiddenTitleBar)` (enables
`fullSizeContentView` so the content extends under the chrome),
`.windowToolbarStyle(.unifiedCompact)` (collapses the toolbar into the
title-bar band rather than stacking under it — the default `.expanded`
style adds ~52pt), and `.toolbarBackground(.hidden, for: .windowToolbar)`
(keeps the toolbar material from painting a band over the transcript).

### Data flow

1. `Transcript2Controller.runSearch("apple")` →
   `coordinator.search.runQuery("apple")`.
2. Scanner walks `coordinator.blockIds`, asks each block's
   `selectionAdapter.searchableRegions()` for plain-text bands, runs a
   case-insensitive literal `NSString.range(of:options:)` per region, and
   converts each match into a `SelectionRange` via the region's
   `position` closure.
3. Hits land in `Transcript2SearchCoordinator.hits: [(blockId, range)]`,
   sorted by document order. Derived `hitsByBlock: [UUID: [Int]]` is
   the per-cell lookup.
4. `onStateChanged` fires; `Transcript2Controller` mirrors to its
   `@Observable` `searchState` so the SwiftUI search bar re-renders.

### Search-range == selection-range

Every searchable region is supplied by the same
`SelectionAdapter.searchableRegions` closure that the layout uses for
selection. Hit rects flow through the *same* `adapter.rects` the
selection band uses — so a yellow rect is guaranteed to land on the
same glyphs a selection drag across that range would highlight. Adding
a new selectable layout that supplies `searchableRegions` opts it into
search automatically — `Transcript2SearchCoordinator` has zero
kind-specific code.

### Rendering

`BlockCellView` carries `searchHighlights: [SearchHighlightSpec]?`. The
cell draws yellow / orange-yellow rects between the selection band and
the glyph pass, so search overlays composite *on top of* selection
(search is the active task; selection is dormant context). Colors are
`NSColor.systemYellow.withAlphaComponent(0.42)` (inactive hit) and
`NSColor.systemOrange.withAlphaComponent(0.78)` (current cursor),
attenuated when the window has resigned key.

### Coverage

`searchableRegions` is provided by the `.text` family of layouts —
`paragraph`, `heading`, `codeBlock`, `blockquote`, `userBubble` (visible
prefix only; the truncated tail isn't selectable, so it isn't searchable)
— and by `toolGroup` rows for **currently-expanded** children:
`fileEdit` diff bodies and any child built on `TextCardSection` (bash /
grep / glob / webFetch / webSearch / askUserQuestion / agent). Folded
children carry no body in the layout, so their text doesn't enter the
initial scan — same invariant as selection. `list` / `table` return
empty regions; their selection adapters exist but haven't been wired
into search yet — adding them is a `searchableRegions` implementation
per layout, no framework change.

### Folded-state navigation

`Coordinator.expandForSearchHit(blockId:position:)` runs before every
nav scroll. For `toolGroup` rows the hit's start position carries a
`.diff(childIndex:_)` or `.textCard(childIndex:_,_)`; the coordinator
opens the group host (if folded) and then the one specific child the
hit lives in. Sibling children are not disturbed. The flow that this
covers: user expanded a tool body, ran a search that landed hits in
it, then collapsed the group / that child — pressing next/prev re-opens
exactly the row needed to surface the highlight.

## 7. Async highlight back-fill

`Transcript2HighlightStorage` is a per-block async side-channel. Supported value shapes:

| Scope | Value | Used by |
|---|---|---|
| `.codeBlock` | `.tokens([SyntaxToken])` | Whole-block code highlighting |
| `.diff` | `.lineMap([content: tokens])` | Per-unique-line highlight in diffs; key is the raw line content |

**Back-fill flow** (same for every highlight-bearing kind):

1. `Coordinator.apply` calls `storage.schedule(block)` on `.insert` / `.update`.
2. `schedule` dispatches via `plan(for: block)`, which returns a `Plan { payload, writeback }`.
3. A single `engine.highlightBatch(payload)` crosses into JSCore; results are written back through `writeback`.
4. `onDidFill(blockId)` triggers `removeCachedLayout(for: id)` + `reloadData(forRowIndexes:)`.
5. The next `viewFor` call's `makeLayout` reads the storage snapshot and produces a colored layout.

**Generation guard** — both `schedule` and `drop` bump `inflightGen[blockId]`. When a job finishes it compares generations; on drift it discards the result. This prevents an old highlight from overwriting newer content (e.g. after `.update` replaces `oldCode` with `newCode`, the in-flight job from the old version must not write back).

**Layout invariant** — highlight back-fill only changes colors, not metrics. Under the same font and width, glyph positions don't shift based on token presence. `onDidFill` only does `reloadData(forRowIndexes:)`, never `noteHeightOfRows` (which would re-layout every following row for no visual reason).

**Adding a new highlight-bearing kind:**

1. Add a case to `Transcript2HighlightScope` (if `.tokens` / `.lineMap` aren't reusable, extend `HighlightValue` with a new shape).
2. Add a `Storage.plan(for:)` arm that returns the `payload` + `writeback` for the new kind.
3. Make `XxxLayout.make` accept the matching optional (e.g. `tokens: [SyntaxToken]?` or `lineMap: [String: [SyntaxToken]]?`).
4. Add an arm to `Coordinator.makeLayout` that pulls the value from the `highlights` snapshot, pattern-matches the token shape, and threads it through.

The framework itself does not change — storage and the reload pipeline are generic.

## 8. Verifying changes

| Touched | Verify with |
|---|---|
| `Coordinator` diff / pipeline | SwiftUI Preview (`NativeTranscript2View.swift` `#Preview`); inspect insert/remove animations |
| `BlockCellView.draw` | Preview; check layout + font |
| `TextLayout.make` | Preview |
| `Transcript2ScrollView` / `Transcript2TableView` | `make build` + launch; drag window width to verify reflow |
