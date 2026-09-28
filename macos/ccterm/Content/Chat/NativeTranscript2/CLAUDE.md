# NativeTranscript2

The production chat transcript: a self-drawn, `NSTableView`-backed list where each row is a `Block`. A row's layout is a pure function of `(block, width, state)`, computed once per `(id, width)` and memoized in `Transcript2Coordinator.layoutCache`. (`macos/TranscriptKit` is the next-generation replacement; the app does not use it yet.)

> **Load-bearing performance contract.** §2 lists the techniques that keep the transcript at 60fps with 10k+ blocks, each with what breaking it costs. **Any change that weakens or removes a §2 item needs explicit user confirmation first** — don't "simplify" it, refactor it away, or swap in a SwiftUI/AppKit equivalent. If a change seems to need one relaxed, stop and ask. Code comments cite these items as `§2.x`; keep the numbering stable.

## 1. Architecture

```
host VC (ChatSessionViewController via TranscriptSwapCoordinator, demo VCs)
   ├─ Transcript2Controller        host-facing, @Observable; owns the Coordinator
   ├─ Transcript2SheetPresenter    observes pendingUserBubbleSheet / pendingImagePreview
   └─ TranscriptScrollViewFactory.make / bindData / dismantle →
      Transcript2ScrollView (NSScrollView, .never, responsive scrolling)
         └─ Transcript2ClipView (.never)
            └─ Transcript2TableView (negative-size clamp)
               └─ BlockCellView (draw(_:), .onSetNeedsDisplay)
```

`Transcript2Coordinator.blocks: [Block]` is the single source of truth — no `rows` mirror, no parallel diff structure. Every mutation is a `Transcript2Controller.Change` (`.prepend` / `.append` / `.replace` / `.remove` / `.update`) through the one sync `apply(_:scroll:)`. Layouts are lazy on `heightOfRow`, or precomputed off-main and landed as cache hits.

Dependencies flow one way: host VC → Controller → Coordinator → `AppKit/` → `Layout/` → `Model/`. `Sheets/` holds SwiftUI sheet bodies used only by `Transcript2SheetPresenter`.

### 1.1 Controller vs. Coordinator — don't merge

- `Transcript2Coordinator` must be an `NSObject` (`NSTableViewDataSource` / `Delegate`) and holds everything that depends on the live table (anchor settling, row state).
- `Transcript2Controller` is `@Observable` so hosts can watch `blockCount` / `isAnchorSettled` / `searchState` / `pendingUserBubbleSheet` / `loadingPillVisible` without touching AppKit, and owns host-level logic (`setLoading` debounce + `reconcileLoadingPill`, search-state mirroring). Its other methods are thin forwards.
- Merging them would put every data-source callback on the host API and produce one oversized class. If the forwards feel redundant, make them thinner (e.g. expose `coordinator.search`), don't collapse the layer.

### 1.2 Runloop corollaries

Read the tick model in [macos/CLAUDE.md](../../../../CLAUDE.md#macos-runloop-tick-model) first. Transcript-specific consequences:

- **Deferred bind.** `TranscriptScrollViewFactory.make` builds the scroll/clip/table shell with **no `dataSource`**, so the host's `view.layoutSubtreeIfNeeded()` sizes it without any `heightOfRow` query. `bindData` then wires `dataSource` + `delegate` + the frame observer (no explicit `noteNumberOfRowsChanged` — it double-counts). `controller.scrollToTail()`'s internal `tableView.layoutSubtreeIfNeeded()` is the first layout with the data source bound, so it tiles at the final width and `rect(ofRow:)` is real in the same source phase. Contract and gates: §2.19.
- **`clip.scroll(to:)` needs settled geometry.** With `documentView.frame.height == 0`, `constrainBoundsRect` clamps the target to 0 and the write is silently absorbed. Without an enclosing frame change to ride on, force the tile with `noteNumberOfRowsChanged` / `insertRows` / `reloadData(forRowIndexes:)`.
- **`NSClipView.scroll(to:)` does not call `reflectScrolledClipView(_:)`.** Every direct `clip.scroll(to:)` (`Coordinator.scrollRowToBottom` / `scrollRowToTop`) must follow with `scrollView.reflectScrolledClipView(scrollView.contentView)`, or the scroller knob shows the old position. Gate: `TranscriptScrollFirstFrameSnapshotTests.testScrollerKnobLandsAtTailAfterScrollToTail`.
- **`tableView.layoutSubtreeIfNeeded()` doesn't re-tile a same-size, un-invalidated table.** It tiles when the frame changes (first attach) or when an invalidation is queued (`invalidate(rows:)` → `noteHeightOfRows` is deferred).
- **`controller.blockCount` is current right after `apply` returns** (mirrored synchronously via `onBlockCountChanged`); `@Observable` observers see it on the next display.
- **Scroll + row mutations run under `CATransaction.setDisableActions(true)` + `NSAnimationContext.allowsImplicitAnimation = false`.** The height change (AppKit-implicit) and the scroll origin change (CoreAnimation-implicit) commit independently at beforeWaiting; unsuppressed, they animate separately and the rows tear.

## 2. Performance contract

Every item is load-bearing for scroll FPS, layout cost, or memory churn. **Changing any of them requires user confirmation.**

### 2.1 `NSTableView`, not `List` / `LazyVStack`
`heightOfRow` is answered synchronously from `layoutCache` or computed on a miss — no estimated heights. SwiftUI lists must either block or estimate. **Cost of replacing:** a cold-load freeze, or jitter on every scroll as estimates resolve.

### 2.2 Cell layer: `wantsLayer` + `.onSetNeedsDisplay`
`BlockCellView` caches its drawn bitmap in its layer; scrolling composites without calling `draw(_:)`. **Cost of `.never`:** every visible cell redrawn every scroll frame. **Cost of `.onDemand`:** redraw on every structural change, hover included.

### 2.3 Scroll / clip views: `.never` + responsive scrolling
`Transcript2ScrollView.isCompatibleWithResponsiveScrolling = true`; scroll and clip views use `.never` (they own no pixels). **Cost of dropping responsive scrolling:** synchronous `drawRect` per scroll frame. **Cost of dropping `.never`:** a redundant draw pass per tick.

### 2.4 `layoutCache: [UUID: CachedLayout]`, no LRU
Keyed by block id, width inside the entry. Evicted only on `.update` / `.remove` (`removeCachedLayout(for:)`); filled lazily by `layout(for:width:)` or eagerly by `refillLayoutCache` and the backfill precompute. **Cost of an LRU:** eviction logic and hit-rate variance for a bounded (≤ ~10k) set.

### 2.5 `nonisolated static makeLayout`
`Transcript2Coordinator.makeLayout(for:width:highlights:folds:statuses:)` takes snapshot dicts captured on the main actor and makes no actor hops. **Cost of `@MainActor`:** off-main layout becomes a stream of main-actor hops and the parallel precompute paths serialize.

### 2.6 Backfill: built off-main, applied sync in budgeted ticks
`TranscriptBackfillPipeline` (`NativeTranscript2Bridge/`) reads reverse pages, builds blocks **and typesets their `RowLayout`s** off-main, and deposits pages into a main-owned buffer. The main drain applies each page through `apply` — tail page `.append`, older pages `.prepend` with `.saveVisible(.visualTop)` — under a per-tick block budget. Layouts are installed via `apply`'s `precomputed:` **before** the structural change, so `insertRows`' synchronous `heightOfRow` is a cache hit. The producer's width is seeded by `start(width:)` (the settled `controller.layoutWidth`) and updated by `retarget(width:)` at live-resize end (`onLayoutWidthDidSettle`); a width mismatch self-heals as a cache miss, so there is no validation gate. **Cost of building on main:** a 100 ms+ freeze on a long cold load.

### 2.7 `refillLayoutCache`: prefetch + forced tile + in-tick anchor
After `viewDidEndLiveResize`, off-screen layouts are prefetched on a detached task, then under `.saveVisible(.visualTop)` installed, `noteHeightOfRows`'d, and **`table.layoutSubtreeIfNeeded()` is forced before `applyAnchor`** — `noteHeightOfRows` defers its re-tile, so without the flush the anchor compensates against stale heights. Because compensation is in-tick, a concurrent `apply` interleaves harmlessly; there is no mutation counter. **Cost of dropping the forced tile:** the anchor row jumps. **Cost of dropping the prefetch:** off-screen rows lay out one at a time as they scroll in.

Only this path needs the flush: the `insertRows` paths settle geometry inside `endUpdates`, so their `.saveVisible` anchor already reads real `rect(ofRow:)`.

### 2.8 Live resize touches visible rows only
`tableFrameDidChange` invalidates only rows in `visibleRect` while `inLiveResize`; the rest wait for `refillLayoutCache`. **Cost of invalidating all:** O(N) layout per resize frame.

### 2.9 Negative-size clamp
`Transcript2TableView.setFrameSize` clamps to ≥ 0 (AppKit briefly sends negative widths during scroller layout). **Cost of dropping:** "Invalid view geometry" warnings and undefined frames.

### 2.10 `invalidate(rows:)` suppresses implicit animation
`reloadData(forRowIndexes:)` + `noteHeightOfRows` run with `duration = 0`, `allowsImplicitAnimation = false`, `setDisableActions(true)`. **Cost of dropping:** rows overlap during fast resize (cells repaint at the new height while neighbours animate from the old y).

### 2.11 Granular updates only; never `reloadData()`
Structural changes go through `applyStructuralChange` inside `beginUpdates` / `endUpdates` using `insertRows` / `removeRows` / `reloadData(forRowIndexes:)`. **Cost of one `reloadData()`:** O(N) typeset + full cell churn.

### 2.12 Highlight back-fill skips `noteHeightOfRows`
`handleHighlightDidFill` does `removeCachedLayout(for:)` + `reloadData(forRowIndexes:)` only — tokens change colour, not metrics. **Cost of adding it:** re-query of every following row per fill.

### 2.13 Status updates bypass `Change.update`
`Coordinator.setStatus(id:)` writes `statusStates[id]`, evicts the host row's layout, and reloads that one row. **Cost of `Change.update`:** `Block.Kind` rebuild, dropped selection and highlight tokens, a needless `noteHeightOfRows`.

### 2.13b Search highlights bypass `Change.update`
Hits live in `Transcript2SearchCoordinator`; affected cells are repainted via `markCellSearchDirty(blockId:)` → `BlockCellView.searchHighlights` + `needsDisplay`. No `reloadData`, no `noteHeightOfRows`. **Cost of `Change.update`:** every keystroke drops selection, reschedules syntax tokens and re-measures rows.

### 2.14 `cacheLayouts` anti-poison check
`cacheLayouts(_:width:)` skips a write when a fresh entry at the same width exists, so a late background result can't overwrite a newer sync layout. **Cost of dropping:** cache poisoning under interleaved `apply` + `refillLayoutCache`.

### 2.15 Per-scope dedup + generation guard in `Transcript2HighlightStorage`
`sourceKeys[Key]` fingerprints what produced each scope's tokens; a `schedule` whose fingerprint matches is skipped. `inflightGen[Key]` is **per scope**: `schedule` bumps the targeted scope, `drop` bumps every scope of the block, and a finishing job discards writebacks for drifted scopes. **Cost of dropping dedup:** siblings of an updated tool child flash plain → coloured while streaming. **Cost of per-block gen:** one scope's reschedule discards unrelated scopes' valid results.

### 2.16 Shimmer overlay: CALayer + CTLine + subpixel `xOffset` + image cache
In `BlockCellView+SubviewPlan.swift` (`ShimmerLayerSet`): the overlay bitmap is drawn with the same sub-pixel `xOffset` as the cell's glyphs (**else** a double-image smear as the stripe sweeps); it's cached on `imageKey(title, font, appearance, scale, xOffset, bottomPadding, size)` (**else** a 15–50 µs raster per reconcile); `viewDidChangeBackingProperties` updates `contentsScale` and drops cached bitmaps (**else** stale rasters across displays).

### 2.17 `CenteredRowView` reuse key
A no-op `NSTableRowView` subclass under identifier `"BlockRow"` in `rowViewForRow`; centering is `BlockCellView.layoutOrigin`'s job. **Cost of removing:** fresh row views allocated per scroll tick.

### 2.18 Caller-supplied, identity-stable `Block.id`
`Block.id: UUID` is never derived from content. Cache, selection, highlight scope, fold and status state all key on it. **Cost of content-hashed ids:** identical consecutive messages collapse; selection and highlights drift across content-equal updates.

### 2.19 Attach contract: one source-phase tick = one width per id
The tick that mounts a transcript — `factory.make` → `addSubview` + constraints → host `view.layoutSubtreeIfNeeded()` → `factory.bindData` → `controller.scrollToTail()` — must typeset each visible block at **exactly one width** (the settled row width). Anything that fires `heightOfRow` mid-cascade (data source bound early, `layoutSubtreeIfNeeded` after `bindData`, an extra `scrollToTail` before settle) typesets every block at the `minLayoutWidth` clamp, then the real width, sometimes `maxLayoutWidth` too. **Cost:** 2–3× Core Text work per attach, cache thrash, a visible stutter on every session switch.

Merge gates (default suite, no `Snapshot` suffix on purpose):

| Test | Catches |
|---|---|
| `TranscriptReentryLayoutCacheTests` | Factory regressions (e.g. eager `dataSource` bind) |
| `TranscriptHostReentryLayoutCacheTests` | Host regressions through `ChatSessionViewController.present(sessionId:)` → `attachSession`: `bindData` before settle, the settle dropped, a new attach-time tile trigger |
| `TranscriptBackfillLayoutCacheTests` | The single-width rule across multi-tick backfill |
| `TranscriptBackfillAnchorTests` | Prepend anchoring, in-tick stability, `.update`/`.replace` viewport preservation |
| `TranscriptColdAttachTests` / `TranscriptDetachedWarmTests` | Cold attach lands at tail; `blocks.count == numberOfRows`; a detached session pre-warms so re-attach computes zero rows on main |

**Never `XCTSkip` them or widen the offender tolerance** — a tolerated multi-width write *is* the bug. When a host test goes red, read the per-stage report it attaches before changing code; the offender list names the call.

## 3. Invariants

### 3.1 Data and state
- **One source of truth:** `Coordinator.blocks`. The only derived store is `layoutCache`; `removeCachedLayout(for:)` is always safe.
- **One mutation entry point:** `apply(_:scroll:)`. Off-main work (backfill producer, `refillLayoutCache`) precomputes and feeds the same `apply` / `cacheLayouts`; never add a `pendingBlocks` side path.

### 3.2 Row state lives on the Coordinator as sparse dicts
Row state is **not** stored in `Block.Kind`: it must survive content `.update`s and layout rebuilds, and layout is a pure function with state as an input. A new stateful behavior = a new sparse dict on the Coordinator (absent = default), threaded through `makeLayout` into the relevant `XxxLayout.make`.

| Dict | Key | Default | Drives |
|---|---|---|---|
| `foldStates: [UUID: Bool]` | `Block.id` or `Child.id` | folded | Collapsed ↔ expanded body (`userBubble` uses truncate + sheet instead) |
| `statusStates: [UUID: ToolStatus]` | group or child id | `.completed` | Header colour + shimmer |
| `search.hits` + `hitsByBlock` | `Block.id` | no hits | Paint-only search overlay (§2.13b) |

Mutation entry points: `Coordinator.toggleFold(id:)` (flag, then `noteHeightOfRows` + `reloadData(forRowIndexes:)` in an animation group); `Controller.setToolStatus(id:status:)` → `Coordinator.setStatus(id:)` (§2.13); `Controller.runSearch` / `nextSearchHit` / `previousSearchHit` / `endSearch` (§6.5).

### 3.3 Tool group status visuals
- Status is folded into `ToolGroupLayout.Header.status` at `make` time; colour and shimmer come only from `titleColor(for:hovered:)`, `chevronTint(for:hovered:)`, `wantsShimmer(for:)`. New status visuals go there.
- `.running` uses the same colours as `.completed`; the running cue is the shimmer. A colour-tier change pops brightness on every transition.
- `.failed` is colour-only (`systemRed` header + chevron; its `message:` is unused). Error **text** is body content (the error card, §5) because it changes row height and must ride the structural path.
- Shimmer is an **additive overlay, not a mask** (a mask dims anti-aliased edges): the cell always paints the title in secondary colour; a pixel-aligned overlay `CALayer` adds `labelColor` glyphs through an `[α 0,1,0]` gradient; hover forces overlay opacity to 0.
- `SubviewPlan.Chevron` carries resolved stroke colour + alpha; `SubviewPlan.Shimmer` carries text rect + title + font + hovered. The cell stays status-enum-free.

### 3.4 `Change` dispatch
There is no diff algorithm — the controller declares the operation, `applyStructuralChange` runs it inside `beginUpdates` / `endUpdates`.

| Case | Table call | Cache / state effect |
|---|---|---|
| `.prepend` / `.append` / `.replace` | `insertBlocks(after:)` → `insertRows(…, .effectFade)` | none (lazy) |
| `.remove(ids)` | `removeRows(…, .effectFade)` | evict layout, drop selection entry + highlights + fold/status |
| `.update(id, kind)` | `reloadData(forRowIndexes:)` + `noteHeightOfRows` | evict layout, reschedule highlights (per-scope diff, §2.15), drop selection entry |

## 4. Layout boundaries

An `XxxLayout` is an immutable value holding the width-dependent geometry to report a row's height and draw its body. Code belongs in a Layout only if it is (1) a pure function of width — no hover / selection / animation awareness, (2) row-body content — it could change the row height, and (3) needed before `draw` (`heightOfRow` is synchronous). State is an input: `make(input, width, state) -> Layout`.

| Layout owns | `BlockCellView` owns |
|---|---|
| Glyph positions, image rects, table-cell content — anything that changes height | Row padding, corner radius, shadows, placeholders — pure decoration |
| A description of needed subviews / sublayers (`SubviewPlan`) | Reconciling subviews / sublayers against that plan |

- `enum RowLayout` wraps each concrete layout behind `totalHeight` / `measuredWidth` / `draw(in:origin:)`; the cell never inspects the case. A new layout kind = a `RowLayout` case + one line in each of its switches.
- **Decorations that can't be a bitmap** go through `RowLayout.subviewPlan(origin:hoveredAction:selection:flashingCopyIds:) -> SubviewPlan`: a `CAShapeLayer` chevron (rotation animation), layer-backed `NSView` body slabs (slide past each other during fold). Only `toolGroup` emits a non-empty plan today.
- `SubviewPlan` and `SelectionAdapter` are **struct + closures, never protocols** — enum dispatch gives exhaustiveness; a protocol lets a case silently miss an implementation. New decoration category = a `SubviewPlan` field + a reconcile arm in `BlockCellView+SubviewPlan.swift`; another layout emitting one = an arm in `RowLayout.subviewPlan`.

## 5. Adding a block kind

1. Add a `case` to `Block.Kind`; re-run the three checks in §4 to decide whether it needs its own Layout.
2. Add an arm to `Transcript2Coordinator.makeLayout` dispatching to `XxxLayout.make` and wrapping in the `RowLayout` case. It must stay actor-free (§2.5): read per-block state only from the supplied `highlights` / `folds` / `statuses` snapshots.
3. New layout type → `Layout/XxxLayout.swift` + a `RowLayout` case.

Dispatch per kind inside `makeLayout`; don't add an umbrella `BlockStyle.attributed(for: Block)` — kinds don't share an attributed-string shape. Text kinds take `[InlineNode]` (the inline IR from the markdown parser); there's no `String` overload — wrap as `[.text(s)]`.

### Tool groups (`.toolGroup` → `ToolGroupLayout`)

One row hosts the whole group: a 24pt group header (title + chevron, no icon, no inset), then child headers with the same `BlockStyle.toolHeader*` constants, 4pt apart (`toolHeaderChildSpacing`); an expanded child shows a 4pt gap then a `codeBlock`-style card (`diffContainerBackground`, `structuralCornerRadius`).

- **Chevron:** two self-drawn segments (`lineWidth 1.4`, round caps) — never an SF Symbol. Alpha 0.35 idle / 0.85 hover; rotation 0 folded, π/2 expanded. Its centre y adds `max(0, (capHeight − xHeight) / 2)` so it sits on the title's x-height midline.
- **Hover:** `BlockCellView`'s tracking area resolves a `HitAction`; `ToolGroupLayout.draw` matches `.toggleFold(id)` against each header's `foldId` and switches that header to `labelColor` + hover alpha.
- **Fold routing:** the id in `.toggleFold` may be a group `Block.id` or a `Child.id`; `Coordinator.toggleFold(id:)` must search both top-level blocks and every group's children, or child-header clicks do nothing.
- **Titles:** `group.resolvedTitle(status:isExpanded:)` is the single source — `.running` folded → `activeTitle`, `.running` expanded → `expandedActiveTitle`, otherwise `completedTitle`. Children: `Child.headerLabel(for:)` → `activeLabel` while running, else `label`. The bridge (`MessageEntryBlockBuilder` + `ToolUseToChild`) fills both forms and the layout switches on `statusStates`, never via `Change.update`. For a single-tool group use `ToolUseBlock.activeFragment` / `completedFragment` directly, not `activeCountPhrase(1)` ("Reading 1 file").
- **Headers show the payload's `label`,** never a raw path (`FileEditChild.filePath` is only for language detection).

**Adding a child kind:**

1. `Layout/ToolGroupChildren/<Kind>/<Kind>Child.swift` — payload exposing `id`, `label` (past), `activeLabel` (progressive), `var errorText: String? = nil`. In `Block.swift`, add the case and an arm to each of the `id` / `label` / `activeLabel` / `errorText` / `hasExpandableBody` switches.
2. `<Kind>ChildLayout.swift` — `make` / `totalHeight` / `draw` / `drawBackplate`. Multi-card bodies reuse `TextCardSection`. **Don't render `errorText`** — the error card is composed uniformly (below).
3. Add the case to `ToolGroupChildLayout.Kind` and its four switch arms (`totalHeight`, `drawBackplate`, `draw`, `Kind.make`).
4. Header-only kinds: `hasExpandableBody = false`, `totalHeight == 0`, empty draws — the chevron and fold hit disappear automatically. Any kind with `errorText != nil` reports `hasExpandableBody = true` so it has a body for the error card.
5. Async highlighting → a case in `ToolGroupChildHighlight.requests(for:)` returning a `Plan`.
6. Selection/search: bodies built on `TextCardSection` are selectable and searchable for free (`LayoutPosition.textCard(childIndex:sectionIndex:char:)`, section-local granularity; cross-section and cross-child drags clamp). Only a body not built on it needs a new `LayoutPosition` case + `buildRegions` arm — as `fileEdit` / `read` do with `.diff(childIndex:char:)`.

**Error card, uniform across kinds.** On an `is_error` tool result, `ToolUseToChild` puts the wrapper-level message (the `tool_result` text, stripped of `<tool_use_error>` tags) into the payload's `errorText`. `ToolGroupChildLayout.make` appends one red monospaced `TextCardSection` (+ a `CopyChrome` on a high sentinel slot) **below** the kind's body — the only place error text renders. It's the trailing text-card section, so it's selectable and searchable on every kind. `read` passes `content: nil` on error so the message isn't also shown as file content.

**Diff bodies:** `fileEdit` / `read` use `DiffLayout`. `read` is new-file mode (`oldString == nil`): `.add` lines render as `.context` — line numbers and tokens, no `+` or add background. Highlighting is per unique line (`.lineMap`, keyed by raw line content); `onDidFill` reloads without `noteHeightOfRows`.

### `.userBubble` → `UserBubbleLayout`
Right-aligned; hard-truncates at `userBubbleCollapseThreshold` lines with `CTLineCreateTruncatedLine` + a `>` chevron inside the padding; selection clamps to the visible prefix. Stateless — no fold flag. Chevron `mouseDown` → `Coordinator.requestUserBubbleSheet(id:)` → `Transcript2Controller.pendingUserBubbleSheet` → `Transcript2SheetPresenter` opens an AppKit sheet hosting `UserBubbleSheetView`.

## 6. Directory map

| Dir | Contents |
|---|---|
| `Model/` | `Block` (kinds + geometry/typography constants), `InlineNode` |
| `Layout/` | One file per `XxxLayout`, `RowLayout` (dispatch), `SelectionAdapter`, `SubviewPlan`, `CopyChrome` (shared copy button) |
| `Layout/ToolGroupChildren/` | `ToolGroupChildLayout` (per-kind dispatch + error card), `TextCardSection`, `ToolGroupChildHighlight`, one subdirectory per child kind (payload + layout + highlight) |
| `AppKit/` | Scroll / clip / table subclasses, `TranscriptScrollViewFactory`, `BlockCellView` (+ `SubviewPlan` reconciler, gutter), `CenteredRowView`, `Transcript2SheetPresenter`, `LoadingPillUsageView` |
| `Sheets/` | SwiftUI sheet bodies |
| root | `Transcript2Controller`, `Transcript2Coordinator`, `Transcript2SelectionCoordinator`, `Transcript2SearchCoordinator`, `Transcript2HighlightStorage` |

## 6.5 Search

`Transcript2SearchCoordinator` owns search state, sibling to `Transcript2SelectionCoordinator`; search paint composites **over** the selection band.

- **Host UI:** an `NSSearchToolbarItem` in `MainWindowController`'s toolbar, wired by `TranscriptSearchToolbarBridge`: typing → `controller.runSearch`, Return → next, Shift+Return → previous. It's always visible; ⌘F bumps `TranscriptSearchBus.focusRequestCounter` and the bridge makes the field first responder. The window uses `.fullSizeContentView` + transparent titlebar + `.unified` toolbar so the transcript runs under the toolbar band.
- **Flow:** `runSearch(q)` → the scanner walks `blockIds`, asks each layout's `selectionAdapter.searchableRegions()`, runs a case-insensitive literal match per region, converts matches to `SelectionRange`s → `hits` (document order) + `hitsByBlock` → `onStateChanged` → the controller's `@Observable searchState`.
- **Search range == selection range.** Regions and hit rects come from the same `SelectionAdapter` closures selection uses, so a hit highlights exactly the glyphs a drag would. A layout that supplies `searchableRegions` joins search with no search-side code.
- **Coverage:** paragraph, heading, codeBlock, blockquote, userBubble (visible prefix only), and **currently expanded** tool children (diff bodies, text-card bodies, error cards). Folded children carry no body, so they aren't scanned. `list` / `table` return no regions yet — adding them is a `searchableRegions` implementation per layout.
- **Rendering:** `BlockCellView.searchHighlights`; `systemYellow` @0.42 for hits, `systemOrange` @0.78 for the current one, attenuated when the window isn't key.
- **Folded navigation:** `Coordinator.expandForSearchHit(blockId:position:)` runs before every nav scroll and opens the group and the one child the hit's position names, leaving siblings alone.

## 7. Async highlight back-fill

`Transcript2HighlightStorage` is a per-block async side channel. Value shapes: `.tokens([SyntaxToken])` (whole code blocks) and `.lineMap([content: tokens])` (diffs, per unique line).

1. `apply` calls `storage.schedule(block)` on insert / `.update`.
2. `plan(for:)` returns `Plan { payload, writeback }`; one `engine.highlightBatch(payload)` crosses into JavaScriptCore; results come back through `writeback`.
3. `onDidFill(blockId)` → `removeCachedLayout` + `reloadData(forRowIndexes:)` (never `noteHeightOfRows`, §2.12); the next `makeLayout` reads the snapshot and colours it.

Generation guard and per-scope dedup: §2.15. A new highlight-bearing kind: a `Transcript2HighlightScope` case (extend `HighlightValue` only if neither shape fits), a `plan(for:)` arm, an optional token parameter on `XxxLayout.make`, and a `makeLayout` arm threading it through. The storage and reload pipeline don't change.

## 8. Verifying changes

| Touched | Verify with |
|---|---|
| Coordinator / pipeline / `BlockCellView.draw` / any Layout | The Transcript Demo (sidebar, DEBUG) or `make test-unit FILTER=TranscriptDemoSnapshotTests` |
| Attach, backfill, anchoring | The §2.19 merge gates |
| Scroll / table subclasses | `make build`, launch, drag the window width to check reflow |
