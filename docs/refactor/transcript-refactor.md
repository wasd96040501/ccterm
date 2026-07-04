# Transcript refactor — history-only, session-agnostic

Status: proposal (pre-implementation), v2 (post-review).
Scope: rewrite the transcript viewer along the top-level `CLAUDE.md` MVVM-C conventions. The current on-branch state routes `.history` selections to a WIP `TranscriptViewController` that violates the § 2.19 attach contract and misses parity items; this plan replaces that WIP with a compliant implementation.

**Explicit non-goal:** removing the old renderer stack (`Transcript2Controller` / `Coordinator` / `Bridge` / `BackfillPipeline`). Those types are still constructed inside `Session.swift` for every session, and pulling them out is a separate PR. They stay compiled, unreferenced by the new history path.

## 1. Goals

1. **Session-agnostic transcript.** Read by `transcriptId: String`; nothing about `Session` / `SessionRuntime`. State lives in an app-scope registry so sidebar switch-back paints instantly.
2. **Layering per top-level `CLAUDE.md`.** Store owns data + cache; ViewController owns lifecycle + dataSource/delegate; Registry lives at the composition root in `AppContext`. Data down, events up; no ViewModel layer.
3. **Perf parity with the old renderer** on every § 2 item — see § 11.
4. **Layout parity.** Content clamped to `[BlockStyle.minLayoutWidth, BlockStyle.maxLayoutWidth] = [460, 780]` and horizontally centered inside a full-width scroll view; the old `TranscriptScrollViewFactory.contentInsets` — `top: 56, bottom: 112` — reused verbatim.
5. **Interaction parity for history.** Hover title-brightening, tool group / child fold, syntax highlight back-fill on `.codeBlock` + `fileEdit` diff lineMap.
6. **Naming compliance.** Every new type carries a listed role suffix (`View` / `Controller` / `Store` / `Delegate`). No `Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Adapter`.

## 2. Components — new only

| Component | Role | Function | Downward dependencies |
|---|---|---|---|
| `TranscriptStore` | Store | `[Block]` + `[UUID: RowLayout]` + `layoutsWidth`; `events` (`.tail` / `.older`); `loadHistoryIfNeeded()` starts the SDK stream once; `layout(for:width:folds:statuses:highlights:)` get-or-compute (miss → `RowLayout.make` + write-back); `writeLayouts(_:width:)` bulk-write from Phase 2 — **stale-width batches are dropped whole, current cache is NEVER wiped** (see § 5.3); `retargetWidth(_:)` explicit width-transition — wipes stale cache and sets `layoutsWidth` (called by VC on live-resize before dispatching prefetch); `invalidateLayout(id:)` single-key evict (used by highlight back-fill + fold toggle) | `SessionHistory.load` / `ReverseEntryBuilder` / `MessageEntryBlockBuilder` / `RowLayout.make` / `Block` / `RowLayout` |
| `TranscriptRegistryStore` | Store | App-scope `[transcriptId: TranscriptStore]`; `store(for:) -> TranscriptStore` get-or-create; `discard(_:)` **wired to `SessionManager` archive/delete** (see § 10.2). | `TranscriptStore` |
| `TranscriptHighlightStore` | Store | Per-scope tokens cache; `schedule(block:)` with fingerprint dedup + per-scope generation guard (drops late writebacks after `.update` / `.remove`); `attachEngine(_:)` idempotent late-bind + reschedules all previously-scheduled scopes; `snapshot(for: UUID) -> [Transcript2HighlightKey: HighlightValue]` — per-block dict for MainActor→detached snapshot capture; `onDidFill: (UUID) -> Void` callback. Modeled after `NativeTranscript2/CLAUDE.md § 2.15` (see § 7 for behavior deltas). | `SyntaxHighlightEngine` / `Block` |
| `TranscriptClipView` | View | `NSClipView` subclass. Overrides `constrainBoundsRect(_:)`: when `documentView.frame.width < proposedBounds.width` → `origin.x = floor((proposedBounds.width - documentView.frame.width) / -2.0)`; else pass through. Vertical passes through. Also clamps negative widths on `setFrameSize` (§ 11 / § 2.9). | — |
| `BlockCellViewDelegate` | Delegate | Class-only protocol. **Every** current `coordinator?.…` call site in `BlockCellView*.swift` gets a method — see § 8 for the full list. | — |
| `TranscriptViewController` | Controller | `NSViewController` + `NSTableViewDataSource` + `NSTableViewDelegate` + `BlockCellViewDelegate` + `DetailContainerChild`. Owns view tree, `folds`/`statuses`/`hoveredBlockId` sparse dicts, `TranscriptHighlightStore` instance, phase-1/2 apply, fold path, hover path, highlight-refill path, live-resize refill. **Two-step attach**: `viewDidLoad` subscribes + configures cell reuse but does **not** wire dataSource; `viewDidLayout` first-pass runs `view.layoutSubtreeIfNeeded()` → binds dataSource/delegate → calls `store.loadHistoryIfNeeded()` (see § 5.4). | `TranscriptStore` / `TranscriptHighlightStore` / `TranscriptClipView` / `BlockCellView` / `BlockCellViewDelegate` / `Block` / `RowLayout` / `BlockStyle` / `SyntaxHighlightEngine` |

Nothing else is new. Already present: `Block`, `RowLayout`, all `XxxLayout.make`, `BlockCellView` (with the `coordinator → delegate` surgery below), `BlockStyle`, `SyntaxHighlightEngine`, `ReverseEntryBuilder`, `MessageEntryBlockBuilder`, `SessionHistory.load`, `AppContext.transcriptRegistry` field, `AppDelegate` registry construction, `DetailContext.transcriptRegistry` propagation, `DetailFlowCoordinator.makeChild(.history)` short-circuit.

## 3. Naming compliance

Every new symbol checked against `CLAUDE.md § AppKit conventions — Project structure & modularization`:

- **Role suffix.** `View` / `Controller` / `Store` / `Delegate` only. `Storage` → `Store`. No `Adapter` / `Manager` / `Presenter` / `Bridge` / `Pipeline`.
- **No numeric suffix.** No `Transcript2Xxx`; the version differentiator does not exist in new types.
- **Data types have no suffix.** `Block`, `RowLayout`, `HighlightValue`, `Message2` are already suffix-free (existing).
- **Directory = feature.** Files live under `macos/ccterm/Content/Chat/Transcript/`.

## 4. Layout — 460..780 band centered in full-width scroll

### 4.1 Why we need `TranscriptClipView` (not Auto Layout alone)

Auto Layout on the documentView alone will **not** center it. `NSClipView.constrainBoundsRect(_:)` clamps `bounds.origin.x` to make a narrow documentView flush-left when the documentView is narrower than the clip — that's Apple's documented behavior and the reason every community writeup on centering an `NSScrollView`'s document view subclasses `NSClipView`. Sources verified.

### 4.2 View hierarchy

Constructed in one place — `TranscriptViewController.loadView()`:

```
TranscriptViewController.view                NSView         full-pane
 └ NSScrollView (host)                       stock
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              — § 2.3
    · hasVerticalScroller = true; autohidesScrollers = true
    · hasHorizontalScroller = false
    · scrollerStyle = .overlay
    · drawsBackground = false; borderType = .noBorder
    · automaticallyAdjustsContentInsets = false
    · contentView = TranscriptClipView()                              — MUST be assigned BEFORE contentInsets
    · contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)  ← ordering intentional
    Constraints: leading/trailing/top/bottom == view.<same>
 └ TranscriptClipView (contentView)          subclass
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              — § 2.3
    · constrainBoundsRect: horizontal center when documentView narrower
    · setFrameSize: max(0, w), max(0, h)                              — § 2.9 negative-width clamp
 └ NSTableView (documentView)                stock
    · headerView = nil
    · backgroundColor = .clear
    · style = .plain
    · selectionHighlightStyle = .none
    · gridStyleMask = []
    · usesAutomaticRowHeights = false; rowSizeStyle = .custom
    · intercellSpacing = .zero
    Auto Layout:
      · widthAnchor ≤ BlockStyle.maxLayoutWidth (780)           — required
      · widthAnchor ≥ BlockStyle.minLayoutWidth (460)           — required
      · widthAnchor == clip.widthAnchor priority .defaultLow    — hug clip inside band
      · topAnchor == clip.topAnchor
      · Height driven by NSTableView's intrinsic content size (rows sum) — no bottom pin
    Single column:
      · identifier = "block"
      · resizingMask = [.autoresizingMask]
      · minWidth = 0; maxWidth = .greatestFiniteMagnitude
 └ NSTableRowView                            stock (no subclass)
 └ BlockCellView                             reused. Reuse identifier: "TranscriptBlockCell"
    (bounds.width ∈ [460, 780])
```

### 4.3 BlockCellView needs no centering change

`BlockCellView.layoutOrigin.x = BlockStyle.cellOriginX(forRowWidth: bounds.width) + blockHorizontalPadding`.
When `bounds.width ∈ [460, 780]`, `cellOriginX` returns 0. `layoutOrigin.x` collapses to the constant `blockHorizontalPadding`. The manual-centering arithmetic in the cell degenerates to a no-op; Auto Layout + `TranscriptClipView` do the centering.

### 4.4 Live resize behavior

- Clip width changes → `TranscriptClipView.constrainBoundsRect` re-centers the (unchanged-width) table.
- Clip width < 460 → `widthAnchor ≥ 460` wins; table stays 460 wide; the left/right edges spill past the visible area; horizontal scroller is off so it clips (accepted — narrower-than-460 window is edge). This matches old behavior (`BlockStyle.clampedLayoutWidth` never shrinks below `minLayoutWidth`).
- Clip width ∈ [460, 780] → `widthAnchor == clip.widthAnchor` at low priority wins; table hugs clip.
- Clip width > 780 → `widthAnchor ≤ 780` wins; table stays 780; clip re-centers via subclass.

### 4.5 Scrims

Deferred. The old `ChatSessionViewController` overlaid `TranscriptTopScrimView` + `TranscriptBottomScrimView` for gradient fade-in/out at top / bottom. The history-only VC does not overlay them yet; content clips flat against the contentInsets boundary. Follow-up: `TranscriptViewController` gains two full-width overlay subviews on top of the scroll view. Tracked as an explicit visual delta from the old rendering.

## 5. Data flow

```
~/.claude/projects/<id>.jsonl                     (CLI-written file)
   │
   ▼
AgentSDK.SessionHistory.load(id:, order:.reverse)
   │  · Task.detached in the SDK: reverse walk + decode + cross-batch tool-result pairing
   │  · yields AsyncThrowingStream<[Message2], Error>
   ▼
TranscriptStore.loadHistoryIfNeeded()
   · Task { for try await batch in stream { ingestReverseBatch(batch) } ; finalizeLoad() }
   ▼  (each batch, MainActor)
ReverseEntryBuilder.ingest(_: Message2) -> [MessageEntry]
   · maintains open group + withheld tool_result buffer across batches
   ▼
MessageEntryBlockBuilder.blocks(from:) -> [Block]
   · MainActor-isolated existing code; block-building runs on main
   ▼
TranscriptStore emits events.send(.tail | .older); updates blocks[]
   │
   ▼  Combine .receive(on: DispatchQueue.main)
TranscriptViewController.apply(_ delta)
```

### 5.1 Phase 1 (`.tail`) and Phase 2 (`.older`) share the off-main typeset path

**Correction from an earlier draft:** Phase 1 does **not** typeset synchronously on main. The old backfill pipeline (`NativeTranscript2/CLAUDE.md § 2.6`) builds the tail page off-main and main-drains the apply; syncing on main was a mistake in an earlier plan revision that would have frozen the first frame on tail messages with heavy body content (worst realistic case: reopening a session whose most recent turn is a fileEdit with a 500-line diff — synchronous `DiffLayout.make` typesets 500 lines on main, freezing perceptibly). Phase 1 goes through the same off-main dispatch as Phase 2 to preserve § 2.6.

The two phases share one dispatch skeleton; the only differences are the structural-change kind (`.tail` = append at bottom, `.older` = insert at index 0) and the post-apply anchor.

### 5.2 Off-main typeset → main-hop apply

Shared prologue:

1. `let w = tableView.bounds.width`; `let batch = blocks`.
2. Capture snapshots on MainActor: `foldsSnap = self.folds`, `statusesSnap = self.statuses`, `highlightsSnaps: [UUID: [Transcript2HighlightKey: HighlightValue]] = batch.reduce(into: [:]) { $0[$1.id] = highlightStore.snapshot(for: $1.id) }` — per-block dict up front so the detached body does no store reads.
3. `Task.detached(priority: .userInitiated) { … }`:
   - For each `b`: `RowLayout.make(for: b, width: w, folds: foldsSnap, statuses: statusesSnap, highlights: highlightsSnaps[b.id] ?? [:])`.
   - Hop back: `await MainActor.run { … }`.

**`.tail` branch on main:**

   - `store.writeLayouts(pairs, width: w)`
   - Inside `CATransaction.setDisableActions(true)` + `NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false }`:
     - `tableView.beginUpdates()`
     - `tableView.insertRows(at: [tail range], withAnimation: [])`
     - `tableView.endUpdates()`
   - `tableView.scrollRowToVisible(tableView.numberOfRows - 1)` — anchor at bottom.

**`.older` branch on main:**

   a. **Save scroll origin & first visible-row rect** before the structural change:
      ```
      let clip = scrollView.contentView
      let originBefore = clip.bounds.origin
      let visibleRange = tableView.rows(in: clip.documentVisibleRect)
      let firstVisibleRow = visibleRange.location            // may be NSNotFound
      let firstVisibleRect = (firstVisibleRow != NSNotFound)
          ? tableView.rect(ofRow: firstVisibleRow) : .zero
      ```
   b. Inside `CATransaction.setDisableActions(true)` + `NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false }`:
      - `store.writeLayouts(pairs, width: w)`
      - `tableView.beginUpdates()`
      - `tableView.insertRows(at: IndexSet(integersIn: 0..<batch.count), withAnimation: [])`
      - `tableView.endUpdates()`
   c. **Restore anchor** (skip when empty table on cold start):
      ```
      guard firstVisibleRow != NSNotFound else { return }    // no anchor to preserve
      let newRow = firstVisibleRow + batch.count
      let newRect = tableView.rect(ofRow: newRow)
      let delta = newRect.minY - firstVisibleRect.minY
      clip.scroll(to: NSPoint(x: originBefore.x, y: originBefore.y + delta))
      scrollView.reflectScrolledClipView(clip)               // docs-mandated
      ```
      Both `clip.scroll(to:)` and `reflectScrolledClipView` stay **inside** the disabled transaction — they are separate source-phase writes that both flush at `beforeWaiting`; the scroller-knob sync would otherwise animate independently of the origin adjustment. `rect(ofRow:)` returns valid values immediately after `endUpdates` because `insertRows` settles new-row geometry synchronously inside `endUpdates` (§ 2.11 — no estimated heights). See also `NativeTranscript2/CLAUDE.md § 1.2` sub-bullet on the `clip.scroll` / `reflectScrolledClipView` pairing.

This mirrors the old backfill pipeline's `.saveVisible(.visualTop)` semantics using stock NSTableView primitives. **Reason it's needed:** stock NSTableView does **not** auto-anchor when rows insert above the viewport; the review flagged this correctly.

### 5.3 `writeLayouts` under concurrent width change

Race: Phase 2 detached typeset uses width W₁; before it hops back, live-resize changes width to W₂ and evicts, **or** a lazy on-main `layout(for:width:)` already ran and wrote a fresh entry at W₁. Fix — `writeLayouts` semantics with the § 2.14 anti-poison guard:

```
func writeLayouts(_ pairs: [(UUID, RowLayout)], width: CGFloat) {
    guard width == layoutsWidth else { return }         // stale batch → drop whole
    let live = Set(blocks.map { $0.id })
    for (id, l) in pairs where live.contains(id) {
        if layouts[id] != nil { continue }              // § 2.14: never overwrite a fresh entry
        layouts[id] = l
    }
}
```

The two guards together match old `cacheLayouts`: don't write past a same-width fresh entry (§ 2.14) **and** don't overwrite the dict wholesale on width mismatch. Stale batches are silently discarded; VC's next `heightOfRow` on affected blocks lazy-typesets at the new width. Self-healing.

### 5.4 Attach contract — § 2.19 compliance

The critical rule: from `viewDidLayout` first-pass through `store.loadHistoryIfNeeded`, each visible block must typeset at exactly ONE width. Violated in v1 by binding dataSource in `viewDidLoad` and calling `reloadData()` before layout settled.

**Fixed order:**

```
loadView()
    build scroll + TranscriptClipView + table + column (no dataSource yet)
    add to hierarchy; activate constraints

viewDidLoad()
    tableView.delegate = self         ← delegate only; delegate methods don't force data queries
    (dataSource stays nil — no rows to query, NSTableView won't tile)
    (events subscription is NOT yet installed — installed post-attach in viewDidLayout)

viewDidLayout()                       ← first call: real frame just settled
    guard !didInitialAttach else { return }
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    view.layoutSubtreeIfNeeded()       ← flush any residual autolayout
    didInitialAttach = true
    tableView.dataSource = self        ← binds NOW; first heightOfRow at settled width
    if !store.blocks.isEmpty {         ← warm re-entry
        tableView.layoutSubtreeIfNeeded()   ← forces the dataSource-set attach path
                                              to tile at the settled width with cache hits
        tableView.scrollRowToVisible(store.blocks.count - 1)
    }
    subscribeStoreEvents()             ← install AFTER attach + warm tile
    store.loadHistoryIfNeeded()

(viewWillAppear is NOT used for load kick — it fires before viewDidLayout on first mount.
 AppKit still delivers viewWillAppear to us for containment/appearance; we just don't hook it.)
```

**No pendingDeltas queue** — the earlier revision parked deltas that arrived between `viewDidLoad` and `viewDidLayout`. That approach crashes on warm re-entry: a background loader from a prior mount can update `store.blocks[]` between the subscription and the attach; warm-re-entry then tiles the table inclusive of those already-appended rows via `layoutSubtreeIfNeeded`; draining the parked `.tail` / `.older` deltas afterwards would `insertRows` on already-present row indexes and raise `Invalid update: invalid number of rows in table view`. The store's `blocks[]` is the truth; the deltas are advisory. Solution: install the subscription **after** the warm-entry tile, so the tile handles the pre-attach growth and future deltas ride the normal apply path.

Warm re-entry does **not** call `reloadData(forRowIndexes:)` — that would race the dataSource-set tile path (which is lazy: AppKit re-queries `numberOfRows` / `heightOfRow` on the next layout pass, not synchronously on the set). Instead we call `tableView.layoutSubtreeIfNeeded()`, which is the same trick `TranscriptScrollViewFactory.bindData` documents (`§ 1.2` in `NativeTranscript2/CLAUDE.md`) — force the first tile at the settled width; `heightOfRow` hits the warm layout cache; `scrollRowToVisible` lands correctly.

### 5.5 Live-resize refill (§ 2.7 / § 2.8 parity)

`NSViewController.viewDidEndLiveResize()` override:

1. Read `w = tableView.bounds.width`.
2. **`store.retargetWidth(w)`** — new explicit API. Wipes stale cache, sets `layoutsWidth = w`. Without this, step 5's `writeLayouts` guard `width == layoutsWidth` would drop the whole batch (the store's `layoutsWidth` is still the OLD width until *someone* triggers `invalidateIfWidthChanged`, which only happens inside `layout(for:width:)` — a call chain that the off-main prefetch never enters).
3. Read `visibleIndexes = tableView.rows(in: tableView.visibleRect)` as an `IndexSet`.
4. Capture snapshots (folds/statuses/highlights) on MainActor; identify visible blocks via `store.blocks[i]` for each `i` in `visibleIndexes`.
5. `Task.detached(priority: .userInitiated)`:
   - For each visible block: `RowLayout.make(for: b, width: w, …)`.
   - `await MainActor.run { store.writeLayouts(pairs, width: w); … }` — writeLayouts now finds matching width, installs.
6. On main, inside `CATransaction.setDisableActions(true)` + disabled-animation context:
   - `tableView.noteHeightOfRows(withIndexesChanged: visibleIndexes)`
   - `tableView.layoutSubtreeIfNeeded()` — force the in-tick tile flush (§ 2.7 requires it; `noteHeightOfRows` alone defers to `beforeWaiting`).
   - Anchor restore for the visual-top row (same recipe as § 5.2.c).

Between step 2 (retarget) and step 6 (tile), a `heightOfRow` query from AppKit's own maintenance path would `layout(for: b, width: w)` on-main synchronously, cache-hit for whichever visible rows the detached task already finished + cache-miss recompute for the rest. Both paths land in the same width-w cache — no poisoning.

The `retargetWidth` seam is also called if the width changes for reasons *other* than live resize (e.g. window split resize without live tracking). VC-side rule: any observed `tableView.bounds.width` change → call `retargetWidth` before the next layout query touches the store.

## 6. Fold / hover / status — sparse dict pattern

`TranscriptViewController` owns three sparse dicts (defaults absent):

| Dict | Key | Default | Effect |
|---|---|---|---|
| `folds: [UUID: Bool]` | `Block.id` or `Child.id` | `false` (folded) | Fed into `RowLayout.make` on every miss. |
| `statuses: [UUID: ToolStatus]` | `Block.id` or `Child.id` | `.completed` | Same. |
| `hoveredBlockId: UUID?` | — | `nil` | Read by `BlockCellView` via delegate. |

Mutation:

- **Hover.** `BlockCellView.mouseEntered/Exited` → `delegate.hoveredBlockId = id`. Setter records old + new id, calls `tableView.reloadData(forRowIndexes: rowsFor([oldId, newId].compactMap{$0}), columnIndexes: [0])` — **no `noteHeightOfRows`** (color only, § 2.12 parity).
- **Fold.** `BlockCellView.mouseDown` → `HitAction.toggleFold(id)` → `delegate.toggleFold(id)` → VC flips `folds[id]`, resolves host `Block.id` (id may be group host OR child), calls `store.invalidateLayout(id: hostBlockId)`, then inside `CATransaction.setDisableActions(true)` + `NSAnimationContext.duration = 0` + `allowsImplicitAnimation = false`: `tableView.noteHeightOfRows(withIndexesChanged: [hostRow])` + `tableView.reloadData(forRowIndexes: [hostRow], columnIndexes: [0])`. Matches § 2.10.
- **Status.** History-only; no live CLI writing status. Dict stays empty; children render `.completed` labels.

### 6.1 RowLayout.make signature

Current shim `RowLayout.make(for:width:)` widens:

```swift
nonisolated static func make(
    for block: Block,
    width: CGFloat,
    folds: [UUID: Bool] = [:],
    statuses: [UUID: ToolStatus] = [:],
    highlights: [Transcript2HighlightKey: HighlightValue] = [:]
) -> RowLayout {
    Transcript2Coordinator.makeLayout(
        for: block, width: width,
        highlights: highlights, folds: folds, statuses: statuses)
}
```

Store's `layout(for:width:folds:statuses:highlights:)` proxies these through.

## 7. Syntax highlight back-fill

`TranscriptHighlightStore` copies `Transcript2HighlightStorage`'s invariants verbatim (§ 2.15):

- `sourceKeys[Key] = fingerprint(payload)` — sub-plans whose fingerprint matches the cached value are skipped (no drop, no JS call, no `onDidFill`).
- `inflightGen[Key]` per-scope (not per-block); every `schedule` targeting a scope bumps that scope's gen; every `drop` bumps every scope on the block; a job compares per-scope gens on completion and discards drift.
- `onDidFill(blockId)` handler on the VC does:
  ```
  store.invalidateLayout(id: blockId)
  if let row = rowFor(blockId) {
      tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
  }
  ```
  **No `noteHeightOfRows`** — highlights change color, not metrics (§ 2.12).

**Late-bind engine.** `TranscriptHighlightStore.init()` takes no engine. `attachEngine(_ engine: SyntaxHighlightEngine)` (idempotent): if the new engine is the same instance we already have, no-op; otherwise attach and internally re-schedule every scope currently in `sourceKeys` so previously-attempted-during-nil-engine scopes fill on next flush. VC calls `attachEngine` in `viewDidLoad`.

Note: this differs from `Transcript2HighlightStorage.setEngine`, which puts the reschedule burden on the caller. The store internalizes it here because the VC has no visibility into which scopes were previously scheduled — semantics equivalent to the old code, just moved. Not "verbatim".

**Schedule cost on `viewFor`.** VC calls `highlightStore.schedule(block:)` only when the cell is being reused for a **new** block id (not on every `viewFor` — the reuse cell may just be repainting due to reload). Concretely: guard with `if cell.blockId != block.id { highlightStore.schedule(block: block); cell.blockId = block.id }`. The store itself also dedupes via the `sourceKeys` fingerprint. Combined, scroll-hot `viewFor` calls pay one dict lookup + one comparison, not a JSCore round trip.

## 8. BlockCellView surgery — delegate protocol (complete)

Every existing `coordinator?.…` site in `BlockCellView*.swift` gets a delegate method. Enumerated from source:

```swift
@MainActor
protocol BlockCellViewDelegate: AnyObject {
    var hoveredBlockId: UUID? { get set }        // BlockCellView.swift:222,223,558,574,575
    var isLiveScrolling: Bool { get }            // BlockCellView.swift:549,556,566
    func toggleFold(id: UUID)                    // BlockCellView.swift:724
    func requestUserBubbleSheet(id: UUID)        // BlockCellView.swift:712 (no-op in impl + log)
    func requestImagePreview(image: NSImage)     // BlockCellView.swift:720 (no-op in impl + log)
    func handleGutter(_ spec: GutterSpec, blockId: UUID)  // BlockCellView+Gutter.swift:171
}
```

`GutterSpec` is already in its own file at `Content/Chat/NativeTranscript2/Layout/GutterSpec.swift` — the protocol references it directly, no code motion needed. VC implementation dispatches to the same "copy content to pasteboard" behavior the old coord had (verified: `Transcript2Coordinator.handleGutter(_:blockId:)` exists at Transcript2Coordinator.swift:1507).

**Renaming rule:** `weak var coordinator: Transcript2Coordinator?` → `weak var delegate: BlockCellViewDelegate?` in `BlockCellView.swift:92`. All 10+ call sites get s/coordinator/delegate/.

The old `Transcript2Coordinator` still exists, is still constructed by `Session.swift`, and still conforms to whatever it needs internally — the ONLY change is `BlockCellView` no longer typed-references it. The old coord becomes a `BlockCellViewDelegate` conformer as a purely additive change (implement the six protocol methods, they already exist as methods on the class).

## 9. Layer boundaries — what is not deleted

- All of `Session.swift`'s render-side wiring (`controller`, `bridge`, `backfillPipeline`) is untouched — pulling those out of `Session` is a separate PR. `Transcript2Controller`, `Transcript2Coordinator`, `Transcript2EntryBridge`, `TranscriptBackfillPipeline`, `Transcript2Search/Selection/SheetPresenter`, `Transcript2Scroll/Clip/TableView`, `TranscriptScrollViewFactory`, `CenteredRowView`, `Transcript2HighlightStorage` — all stay compiled.
- The one required change to the old code: `BlockCellView` types its back-reference as `BlockCellViewDelegate?` instead of `Transcript2Coordinator?`. The old coord adopts the protocol; a one-line `extension Transcript2Coordinator: BlockCellViewDelegate {}` covers it (all six methods already exist as members).

## 10. DI & lifecycle

### 10.1 Composition root

`AppDelegate.applicationWillFinishLaunching`:
```
let transcriptRegistry = TranscriptRegistryStore()
let appContext = AppContext(..., transcriptRegistry: transcriptRegistry)
sessionManager.transcriptRegistry = transcriptRegistry   // for discard(_:)
```

### 10.2 Registry `discard(_:)` wiring

`SessionManager` gets a `weak var transcriptRegistry: TranscriptRegistryStore?` (or the equivalent DI). On `archiveSession(_:)` and `deleteSession(_:)`, calls `transcriptRegistry?.discard(sessionId)`. Without this, the registry grows monotonically — the review's memory-leak finding.

If the specific wiring surface on `SessionManager` doesn't fit, alternative: `TranscriptRegistryStore` subscribes to a Combine `PassthroughSubject<SessionArchivedEvent, Never>` exposed by `SessionManager`. Either way, the wire lands in the same PR as this refactor.

### 10.3 VC init

`TranscriptViewController(store: TranscriptStore, syntaxEngine: SyntaxHighlightEngine)`. Both injected from `DetailContext` in `DetailFlowCoordinator.makeChild(.history)`. VC constructs its own `TranscriptHighlightStore` and calls `attachEngine(syntaxEngine)` in `viewDidLoad`.

### 10.4 Lifetimes

- Registry: process-lifetime. `discard(_:)` on archive/delete only.
- Store: lifetime = its slot in registry. Loader task retains `self` weakly.
- VC: one mount = one VC. `prepareForRemoval()` cancels event subscription + unwires dataSource/delegate. Does **not** cancel the loader — store lives past VC, finishing the stream benefits the next mount.

## 11. Perf parity — line-item against `NativeTranscript2/CLAUDE.md § 2`

| Old invariant | How new keeps it |
|---|---|
| § 2.1 sync `heightOfRow` on cache hit | `store.layout(for:width:…)` is get-or-compute; Phase 1 primes cache before `insertRows`; Phase 2 primes on main hop before `insertRows`. |
| § 2.2 cell `wantsLayer + .onSetNeedsDisplay` | `BlockCellView` unchanged. |
| § 2.3 `.never` layer on scroll + clip | Set on stock `NSScrollView` **and** `TranscriptClipView`. |
| § 2.4 `[UUID: CachedLayout]` no LRU | `TranscriptStore.layouts: [UUID: RowLayout]`; width lives on the store; invalidated wholesale on width change. |
| § 2.5 `nonisolated static makeLayout` | `RowLayout.make` is `nonisolated static`; Phase 2's `Task.detached` calls it. **Caveat:** downstream `XxxLayout.make` implementations have MainActor-isolation warnings in the compiler (per the June build log); these are same on the old code path — parity preserved, not improved. Follow-up: audit those layouts for real thread-safety independent of this refactor. |
| § 2.6 backfill off-main-built + sync-applied | Phase 2 typeset off-main → `MainActor.run` → single-tick `writeLayouts + insertRows`. Cache primed before structural change. |
| § 2.7 in-tick anchor for resize | § 5.5 `viewDidEndLiveResize` handler forces `tableView.layoutSubtreeIfNeeded()` after `noteHeightOfRows` inside the disabled transaction. |
| § 2.8 live-resize touches visible rows only | § 5.5 reads `tableView.rows(in: tableView.visibleRect)`. |
| § 2.9 negative-width clamp | `TranscriptClipView.setFrameSize` clamps `max(0, w), max(0, h)`. |
| § 2.10 suppress implicit animations | Fold/hover/highlight reload paths wrap in `NSAnimationContext.duration = 0 + allowsImplicitAnimation = false + CATransaction.setDisableActions(true)`. |
| § 2.11 no `reloadData()` | VC never calls `reloadData()`. Uses `insertRows`, `noteHeightOfRows`, `reloadData(forRowIndexes:columnIndexes:)`. |
| § 2.12 highlight refill skips `noteHeightOfRows` | § 7. |
| § 2.13/b search / status | Search deferred (§ 14). Status kept as sparse dict → same channel as old. |
| § 2.14 anti-poison in `cacheLayouts` | § 5.3 stale-width drop + block-still-live guard. |
| § 2.15 per-scope dedup + gen guard | `TranscriptHighlightStore` mirrors invariants verbatim (§ 7). |
| § 2.16 shimmer overlay | Cell code unchanged. |
| § 2.17 stable row-reuse key | `BlockCellView` registered under identifier `"TranscriptBlockCell"`. |
| § 2.18 stable `Block.id` | `MessageEntryBlockBuilder` unchanged. |
| § 2.19 one width per attach | § 5.4 two-step attach — dataSource binds only after `layoutSubtreeIfNeeded` on the first framed `viewDidLayout`; events sink installs after the warm-entry tile so no delta bypasses the settled-width path. |

### 11.1 Phase 1 first-frame timing

Both Phase 1 (`.tail`) and Phase 2 (`.older`) run typeset off-main via `Task.detached` (§ 5.2). First paint is not instantaneous — there is a one-hop delay (SDK yields → MainActor.ingest → detached typeset → MainActor apply → runloop tick → paint). Perceptually ~one frame of blank pane before content lands; matches old backfill pipeline behavior.

**Why not Phase 1 sync-on-main?** An earlier plan draft did this for "first-frame determinism". It was wrong: a tail message can carry a fileEdit tool result with a 500-line diff, whose synchronous `DiffLayout.make` typeset freezes for hundreds of milliseconds. § 2.6 explicitly forbids on-main typeset for cold history load; going sync on Phase 1 would violate that invariant. The one-hop delay is the correct tradeoff.

## 12. Testing

- **New**: `TranscriptStorePhaseTests` — fake SDK stream, assert (1) first non-empty batch emits `.tail` and subsequent emit `.older`; (2) `blocks` accumulates in document order; (3) `layouts.count == blocks.count` after each Phase 1 apply and after each Phase 2 write.
- **New**: `TranscriptClipViewCenteringTests` — instantiate the clip, install a documentView of width 500, drive `constrainBoundsRect` at proposed widths 800 / 500 / 300, assert `origin.x` values (`-150 / 0 / 0` respectively) and that vertical passes through.
- **New**: `TranscriptViewControllerAttachOrderTests` — construct VC, force `viewDidLoad` then `viewDidLayout` in sequence, assert dataSource is `nil` after `viewDidLoad` and set after `viewDidLayout`. Assert that the events sink is only installed post-attach, so a store mutation between `viewDidLoad` and `viewDidLayout` is picked up by the warm-entry tile (not by a duplicate delta apply).
- **New**: `TranscriptHighlightStoreTests` — fingerprint dedup returns cache hit; late-bind `attachEngine` reschedules pending scopes; per-scope gen guard drops stale writebacks.
- **Removed / N/A**: v1 plan cited `TranscriptReentryLayoutCacheTests` as an existing merge gate — that file does **not** exist in `macos/cctermTests/`. The `AttachOrderTests` above replaces the intended coverage.

## 13. Rollout

1. Add `TranscriptClipView` + `BlockCellViewDelegate` + `TranscriptHighlightStore`.
2. Widen `RowLayout.make` signature (§ 6.1).
3. Refactor `BlockCellView` (`coordinator → delegate`); extend `Transcript2Coordinator` with the protocol conformance (one-line extension).
4. Rewrite `TranscriptStore` + `TranscriptViewController` per this doc.
5. Wire `discard(_:)` in `SessionManager` (§ 10.2).
6. Build clean; run new tests; manually test sidebar switch-back for cache warmth + resize + fold interaction.
7. Follow-up PR: rip the old renderer stack out of `Session.swift`.
8. Follow-up PR: bring back top/bottom scrims on the history VC.
9. Follow-up PR: user-bubble sheet + image preview sheets + in-transcript search.

## 14. Out of scope

- User-bubble full-text sheet and image-preview sheet (`BlockCellViewDelegate.requestUserBubbleSheet` / `requestImagePreview` log at `.info` and no-op). Documented as visible UX gap.
- In-transcript ⌘F search.
- Cross-row selection.
- Removal of the old renderer stack from `Session.swift`.
- Top/bottom scrim overlays.

Every out-of-scope item is a follow-up PR — none precludes the others.
