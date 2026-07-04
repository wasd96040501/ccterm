# Transcript refactor — history-only, session-agnostic (v6)

Status: proposal (pre-implementation), v10 (v9 + push tool-pair to SDK · forward builder only · drop `MessageEntry` intermediate · Phase 1 off-main · snapshot terminology cleanup · § 3 naming rule).

Scope: rewrite the history transcript viewer along the top-level `CLAUDE.md` MVVM-C conventions. **v5 shipped a Store↔VC coupling that leaked async plumbing (Combine subject + serialized apply chain + row-count mirror + `isReleased` guard) — all of it was self-inflicted complexity, not required by AppKit or the SDK.** v6 rewrites the data path around one primitive: a for-await loop in the VC that awaits a `Task.detached` typeset and commits row inserts in the same MainActor tick. No mirror, no chain, no Combine, no guard.

Kept from v5: layout parity (460..780 centered), naming compliance, § 2 perf items, `RowLayout` + `BlockCellView` code as-is (minor delegate rename only), attach § 2.19 contract shape.

Rewritten: SDK history API (adds sync + cursor), Store shape (no events subject, no loader — pure data + cache), VC (owns loader Task, drives commit directly).

Not in scope: pulling the old renderer stack out of `Session.swift` (separate PR); user-bubble / image-preview sheets; in-transcript ⌘F search; cross-row **selection** (separate PR — style parity is this PR's focus); top/bottom scrim overlays.

## 0. The single invariant everything else falls out of

> **Data mutation and `tableView.insertRows` must land in the same MainActor tick.**

If this holds, every one of v5's "helper" mechanisms becomes unnecessary:

- Because mutation and `insertRows` share a tick, `store.blocks.count` and `tableView.numberOfRows` are consistent at every dataSource query → **no `visibleBlocks` mirror**.
- Because a for-await loop's body runs synchronously between awaits — and `await Task.detached { … }.value` returns to the same actor — one page's commit finishes before the next `stream.next()` returns → **no `applyChain`**.
- Because there is no cross-tick delta to propagate, the Store doesn't need to publish events → **no Combine subject, no `.receive(on:)`**.
- Because `Task.cancel()` throws `CancellationError` from the next `try await` (and from explicit `Task.checkCancellation()` around detached work), the loop exits cleanly on VC teardown → **no `isReleased` flag on every commit path**.

**Violating this invariant re-invites all four.** v5 violated it — Store mutated `blocks[]` synchronously inside `events.send(...)`, VC applied `insertRows` after an off-main typeset hop-back. To patch the resulting inconsistency window, v5 grew a mirror, a chain, a subject, and a flag. **Every subsection below is checked against this rule.**

## 1. Goals

1. **Session-agnostic transcript.** Read by `transcriptId: String`; nothing about `Session` / `SessionRuntime`. State lives in an app-scope registry so sidebar switch-back paints instantly.
2. **First-screen sync, subsequent pages async.** SDK exposes a **sync** `loadPage` + **async** `stream`, both cursor-based. First page reads on main (local file, ~64 KB, <10 ms typical), typesets on main, hits the table with data-already-there — zero blank-pane flash. Older pages stream from the cursor via `Task.detached`, typeset off-main, commit main.
3. **Layering per top-level `CLAUDE.md`.** Store owns data + cache + cursor; VC owns lifecycle + dataSource + delegate + loader Task; Registry lives at the composition root. Data down, events up. **No ViewModel** — there is no derivation step between `Block` and what a cell renders (that step IS `RowLayout.make`, which is a pure function called by the delegate at query time). Adding a VM here would be layer for its own sake.
4. **Perf parity with the old renderer** on every § 2 item — see § 11.
5. **Layout parity.** Content clamped to `[BlockStyle.minLayoutWidth, BlockStyle.maxLayoutWidth] = [460, 780]` and horizontally centered inside a full-width scroll view; the old `TranscriptScrollViewFactory.contentInsets` — `top: 56, bottom: 112` — reused verbatim.
6. **Interaction parity for style.** Hover title-brightening, tool group / child fold, syntax highlight back-fill on `.codeBlock` + `fileEdit` diff lineMap. Selection is deferred to a follow-up PR (§ 14).
7. **Naming compliance.** Every new type carries a listed role suffix (`View` / `Controller` / `Store` / `Delegate`). No `Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Adapter` / `Coordinator` in the new stack. (The old `Transcript2Coordinator` name is not adopted by anything new — it's a legacy mis-name we don't propagate.)

## 2. Components — new only

| Component | Role | Function | Downward dependencies |
|---|---|---|---|
| `TranscriptStore` | Store | Pure data + cache holder. Owns `blocks: [Block]`, `layouts: [UUID: RowLayout]`, `layoutsWidth: CGFloat`, `folds: [UUID: Bool]`, `statuses: [UUID: ToolStatus]`, `highlights: TranscriptHighlightStore`, `nextCursor: SessionHistory.Cursor?`, `didLoadFirstPage: Bool`, `didFinishLoad: Bool`, `builder: MessageBlockBuilder`. **No loader Task**, **no events subject**, **no Combine**. Sync mutation API — each verb names an act, not an implementation detail (§ 3 naming rule): `loadFirstScreenSync(viewportHeight:width:)` (§ 5.1.1), `prependOlderBlocks(_:nextCursor:)` (prepend blocks + set cursor; `nextCursor == nil` auto-flips `didFinishLoad`), `setLayoutWidth(_:)` (idempotent: no-op if already at that width; otherwise clears the cache and updates `layoutsWidth`), `cacheRowLayouts(_:atWidth:)` (bulk-populate cache from off-main typeset; width-guard + anti-poison), `invalidateRowLayout(id:)`, `toggleFold(id:) -> UUID?`. Read API: `layout(for:width:folds:statuses:highlights:) -> RowLayout` (get-or-compute), plus direct `blocks` / cache reads. | `SessionHistory` (types only) / `MessageBlockBuilder` / `RowLayout.make` / `Block` / `RowLayout` |
| `MessageBlockBuilder` | Builder (transient stateful transformer) | **Single builder, single direction (forward).** `Message2` → `[Block]`. `mutating ingest(_:) -> [Block]`, `mutating finish() -> [Block]`. Internal state = `openGroupItems` (buffered groupable-assistant run). **No `withheld` tool_result buffer — SDK owns pairing** (§ 2 SDK row). **`nonisolated struct`** — no `@MainActor`, no UI types. Runnable on any executor: Phase 1 goes off-main via `Task.detached` (§ 5.2). **Traversal direction is a stream-layer concern, not a builder concern** — v9's `Reverse*Builder` name was the tail wagging the dog. The history path feeds the builder forward-ordered pages the SDK yields (each page already forward-ordered internally, tool-pairs complete); a future live-path refactor can use the exact same builder by feeding messages one at a time as the CLI streams them. | `Message2` / `Block` / `isGroupableAssistant` predicate |
| `TranscriptRegistryStore` | Store | App-scope `[transcriptId: TranscriptStore]`; `store(for:) -> TranscriptStore` get-or-create; `discard(_:)` wired to `SessionManager.archive` via `onSessionArchived` closure. | `TranscriptStore` |
| `TranscriptHighlightStore` | Store | Per-scope tokens cache with fingerprint dedup + per-scope generation guard. **Adds real behavior over `Transcript2HighlightStorage`** (not a rename-only shim — v7 review #10): (a) idempotent `attachEngine(_:)` internalizes the reschedule burden — v5's caller had to remember every scope it ever asked about; wrapper tracks `seen: [UUID: Block]` and replays on nil→non-nil transition; (b) O(1) full-dict `snapshot()` for MainActor→detached typeset capture (Swift dicts are COW; the read is a reference-count bump, not a copy) — avoids v5's per-block filter that turned scroll-hot lookups into O(N × visible-rows). **Owned by `TranscriptStore`, not by VC** — highlights survive sidebar switch-away like blocks and layouts do. | `SyntaxHighlightEngine` / `Block` (delegates dedup + gen-guard invariants to existing `Transcript2HighlightStorage`) |
| `TranscriptClipView` | View | `NSClipView` subclass. `constrainBoundsRect(_:)` centers a documentView narrower than the clip (`origin.x = floor((proposedBounds.width - docWidth) / -2.0)`; else pass through). `setFrameSize(_:)` clamps negative widths (§ 2.9). Vertical passes through. | — |
| `BlockCellViewDelegate` | Delegate | `@MainActor` class-only protocol. Every current `coordinator?.…` site in `BlockCellView*.swift` gets a method — see § 8. | — |
| `TranscriptViewController` | Controller | `NSViewController` + `NSTableViewDataSource` + `NSTableViewDelegate` + `BlockCellViewDelegate` + `DetailContainerChild`. **Owns the background loader Task**. dataSource callbacks read `store.blocks` **directly** (no mirror — mutation and `insertRows` land in the same `await`-return tick). Two-step attach: `viewDidLoad` wires delegate + attaches highlight engine; `viewDidLayout` first-pass runs `layoutSubtreeIfNeeded` → seeds width → **sync first-page** → `dataSource = self` → warm tile → `scrollRowToVisible` at tail → starts background loader. On `prepareForRemoval`: `loaderTask?.cancel()` — for-await loop's next `await` throws `CancellationError`, loop exits; no post-teardown guard needed. | `TranscriptStore` / `TranscriptClipView` / `BlockCellView` / `BlockCellViewDelegate` / `Block` / `RowLayout` / `BlockStyle` / `SyntaxHighlightEngine` / `SessionHistory` |
| **`AgentSDK.SessionHistory` (extended)** | SDK | Cursor-based API. `Cursor` = opaque byte-offset. `Page { messages: [Message2]; nextCursor: Cursor? }`. **Sync** `loadPage(id:cursor:) throws -> Page` reads one chunk (~64 KB) synchronously, decodes, returns messages **forward-ordered within the page** (SDK reverses the byte-walk order at page boundary so the app never sees reverse-per-page ordering). `nextCursor` is the next-older byte position or nil at file top. **Async** `stream(id:cursor:) -> AsyncThrowingStream<Page, Error>` — demand-driven producer via `AsyncStream(unfolding:)`-style iterator; `next()` triggers exactly one `loadPage`; producer polls `Task.checkCancellation()`. **SDK owns cross-page tool-result pairing** (v10 correction — v6 was wrong to push it to the app): when the reverse byte-walk encounters an orphan `tool_result` whose `tool_use` hasn't been read yet, SDK withholds it in `_WithheldTools: [String: Message2]` (keyed by `tool_use_id`); when a later (older) page yields the matching `tool_use`, SDK inserts the withheld `tool_result` into that page's forward-ordered message list right after its `tool_use`. **Every yielded page is a self-contained forward-ordered slice with complete tool pairs.** App-side receives clean data — no `withheld` state, no direction awareness. The v5 `SessionHistory.load(id:order:)` **is removed**. | Existing SDK internals (`_ReverseLineReader` / `Message2Resolver`) |

Explicitly **NOT** in the new stack:

- **No `visibleBlocks` mirror.** dataSource returns `store.blocks.count`. Loader mutates `store.blocks` inside the same MainActor tick as `tableView.insertRows` — see § 5.
- **No `applyChain: Task<Void, Never>?`.** The loader's for-await loop is the serialization — one page's commit completes (main) before `await` on the next page's typeset returns.
- **No `Combine.PassthroughSubject` / `.receive(on:)` in the Store→VC path.** The loader is a Task the VC owns; commit is a direct method call on `self` inside the loop body.
- **No `isReleased: Bool` flag.** Cancelling the loader Task at `prepareForRemoval` throws `CancellationError` from the next `for-await` step; the loop exits cleanly. Any Task.detached typeset already in flight completes and its return value is discarded — `Task.checkCancellation()` after the await handles the post-typeset gate (§ 5.2).
- **No `ViewModel` layer.** `RowLayout.make(for:width:…)` IS the derivation step. Inserting a VM would either be a pass-through wrapper (adds nothing) or would duplicate the layout function (adds bugs).

Reused as-is (no code motion): `Block`, `RowLayout`, all `XxxLayout.make`, `BlockCellView` (with the `coordinator → delegate` rename below only), `BlockStyle`, `SyntaxHighlightEngine`, `AppContext.transcriptRegistry` slot, `AppDelegate` registry construction, `DetailContext.transcriptRegistry` propagation, `DetailFlowCoordinator.makeChild(.history)` short-circuit, `Transcript2HighlightStorage` (wrapped as internal by `TranscriptHighlightStore`), `isGroupableAssistant` predicate (extension on `Message2`).

**Not reused for the history path (still compiled for live path):** `ReverseEntryBuilder`, `MessageEntryBlockBuilder`, `MessageEntry` type. Live path continues to use them; history path uses only the new `MessageBlockBuilder` in one shot.

## 3. Naming compliance

- **Role suffix only.** `View` / `Controller` / `Store` / `Delegate`. No `Adapter` / `Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Coordinator`. `Storage` → `Store`. `Builder` is allowed for transient stateful transformers (idiomatic Swift, matches existing usage — but reasons **must** be structural, not "we already had one").
- **No numeric suffix on new types.** No `Transcript2Xxx`.
- **Data types have no suffix.** `Block`, `RowLayout`, `HighlightValue`, `Message2` are existing suffix-free types; retained.
- **Directory = feature.** All new files live under `macos/ccterm/Content/Chat/Transcript/`.

### 3.1 Name by structure, not by caller / context / source

The three worst renames this doc has been through (`ReverseEntryBuilder → HistoryBlockBuilder → ReverseMessageBlockBuilder → MessageBlockBuilder`; `applyFirstPage → loadFirstScreenSync`; `visibleBlocks` mirror in the VC) all started by naming from **who calls it** or **where I copied it from**, then had to be renamed once the design settled. The rule that would have caught all three at write-time:

> **A name has to describe what the thing IS in isolation, not what its current caller expects it to do.** If deleting the surrounding code makes the name meaningless, it's a bad name.

Concretely:

| ❌ Named by | Real answer | ✅ Named by |
|---|---|---|
| `HistoryBlockBuilder` | Transforms `Message2 → [Block]`; direction is a caller concern | `MessageBlockBuilder` |
| `ReverseMessageBlockBuilder` | Traversal direction lives in SDK (byte-walk), not in the builder | `MessageBlockBuilder` |
| `visibleBlocks` mirror in VC | Second source of truth that only existed because Store's mutation and VC's insertRows landed in different ticks | Nothing — mutation and insertRows share a tick (§ 0), the mirror doesn't exist |
| `applyFirstPage(_:)` | "Apply" is a verb without a direct object — apply what? A page? A batch? To where? | Subsumed into `loadFirstScreenSync` which describes the act |
| `seedWidth(_:)` / `retargetWidth(_:)` | Both were "set the layout width and wipe stale cache if it changed" | Merged into `setLayoutWidth(_:)` |
| `cacheRowLayouts(_:width:)` | "Write" is a plumbing verb (write to disk? write to memory?). Actual act = populate the layout cache | `cacheRowLayouts(_:atWidth:)` |
| `prependOlder(_:newCursor:)` + `advanceCursor(to:)` + `markFinished()` | Three names for the three cases of "we processed some (or zero) older blocks, here's the next cursor (nil = at file top)" | One name: `prependOlderBlocks(_:nextCursor:)` |
| `applyOlderBatch(blocks:nextCursor:)` (v10 first attempt) | "apply" is a vague verb (§ 3.2 smell test); "batch" describes size, not what's being batched | `prependOlderBlocks(_:nextCursor:)` |
| `startBackgroundLoader()` | "background" is a runtime attribute (thread/tick), not a description of the act | `startOlderPagesLoader()` |
| `commitOlder(blocks:pairs:width:newCursor:)` (VC method) | "commit" is a DB verb; the actual UI act is inserting rows at top of the table | `insertOlderBlocksAtTop(_:cachedLayouts:atWidth:nextCursor:)` |
| `runStructuralUpdate(_:)` | "structural" is a category name, not an act; hides what's actually happening (implicit animations suppressed) | `withoutImplicitAnimations(_:)` |
| `performLiveResizeFrame(newWidth:)` | "perform...frame" — window frame? runloop frame? both plausible | `handleLiveResizeTick(newWidth:)` |
| `performWidthChange(newWidth:)` | "perform" is a vague framing verb | `retileAtNewWidth(_:)` |
| `cacheLayouts` / `invalidateLayout` / `layout(for:width:...)` | "layouts" is under-specified — layouts of what? | `cacheRowLayouts` / `invalidateRowLayout` / `rowLayout(for:...)` |
| `handleHighlightFilled(id:)` | "handle" + past-participle event name is Cocoa-style callback; hides the act (which is: refresh one row) | `refreshRowForHighlight(_:)` |
| `schedule(block:)` (HighlightStore) | "schedule" what? Highlighting for that block | `scheduleHighlighting(for:)` |

### 3.2 Two smell tests before adding a name

- **Delete the context.** If I hand a fresh reader the type/function signature alone with no surrounding code, can they say what it does? If the name only makes sense next to its call site, rename it.
- **Verb first, target second.** For method names, the verb is the ACT (`cache`, `set`, `apply`, `refresh`, `invalidate`, `toggle`, `load`), never the implementation detail (`write`, `seed`, `retarget`, `commit`, `handle`). The target is what's being acted on (`Layouts`, `LayoutWidth`, `OlderBatch`, `RowForHighlight`, `Fold`).

## 4. Layout — 460..780 band centered in full-width scroll

### 4.1 Why `TranscriptClipView` (not Auto Layout alone)

Auto Layout on the documentView alone will **not** center it. `NSClipView.constrainBoundsRect(_:)` clamps `bounds.origin.x` to make a narrow documentView flush-left when the documentView is narrower than the clip — that's Apple's documented behavior. Subclassing `NSClipView` to reverse that clamp is the canonical fix (verified against Apple docs + community writeups). No trick — this is the recommended pattern.

### 4.2 View hierarchy

Constructed in `TranscriptViewController.loadView()`:

```
TranscriptViewController.view                NSView         full-pane
 └ NSScrollView (host)                       stock
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              § 2.3
    · hasVerticalScroller = true; autohidesScrollers = true
    · hasHorizontalScroller = false
    · scrollerStyle = .overlay
    · drawsBackground = false; borderType = .noBorder
    · automaticallyAdjustsContentInsets = false
    · contentView = TranscriptClipView()                              MUST assign BEFORE contentInsets
    · contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
    Constraints: 4-edge pin to view
 └ TranscriptClipView (contentView)          subclass
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              § 2.3
    · constrainBoundsRect: horizontal center when documentView narrower
    · setFrameSize: max(0, w), max(0, h)                              § 2.9 negative-width clamp
 └ NSTableView (documentView)                stock
    · headerView = nil
    · backgroundColor = .clear
    · style = .plain
    · selectionHighlightStyle = .none                                 (§ 14 defers real selection to next PR)
    · gridStyleMask = []
    · usesAutomaticRowHeights = false; rowSizeStyle = .custom
    · intercellSpacing = .zero
    Auto Layout:
      · widthAnchor ≤ BlockStyle.maxLayoutWidth (780)          required
      · widthAnchor ≥ BlockStyle.minLayoutWidth (460)          required
      · widthAnchor == clip.widthAnchor priority .defaultLow   hug clip inside band
      · topAnchor == clip.topAnchor
      · Height driven by intrinsic content size (rows sum) — no bottom pin
    Single column:
      · identifier = "block"
      · resizingMask = [.autoresizingMask]
      · minWidth = 0; maxWidth = .greatestFiniteMagnitude
 └ NSTableRowView                            stock, but pooled via a reuse identifier — see below
 └ BlockCellView                             reused. Reuse identifier: "TranscriptBlockCell"
    (bounds.width ∈ [460, 780])

VC also implements `tableView(_:rowViewForRow:) -> NSTableRowView?` (v7 review #4 fix — matches § 2.17):

    let id = NSUserInterfaceItemIdentifier("TranscriptBlockRow")
    if let v = tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView { return v }
    let v = NSTableRowView()
    v.identifier = id
    return v

Without this, NSTableView allocates fresh row views per scroll tick (§ 2.17 regression). The row view itself is stock — the `BlockCellView` inside does the drawing.
```

### 4.3 BlockCellView needs no centering change

`BlockCellView.layoutOrigin.x = BlockStyle.cellOriginX(forRowWidth: bounds.width) + blockHorizontalPadding`. When `bounds.width ∈ [460, 780]`, `cellOriginX` returns 0 (no per-cell centering — the clip already centered the table). `layoutOrigin.x` collapses to the constant `blockHorizontalPadding`.

### 4.4 Live resize behavior

- Clip < 460 → `widthAnchor ≥ 460` wins; table stays 460; horizontal scroller off → clips at edges (accepted; matches old behavior).
- Clip ∈ [460, 780] → `widthAnchor == clip.widthAnchor` at low priority wins; table hugs clip.
- Clip > 780 → `widthAnchor ≤ 780` wins; table stays 780; clip re-centers via subclass.

## 5. Data flow

```
~/.claude/projects/<id>.jsonl                    (CLI-written file)
    │
    │  cursor = nil (first page) → cursor = page.nextCursor → …
    ▼
SessionHistory.loadPage(id:cursor:order:.reverse)  SYNC — first screen only
    · Task-less; blocks main; ≤ 10 ms typical for one 64 KB page
    · Returns Page { messages, nextCursor }
    ▼
Store.loadFirstScreenSync(viewportHeight:width:)  MainActor sync — bounded by viewport height (§ 5.1.1)
    · for each page returned by SessionHistory.loadPage:
        - forward-order messages fed to store.builder (MessageBlockBuilder)
        - builder emits Blocks (nonisolated, direction-agnostic)
        - per-block sync typeset via store.rowLayout(for:width:...) — warms cache, sums height
    · cross-page group merge (§ 5.1.2) at each page boundary
    · terminates when Σ heights ≥ viewportHeight OR page.nextCursor == nil (file top)
    ▼
TranscriptViewController.viewDidLayout — first pass
    · setLayoutWidth → dataSource = self → layoutSubtreeIfNeeded → scrollRowToVisible(last)
    · startOlderPagesLoader()   ── fires ONLY if store.nextCursor != nil
    │
    ▼
SessionHistory.stream(id:, cursor: store.nextCursor)   ASYNC (Task.detached inside SDK)
    · yields AsyncThrowingStream<Page, Error>
    · Task.detached: each iteration = one loadPage synchronously off-main
    │  · SDK's _WithheldTools ensures every yielded page has complete tool_use↔tool_result pairs
    ▼
VC's loader Task = for try await page in stream { … }        MainActor
    Phase 1  · for m in page.messages { blocks += store.builder.ingest(m) }   (main)
             · blocks += store.builder.flushOpen()                           (main; page boundary)
             · merge group at boundary if needed (§ 5.1.2)                    (main)
    Phase 2  · let pairs = await Task.detached { blocks.map … RowLayout.make(…) }.value   (off-main)
    Commit   · withoutImplicitAnimations {                                   (main, one runloop tick)
                  captureAnchor()
                  store.prependOlderBlocks(blocks, nextCursor: page.nextCursor)
                  store.cacheRowLayouts(pairs, atWidth: w)
                  tableView.beginUpdates()
                  tableView.insertRows(at: 0..<n, withAnimation: [])
                  tableView.endUpdates()
                  restoreAnchor()
              }
    (next iteration; loader Task keeps running until stream ends or Task.cancel())
```

Key invariants of this shape:

- **Serialization** comes from the for-await loop itself. One page finishes committing before the next `await` on `stream.next()` returns. No `applyChain` needed.
- **VC-Store-Table consistency in one tick.** `store.prependOlderBlocks` and `tableView.insertRows` execute in the same MainActor tick, both inside `withoutImplicitAnimations`. `store.blocks.count` and `tableView.numberOfRows` are consistent every time dataSource is queried. No `visibleBlocks` mirror needed.
- **Cancellation** is a natural fall-out: `loaderTask?.cancel()` in `prepareForRemoval` throws `CancellationError` at the next `try await stream.next()`. `Task.checkCancellation()` after the detached typeset closes the "typeset completed after VC teardown" window (§ 5.2). No `isReleased` guard needed.
- **No Combine.** VC owns the Task and the commit closure directly.

### 5.1 First-screen sync — height-based termination

The v5 plan mandated Phase 1 typeset off-main to preserve § 2.6 ("backfill off-main-built"). v9 splits into two paths:

**First page (sync on main):**
1. `SessionHistory.loadPage(cursor: …)` — file read + JSON decode. Local file, one 64 KB page → typical read + decode 3–8 ms.
2. `store.builder.ingest(_:)` — nonisolated call (builder is direction-agnostic, no MainActor requirement), block build ~1 ms for ~50 messages.
3. **Per-block sync typeset inside the loop** — for each block just built, call `store.layout(for: b, width: w, …)`. This both fills the layout cache AND yields the block's total height. Accumulate `heightSoFar` and STOP when `heightSoFar >= viewportHeight` (or when file top is reached, whichever first).
4. `dataSource = self` + `tableView.layoutSubtreeIfNeeded()` — tile visible rows. `heightOfRow` now returns cache hits by construction (step 3 already primed them). **Zero on-main typeset during the tile pass** — cleanest possible § 2.19 attach contract.

**Older pages (async off-main typeset):**
The old renderer's § 2.6 rule ("backfill off-main-built") applies here. Older pages come from `stream`, iterated by the VC's loader Task; typeset runs in `Task.detached`; commit main. Same off-main-built + main-sync-applied contract.

#### 5.1.1 Height-based termination — the whole loop

```swift
func loadFirstScreenSync(viewportHeight: CGFloat, width: CGFloat) throws {
    guard !didLoadFirstPage else { return }
    setLayoutWidth(width)                                            // idempotent — no-op if unchanged
    let hi = highlights.snapshot()
    var cursor: SessionHistory.Cursor? = nil
    var accumulated: [Block] = []
    var heightSoFar: CGFloat = 0

    while heightSoFar < viewportHeight {
        // SDK yields the page forward-ordered internally, with tool-pairs
        // complete (§ 2 SDK row). App-side builder is direction-agnostic.
        let page = try SessionHistory.loadPage(id: transcriptId, cursor: cursor)
        var pageBlocks: [Block] = []
        for m in page.messages { pageBlocks.append(contentsOf: builder.ingest(m)) }
        if page.nextCursor == nil {
            pageBlocks.append(contentsOf: builder.finish())          // flush open group at file top
            didFinishLoad = true
        }

        // Cross-page group merge (§ 5.1.2): if the newest block of the newer
        // page (accumulated[0]) and the oldest block of this older page
        // (pageBlocks.last) both belong to the same open group, merge them.
        if !pageBlocks.isEmpty, !accumulated.isEmpty {
            mergeGroupAtBoundary(older: &pageBlocks, newer: &accumulated)
        }

        // Per-block sync typeset — populates cache, sums the terminate check.
        if !pageBlocks.isEmpty {
            let inserted = pageBlocks
            accumulated.insert(contentsOf: inserted, at: 0)
            for b in inserted {
                let l = layout(
                    for: b, width: width,
                    folds: folds, statuses: statuses, highlights: hi)
                let pad = BlockStyle.blockPadding(for: b.kind)
                heightSoFar += pad.top + l.totalHeight + pad.bottom
            }
        }

        if page.nextCursor == nil { break }                          // file top
        cursor = page.nextCursor
    }
    blocks = accumulated
    nextCursor = didFinishLoad ? nil : cursor
    didLoadFirstPage = true
}
```

#### 5.1.2 Cross-page group merge

A groupable-assistant run can straddle a page boundary. The SDK doesn't align pages to group boundaries (that would leak app rendering semantics into a byte-oriented reader). App-side handles it at prepend time:

```swift
private func mergeGroupAtBoundary(older: inout [Block], newer: inout [Block]) {
    guard case .toolGroup(var olderTail)  = older.last?.kind,
          case .toolGroup(let newerHead)  = newer.first?.kind,
          !olderTail.children.isEmpty, !newerHead.children.isEmpty
    else { return }
    // The older page's tail-block (oldest-in-page: forward order last) and
    // the newer page's head-block (newest-in-page: forward order first)
    // both being a toolGroup with contiguous child ids means they're the
    // same open run split across the seam.
    olderTail.children.append(contentsOf: newerHead.children)
    older[older.count - 1] = Block(id: older.last!.id, kind: .toolGroup(olderTail))
    newer.removeFirst()
}
```

**Correctness of the merge check** rests on one invariant: **a group is a maximal run of consecutive `isGroupableAssistant` messages** (per `ReverseEntryBuilder` and `SessionRuntime.appendToTimeline`, both share this predicate). So if the older page's last block AND the newer page's first block are both `.toolGroup`, they must be part of the same run (adjacent + both groupable ⇒ same maximal run by definition). Non-groupable messages at either boundary produce singles or close prior groups, and the merge check's `both are .toolGroup` gate correctly skips these cases.

The builder's `finish()` is called at the end of each page's `ingest` loop — but ONLY at the true file top for the sole "final flush any residual open group" purpose. At intermediate page boundaries, we DON'T call `finish()`; instead, the builder's internal `openGroupItems` is drained by explicit synthesis: right before we move on to the next page, call `builder.emitOpenGroupSoFar() -> [Block]` which emits (but doesn't reset internal state — see next paragraph). No — actually simpler: **the builder emits ALL open groups at the end of each ingest sequence via a per-page `flushOpen() -> [Block]` call.** It resets its internal state before the next page. The cross-page merge in `mergeGroupAtBoundary` then reconstructs continuity from the emitted blocks. This keeps the builder itself simple (no cross-page state).

Compact builder shape:

```swift
struct MessageBlockBuilder {                            // nonisolated, Sendable
    private var openGroupItems: [Message2] = []
    mutating func ingest(_ m: Message2) -> [Block] { … }   // may emit prior open group + m
    mutating func flushOpen() -> [Block] { … }              // page boundary: emit residual open, reset
    mutating func finish() -> [Block] { flushOpen() }       // file top: same
}
```

**Termination is derived from the actual goal**, not from a heuristic:
- `heightSoFar >= viewportHeight` — we've built enough to fill the visible pane.
- `page.nextCursor == nil` — file top; nothing else exists to build.

Both branches naturally terminate. **No `maxPages` cap. No `deadline` heuristic.** The v7/v8 draft carried both as "safety" bounds; the v9 rejection is deliberate — the pathological session shape (entire file is one open groupable-assistant run with no closer) would freeze main for seconds to walk the whole file synchronously, but the alternative (bail out at N pages and hand off to async) is equally bad — the user waits either way, and hands-off-to-async means seeing an empty pane then a delayed paint instead of one longer wait for a full paint. Removing the cap means: rare-worst-case is one longer wait; typical-case is faster (no over-read); logic is simpler (one termination criterion instead of three).

**Practical envelope:**
- Typical session (first page fills the screen): 1 page read + ~15–20 blocks typeset ≈ **20–50 ms**.
- Tool-heavy tail (needs 2–3 pages to find enough visible-height content): ~40–80 ms.
- Very tall first message (500-line fileEdit diff): 1 page read + 1 block typeset ≈ **10–30 ms** — the diff alone exceeds `viewportHeight`, we stop after one block, `heightOfRow` is a cache hit for that one row on tile pass.
- Rare-worst-case (entire file is one open group run): sync walk to file top. Could be seconds on a 10 MB file. Accepted; adding a bail-out doesn't improve UX.

Justification for sync-on-main here: § 2.6's target was "long cold-load doesn't freeze the UI"; that concern applies to older-page catchup (which can traverse thousands of blocks). First-screen is bounded by the viewport, not the file — one screen worth of blocks, whatever that is for the current window height. Freezing for ~30 ms on session open beats one-frame-late paint. And because per-block typeset lands in the cache before `dataSource = self`, the § 2.19 attach contract is held by construction — the first `heightOfRow` call is a pure cache lookup.

### 5.2 Loader Task — off-main typeset + main-tick commit

```swift
private func startOlderPagesLoader() {
    guard loaderTask == nil,
        let startCursor = store.nextCursor
    else { return }
    let tid = store.transcriptId
    loaderTask = Task { @MainActor [weak self] in
        do {
            let stream = SessionHistory.stream(id: tid, cursor: startCursor, order: .reverse)
            for try await page in stream {
                try Task.checkCancellation()
                guard let self else { return }

                // Phase 1: MainActor build.
                var blocks: [Block] = []
                for m in page.messages { blocks.append(contentsOf: self.store.builder.ingest(m)) }
                blocks.append(contentsOf: self.store.builder.flushOpen())   // page-boundary flush
                self.mergeGroupAtBoundary(older: &blocks, newer: &self.headSnapshot())
                guard !blocks.isEmpty else {
                    self.store.prependOlderBlocks([], nextCursor: page.nextCursor)
                    continue
                }

                // Phase 2: off-main typeset. Snapshot state on MainActor before dispatch.
                let w = self.store.layoutsWidth
                let folds = self.store.folds
                let statuses = self.store.statuses
                let hi = self.store.highlights.snapshot()
                let pairs = await Task.detached(priority: .userInitiated) {
                    blocks.map { b in
                        (b.id, RowLayout.make(
                            for: b, width: w,
                            folds: folds, statuses: statuses, highlights: hi))
                    }
                }.value

                try Task.checkCancellation()
                // Commit — same MainActor tick as the await return.
                self.insertOlderBlocksAtTop(
                    blocks: blocks, pairs: pairs, width: w, newCursor: page.nextCursor)
            }
            self?.store.prependOlderBlocks([], nextCursor: nil)   // nextCursor==nil auto-flips didFinishLoad
        } catch is CancellationError {
            return
        } catch {
            appLog(.error, "TranscriptViewController", "loader: \(error)")
        }
    }
}
```

**Cancellation** — three checkpoints match Task cancel to VC teardown:
1. `for try await page in stream` — `stream.next()` throws `CancellationError` when the enclosing Task is cancelled.
2. `try Task.checkCancellation()` before Phase 1 — covers the narrow "yielded page but Task got cancelled since" window.
3. `try Task.checkCancellation()` after Phase 2 await — covers the "off-main typeset completed but VC has since torn down" window; the throw exits the loop before touching tableView.

The v5 `isReleased` flag was a fourth checkpoint at each closure body reentry — the Task-cancel design achieves the same thing without a boolean, because cancellation is a first-class exit path.

### 5.3 commit — anchor capture, mutate, insertRows, anchor restore

```swift
private func insertOlderBlocksAtTop(
    blocks: [Block], pairs: [(UUID, RowLayout)],
    width: CGFloat, newCursor: SessionHistory.Cursor?
) {
    let clip = scrollView.contentView
    let originBefore = clip.bounds.origin
    let visibleRange = tableView.rows(in: clip.documentVisibleRect)
    let hasVisible = visibleRange.length > 0                          // ← v5 bug: was `!= NSNotFound`
    let firstVisibleRow = hasVisible ? visibleRange.location : 0
    let firstVisibleRect: NSRect =
        hasVisible ? tableView.rect(ofRow: firstVisibleRow) : .zero

    withoutImplicitAnimations {
        // ORDER LOAD-BEARING (v7 review #1 fix): prepend blocks BEFORE cacheRowLayouts.
        // cacheRowLayouts filters `pairs` by `live = Set(store.blocks.map { $0.id })` —
        // if we wrote before prepending, the new blocks aren't yet "live", so every
        // pair would be dropped silently and heightOfRow would lazy-typeset on main.
        store.prependOlderBlocks(blocks, nextCursor: newCursor)
        store.cacheRowLayouts(pairs, width: width)
        tableView.beginUpdates()
        tableView.insertRows(
            at: IndexSet(integersIn: 0..<blocks.count), withAnimation: [])
        tableView.endUpdates()

        if hasVisible {
            let newRow = firstVisibleRow + blocks.count
            let newRect = tableView.rect(ofRow: newRow)
            let delta = newRect.minY - firstVisibleRect.minY
            clip.scroll(to: NSPoint(x: originBefore.x, y: originBefore.y + delta))
            scrollView.reflectScrolledClipView(scrollView.contentView)  // docs-mandated pairing
        }
    }
}
```

Notes:
- **Order matters** — `prependOlderBlocks` first, `cacheRowLayouts` second, `insertRows` third. `cacheRowLayouts` filters `pairs` against `Set(store.blocks.map { $0.id })` (§ 5.4 stale-block guard); if it ran before `prependOlderBlocks`, every pair would fail the filter and silently drop, and `heightOfRow` would then lazy-typeset each new row on main (§ 2.6 violation). Both writes happen before `insertRows` so that NSTableView's first `heightOfRow` on the new rows hits the warmed cache.
- `NSTableView.rows(in:)` returns `NSRange(0, 0)` when the rect has no rows — **not** `NSNotFound`. v5 gated on `visibleRange.location != NSNotFound`, which is always true; the `hasVisible` check on `.length > 0` is correct.
- `rect(ofRow:)` returns valid values immediately after `endUpdates` — new-row geometry settles synchronously inside `endUpdates` (§ 2.11, no estimated heights). The read stays inside `withoutImplicitAnimations` so the scroll adjust rides the same disabled transaction as the row insert (avoids implicit-animation crossfade of clip origin).
- `withoutImplicitAnimations` = `CATransaction.setDisableActions(true)` + `NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false; body() }` (§ 2.10).

### 5.4 `cacheRowLayouts` — width guard + anti-poison

```swift
func cacheRowLayouts(_ pairs: [(UUID, RowLayout)], width: CGFloat) {
    guard width == layoutsWidth else { return }   // stale batch → drop whole (§ 5.5)
    let live = Set(blocks.map { $0.id })          // stale-block guard
    for (id, l) in pairs where live.contains(id) {
        if layouts[id] != nil { continue }         // § 2.14 anti-poison
        layouts[id] = l
    }
}
```

**v5 bug this fixes:** `layoutsWidth` starts at 0. The v5 code called `cacheRowLayouts(pairs, width: w)` before anyone had populated `layoutsWidth`, so the guard silently dropped every first-batch pair; `heightOfRow` then lazy-typeset each row on main (§ 2.6 violation and a hidden perf regression).

**v7 fix (v10 rename):** VC calls `store.setLayoutWidth(w)` **before** the first `cacheRowLayouts` — inside `viewDidLayout`'s first pass, right after `view.layoutSubtreeIfNeeded()`. `setLayoutWidth` is **conditional**:

```swift
func setLayoutWidth(_ w: CGFloat) {
    guard w != layoutsWidth else { return }   // warm re-entry no-op
    layouts.removeAll(keepingCapacity: true)
    layoutsWidth = w
}
```

Warm re-entry at the same window width now KEEPS the layout cache (matches § 1 goal #1 "sidebar switch-back paints instantly"); a genuine width change wipes and reseeds. This method is called from both first-attach and width-change paths (§ 5.5) — same body, one name.

### 5.5 Width transitions — general width-change trigger (v7 review #5 + v8 review-2#3 fixes)

**Not just `viewDidEndLiveResize`.** Programmatic width changes (⌥⌘S toggling the sidebar, split-view divider set programmatically, entering full-screen, window `setFrame` from an animator) fire `viewDidLayout` **without** live-resize hooks. The v6 spec's live-resize-only wiring would leave `layoutsWidth` stale in all those cases.

**But — don't retarget every drift-frame during a drag.** A live-resize drag fires `viewDidLayout` per frame; the retarget path cancels the loader, wipes the cache, spawns a new detached typeset — running this per frame is drag thrash. Solution: **during live resize, only invalidate visible-row heights** (§ 2.8 shape); defer the full retarget-and-loader-restart until `viewDidEndLiveResize`.

**Trigger surface**:

```swift
override func viewDidLayout() {
    super.viewDidLayout()
    let w = tableView.bounds.width
    if !didInitialAttach {
        performFirstAttach(width: w)              // § 5.6
        didInitialAttach = true
        return
    }
    guard w != store.layoutsWidth else { return }
    if tableView.inLiveResize {
        handleLiveResizeTick(newWidth: w)       // cheap: invalidate visible only (§ 2.8)
    } else {
        retileAtNewWidth(newWidth: w)           // full retarget (this section's body below)
    }
}

override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    let w = tableView.bounds.width
    if w != store.layoutsWidth {
        retileAtNewWidth(newWidth: w)           // deferred full retarget
    }
}
```

`handleLiveResizeTick` reads `tableView.rows(in: tableView.visibleRect)` and does `noteHeightOfRows(withIndexesChanged:)` **only** — no cache wipe, no loader restart, no Phase 2 typeset. `heightOfRow` for the invalidated rows will lazy-typeset on main (§ 2.6 acceptable here — the drag is user-initiated, visible-rows-only, and short-lived).

**`retileAtNewWidth` body** — matches v5 § 5.5:
1. `store.setLayoutWidth(newWidth)` — conditional wipe (§ 5.4) + set `layoutsWidth`.
2. **Cancel + restart loader** (v7 review #7 fix): `loaderTask?.cancel(); loaderTask = nil; startOlderPagesLoader()`. In-flight Phase 2 typeset gets its result discarded by `Task.checkCancellation()` after the await; the new loader restarts from `store.nextCursor` (which is only advanced on commit, so unconsumed pages replay at the new width).
3. Snapshot state on MainActor (`folds`, `statuses`, `highlights`).
4. Identify visible + off-screen row indexes (`tableView.rows(in: visibleRect)`, `tableView.rows(in: overdrawRect)`).
5. `Task.detached(priority: .userInitiated)` typesets visible AND off-screen blocks at `newWidth`.
6. Hop back main; `store.cacheRowLayouts(pairs, width: newWidth)`; inside `withoutImplicitAnimations`: `tableView.noteHeightOfRows(withIndexesChanged: visibleIndexes)` + `tableView.layoutSubtreeIfNeeded()` (force in-tick tile flush per § 2.7) + anchor restore for the visual-top row.

### 5.6 Attach contract — § 2.19 compliance

```
loadView()
    build scroll + TranscriptClipView + table + column (no dataSource)
    add to hierarchy; activate constraints

viewDidLoad()
    tableView.delegate = self
    store.highlights.attachEngine(syntaxEngine)
    store.highlights.onDidFill = { [weak self] id in self?.refreshRowForHighlight(id) }
    (dataSource still nil — no rows queried)
    (no loader Task yet)

viewDidLayout()                                          ← first call: real frame settled
    super.viewDidLayout()
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    view.layoutSubtreeIfNeeded()
    // contentWidth (v7 review #9 fix) — defined as tableView.bounds.width,
    // read AFTER layoutSubtreeIfNeeded settles the constraint solver.
    // NOT view.bounds.width (includes pane) and NOT clipView.bounds.width
    // (does not reflect the 460..780 anchor clamp on the table).
    let contentWidth = tableView.bounds.width

    // Subsequent viewDidLayout calls handle width transitions — see § 5.5.
    guard !didInitialAttach else {
        if contentWidth != store.layoutsWidth { retileAtNewWidth(newWidth: contentWidth) }
        return
    }
    didInitialAttach = true

    store.setLayoutWidth(contentWidth)                   ← BEFORE any typeset

    if !store.didLoadFirstPage {
        // v9: height-based termination. viewportHeight is the pane's
        // effective visible height minus contentInsets (top + bottom scrims);
        // read from the settled scrollView contentSize inside the disabled
        // transaction. The loop reads pages until accumulated row heights
        // fill viewportHeight OR file top is reached — no maxPages / deadline
        // heuristics. Per-block sync typeset inside the loop warms the cache
        // so the subsequent layoutSubtreeIfNeeded tile pass is pure cache-hit.
        let viewportHeight = max(
            0, view.bounds.height - scrollView.contentInsets.top
                - scrollView.contentInsets.bottom)
        do { try store.loadFirstScreenSync(viewportHeight: viewportHeight, width: contentWidth) }
        catch {
            appLog(.error, "TranscriptViewController", "sync first-page: \(error)")
        }
    }

    tableView.dataSource = self                          ← binds NOW; first heightOfRow at settled width
    if !store.blocks.isEmpty {
        tableView.layoutSubtreeIfNeeded()                ← forces the dataSource-set tile
        tableView.scrollRowToVisible(store.blocks.count - 1)
    }

    startOlderPagesLoader()                              ← older-page catchup begins
```

**Warm re-entry:** `store.didLoadFirstPage == true`; sync page load skipped. `store.blocks` already populated (possibly grown by a prior loader Task before it was cancelled). `dataSource = self` binds to full block list; `layoutSubtreeIfNeeded` tiles from the warm `layouts` cache. `startOlderPagesLoader` resumes from `store.nextCursor` if the file top wasn't reached.

**No pendingDeltas queue** — v5 had one; v6 doesn't need one. There's no event to queue: the Store never emits, the VC drives the loader directly.

## 6. Fold / hover / status

Store owns the state (§ 2 table). VC dispatches user actions to store:

- **Hover.** `BlockCellView.mouseEntered/Exited` → `delegate.hoveredBlockId = id`. VC setter records old + new id, then for each affected row calls `tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? BlockCellView` and sets `cell.needsDisplay = true` **directly** (v7 review #8 fix — matches the old renderer's `markGutterRedraw` cost profile). Does NOT go through `reloadData(forRowIndexes:)`, which would re-run `viewFor` and reissue the highlight schedule gate for every cell the cursor crosses. No `noteHeightOfRows` either (color only, § 2.12).
- **Fold.** `BlockCellView.mouseDown` → `HitAction.toggleFold(id)` → `delegate.toggleFold(id)` → VC calls `store.toggleFold(id)`. Returns host `Block.id` or `nil`. **Resolution rule** (v7 review #11 fix): the input `id` may be a group-host `Block.id` OR a `Child.id` inside `Block.Kind.toolGroup(group).children`. `store.toggleFold(id:)` must search both:
  ```swift
  func toggleFold(id: UUID) -> UUID? {
      if let idx = blocks.firstIndex(where: { $0.id == id }) {
          folds[id, default: false].toggle()
          invalidateRowLayout(id: id)
          return id
      }
      for host in blocks {
          if case .toolGroup(let group) = host.kind,
             group.children.contains(where: { $0.id == id })
          {
              folds[id, default: false].toggle()
              invalidateRowLayout(id: host.id)
              return host.id
          }
      }
      return nil
  }
  ```
  Fold flag is stored per-input-id (host or child); layout eviction targets the host block id (that's the row that reloads). If the input id isn't recognized, return `nil` and the VC no-ops. VC then, inside `withoutImplicitAnimations`: `tableView.noteHeightOfRows(withIndexesChanged: [hostRow])` + `tableView.reloadData(forRowIndexes: [hostRow], columnIndexes: [0])`. Matches § 2.10.
- **Status.** History-only; nobody writes here. `statuses` stays empty; children render `.completed` labels. (Live path would write; that path is out of scope here.)

### 6.1 RowLayout.make signature (kept from v5)

```swift
nonisolated static func make(
    for block: Block,
    width: CGFloat,
    folds: [UUID: Bool] = [:],
    statuses: [UUID: ToolStatus] = [:],
    highlights: [Transcript2HighlightKey: HighlightValue] = [:]
) -> RowLayout
```

Thin shim over `Transcript2Coordinator.makeLayout` (existing). RowLayout is otherwise untouched.

## 7. Syntax highlight back-fill

`TranscriptHighlightStore` wraps `Transcript2HighlightStorage` (existing, § 2.15 invariants):

- **Owned by Store, not by VC** (change from v5). Highlights survive sidebar switch-away like `blocks` and `layouts` do — a session with warm code-block tokens paints in-color on switch-back, not plain → colored one frame later.
- `sourceKeys[Key] = fingerprint(payload)` — sub-plans whose fingerprint matches the cached value are skipped (no drop, no JS call, no `onDidFill`).
- `inflightGen[Key]` per-scope; `schedule` bumps gen for the target scope; `drop(blockId:)` bumps every scope on the block; the writeback checks per-scope gen before writing.
- `snapshot()` returns the full `[Transcript2HighlightKey: HighlightValue]` dict as an O(1) COW read (dict is a value type; the read is a reference-count bump, not a copy — copy-on-first-mutation, which never happens in the snapshot's downstream users).
- `onDidFill(blockId:)` handler on the VC:
  ```
  store.invalidateRowLayout(id: blockId)
  if let row = rowFor(blockId) {
      withoutImplicitAnimations {
          tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
      }
  }
  ```
  **No `noteHeightOfRows`** — highlights change color, not metrics (§ 2.12).
- **Late-bind engine.** `TranscriptHighlightStore.attachEngine(_:)` — idempotent, re-schedules every previously-seen scope on nil→non-nil transition. VC calls `attachEngine(syntaxEngine)` once in `viewDidLoad`.
- **Schedule cost on `viewFor`.** VC calls `store.highlights.schedule(block:)` only when the reused cell is being reseated on a new block id (`if cell.blockId != block.id`).

## 8. `BlockCellViewDelegate`

Every current `coordinator?.…` site becomes a delegate method:

```swift
@MainActor
protocol BlockCellViewDelegate: AnyObject {
    var hoveredBlockId: UUID? { get set }        // BlockCellView.swift:222,223,558,574,575
    var isLiveScrolling: Bool { get }            // BlockCellView.swift:549,556,566
    func toggleFold(id: UUID)                    // BlockCellView.swift:724
    func requestUserBubbleSheet(id: UUID)        // BlockCellView.swift:712 (log-only in v8; sheet is in § 14)
    func requestImagePreview(image: NSImage)     // BlockCellView.swift:720 (log-only in v8)
    func handleGutter(_ spec: GutterSpec, blockId: UUID)  // BlockCellView+Gutter.swift:171
}
```

**Rename**: `BlockCellView.swift:92` — `weak var coordinator: Transcript2Coordinator?` → `weak var delegate: BlockCellViewDelegate?`. All ~10 call sites `s/coordinator/delegate/`.

**Old coord adopts protocol additively.** The existing `Transcript2Coordinator` (still constructed by `Session.swift`'s live path) already has all six methods; a one-line `extension Transcript2Coordinator: BlockCellViewDelegate {}` covers it. New `TranscriptViewController` implements the same six. The two paths never share a cell instance.

## 9. Layer boundaries — what is not deleted

- All of `Session.swift`'s render-side wiring (`controller`, `bridge`, `backfillPipeline`) is untouched. `Transcript2Controller`, `Transcript2Coordinator`, `Transcript2EntryBridge`, `TranscriptBackfillPipeline`, `Transcript2Search/Selection/SheetPresenter`, `Transcript2Scroll/Clip/TableView`, `TranscriptScrollViewFactory`, `CenteredRowView`, `Transcript2HighlightStorage` — all stay compiled and used by the live path.
- One required delegate rename in `BlockCellView` (§ 8). Rest of the old stack is unchanged.
- `TranscriptBackfillPipeline` and `JSONLReversePageSource` in `Content/Chat/NativeTranscript2Bridge/` continue to serve `Session.swift`'s live/backfill path. The new history VC does not use them; it goes through `SessionHistory.loadPage` / `.stream` in AgentSDK.
- SDK: `SessionHistory.load(id:order:)` (the async-only v5-added API) is deleted; `_ReverseBatchPairer` is deleted; `_ReverseLineReader` stays. The new API surface is `loadPage` + `stream`, both cursor-based.

## 10. DI & lifecycle

### 10.1 Composition root

`AppDelegate.applicationWillFinishLaunching`:
```swift
let transcriptRegistry = TranscriptRegistryStore()
let appContext = AppContext(..., transcriptRegistry: transcriptRegistry)
sessionManager.onSessionArchived = { [transcriptRegistry] sessionId in
    transcriptRegistry.discard(sessionId)
}
```

### 10.2 Registry `discard(_:)` wiring

`SessionManager.archive(_:)` fires `onSessionArchived?(sessionId)` at the end of its body. `AppDelegate` wires the closure to `TranscriptRegistryStore.discard(_:)`. Discard drops the Store from the dict — the Store deallocates, its highlight store deallocates, blocks/layouts freed.

### 10.3 VC init

`TranscriptViewController(store: TranscriptStore, syntaxEngine: SyntaxHighlightEngine)`. Both injected from `DetailContext` in `DetailFlowCoordinator.makeChild(.history)`.

VC's `viewDidLoad` calls `store.highlights.attachEngine(syntaxEngine)` and installs `onDidFill`. No highlight store is owned by the VC — the Store's `highlights` field is the shared instance.

### 10.4 Lifetimes

| Owner | Lifetime | Cancel/dealloc trigger |
|---|---|---|
| `TranscriptRegistryStore` | Process | AppDelegate deinit (never fires in practice) |
| `TranscriptStore` (per id) | Its slot in registry | `discard(_:)` on archive/delete |
| `TranscriptViewController` | One mount | Container removal → `prepareForRemoval` |
| `loaderTask` | ≤ VC | `prepareForRemoval` calls `loaderTask?.cancel()` |
| Detached typeset Task (per commit) | Bound to its `await` return | Enclosing `loaderTask` cancel → next `Task.checkCancellation()` throws → detached Task itself finishes normally (its `blocks.map` doesn't check cancel — it just runs to completion; the result is discarded) |

The detached typeset closure isn't itself cancellable — `blocks.map { RowLayout.make(…) }` isn't a checkpoint. That's OK: worst case is one page's worth of typeset work continues after VC teardown, then its result is discarded when `Task.checkCancellation()` throws after the `await`. Total wasted CPU: one page (≤ ~50 blocks × 1–3 ms).

## 11. Perf parity — line-item against `NativeTranscript2/CLAUDE.md § 2`

| Old invariant | How v6 keeps it |
|---|---|
| § 2.1 sync `heightOfRow` on cache hit | `store.layout(for:width:…)` is get-or-compute. Warm cache = hit. First-page sync tile misses (§ 5.1) then caches, so subsequent scrolls hit. |
| § 2.2 cell `wantsLayer + .onSetNeedsDisplay` | `BlockCellView` unchanged. |
| § 2.3 `.never` layer on scroll + clip | Set on stock `NSScrollView` **and** `TranscriptClipView`. |
| § 2.4 `[UUID: CachedLayout]` no LRU | `TranscriptStore.layouts: [UUID: RowLayout]`; width lives on the store; wholesale invalidate on width change. |
| § 2.5 `nonisolated static makeLayout` | `RowLayout.make` is `nonisolated static`; loader's Phase 2 Task.detached calls it. |
| § 2.6 backfill off-main-built + sync-applied | Older pages: Phase 2 typeset off-main → main-hop commit. First page: **sync on main** — see § 5.1 justification (bounded to one 64 KB page). |
| § 2.7 in-tick anchor for resize | § 5.5 `viewDidEndLiveResize` forces `layoutSubtreeIfNeeded` after `noteHeightOfRows` inside the disabled transaction. |
| § 2.8 live-resize touches visible rows only | § 5.5. |
| § 2.9 negative-width clamp | `TranscriptClipView.setFrameSize` clamps `max(0, w), max(0, h)`. |
| § 2.10 suppress implicit animations | Every commit path (loader commit, fold, hover, highlight refill, live-resize refill) wrapped in `withoutImplicitAnimations`. |
| § 2.11 no `reloadData()` | VC never calls `reloadData()`. |
| § 2.12 highlight refill skips `noteHeightOfRows` | § 7. |
| § 2.13/b search / status | Search out of scope (§ 14). Status kept as sparse dict. |
| § 2.14 anti-poison in `cacheRowLayouts` | § 5.4. |
| § 2.15 per-scope dedup + gen guard | Wrapped `Transcript2HighlightStorage` — invariants intact. |
| § 2.16 shimmer overlay | `BlockCellView` unchanged. |
| § 2.17 stable row-reuse key | VC implements `tableView(_:rowViewForRow:)` with reuse identifier `"TranscriptBlockRow"`; `BlockCellView` reuse identifier `"TranscriptBlockCell"`. Both are stable across scroll ticks. |
| § 2.18 stable `Block.id` | `MessageEntryBlockBuilder` unchanged. |
| § 2.19 one width per attach | § 5.6 attach contract — sync first page populates blocks BEFORE `dataSource = self`, so the first `heightOfRow` runs at the settled width against the warm cache. Loader's own for-await commits happen after the attach tick — later batches ride the same width contract. |

### 11.1 First-frame timing

**v9 first-frame:** click session → attach VC → `viewDidLayout` first pass → `loadFirstScreenSync(viewportHeight:, width:)` (reads pages + typesets per block until viewport filled) → `dataSource = self` → `layoutSubtreeIfNeeded` (pure cache hits) → paint. **Total: ~20–50 ms typical (1 page fills the pane); ~40–80 ms tool-heavy tail (2–3 pages); ~10–30 ms tall-first-message (one huge diff block exceeds viewport, we stop after typesetting one row). Rare-worst-case: seconds if the entire session file is one open groupable-assistant run with no closer — see § 5.1.1's acceptance of this edge. Zero blank-pane flash in every non-pathological case.**

**v5 first-frame** (would have been if v5 hadn't been reverted): click → attach → `viewDidLayout` → attach subscription → wait for SDK's first stream yield (~5 ms + Task hop) → Combine hop to main → Task chain scheduling → detached typeset (~10 ms) → hop back → commit → paint. **~30–50 ms + one blank frame (16 ms) between the two hops.**

The sync-first-page tradeoff: v6 spends a bit more main time but eliminates the one-frame blank. Perceived responsiveness is materially better on session open, especially on the click-to-first-glyph metric.

## 12. Testing

Unit tests live in `cctermTests/` and follow the CLAUDE.md rules (no `forceXxxForTest`, no widening access; drive public surface).

Baseline suite:

- **New**: `TranscriptStoreFirstPageTests` — inject fake JSONL via a temp URL; assert (1) `loadFirstScreenSync(viewportHeight: 800, width: 720)` populates `blocks` in document order (oldest→newest); (2) accumulated block heights ≥ 800 pt (viewport filled) OR file top reached (`didFinishLoad == true`); (3) after the call, `store.layouts.count == store.blocks.count` — every block was typeset synchronously and cached; (4) short file variant — file smaller than one viewport → `nextCursor == nil` AND `didFinishLoad == true`.
- **New**: `TranscriptStorePrependTests` — starting from a populated store, drive `prependOlder([b1, b2, b3], newCursor: nil)`; assert `blocks[0..3] == [b1, b2, b3]` and `didFinishLoad == true`. Drive `cacheRowLayouts` with mismatched width; assert cache unchanged; drive with matching width; assert entries installed.
- **New**: `TranscriptViewControllerAttachOrderTests` — mount VC against a stub Store, drive `loadView` + `viewDidLoad` + `viewDidLayout`, assert `dataSource` is nil after `viewDidLoad` and set after `viewDidLayout`. Inject a stub `SessionHistory.loadPage` that returns a canned Page; assert `store.blocks == cannedFirstPageBlocks` after `viewDidLayout` first-pass returns.
- **New**: `TranscriptClipViewCenteringTests` — install a documentView of width 500 into `TranscriptClipView`, drive `constrainBoundsRect` at proposed widths 800 / 500 / 300, assert `origin.x = -150 / 0 / 0` respectively. Vertical passes through.
- **New**: `SessionHistoryCursorTests` — synthetic JSONL fixture; assert `loadPage(cursor: nil)` returns page 1 with a `nextCursor`; `loadPage(cursor: nextCursor)` returns page 2; iterate to file top; last page has `nextCursor == nil`. Same fixture through `stream` — yields the same page sequence.
- **New**: `TranscriptHighlightStoreTests` — fingerprint dedup returns cache hit; late-bind `attachEngine` reschedules pending scopes; per-scope gen guard drops stale writebacks.

v7 review #12 additions (guarding the review-flagged shapes explicitly):

- **New**: `TranscriptStoreOpenGroupFirstPageTests` — fixture: a JSONL whose newest 20 messages are one open `isGroupableAssistant` run followed by an older text turn that closes it. Assert `loadFirstScreenSync(viewportHeight: 800, width: 720)` walks pages until it finds the closer (or file top), returns with `blocks.count >= 1` (typically 1 group entry containing all 20 tool_uses), accumulated height ≥ viewportHeight OR `didFinishLoad == true`. Pathological variant (entire file is one groupable run, no closer): loop walks to file top; `builder.finish()` flushes the run as one group entry; returns with at least one block.
- **New**: `TranscriptStoreCommitOrderTests` — regression net for review #1. Drive `insertOlderBlocksAtTop(blocks: [b1, b2], pairs: [(b1.id, l1), (b2.id, l2)], width: w, newCursor: nil)` with a populated store. Assert (1) `store.layouts[b1.id] == l1` AND `store.layouts[b2.id] == l2` after commit — would fail (`layouts[bN.id] == nil`) if the code wrote layouts before prepending blocks, because the stale-block filter `Set(store.blocks.map { $0.id })` would exclude the new ids and drop every pair. Assertion (2) — verifying no lazy re-typeset — is dropped from this test; measuring "no `RowLayout.make` call happened" needs a call-counter seam, which per CLAUDE.md we don't add for tests. Assertion (1) is a sufficient regression net: if layouts are cached, `heightOfRow` returns the cached height by construction (it's `layouts[id] ?? make(…)`); if layouts are dropped, `heightOfRow` typesets. Cache population and heightOfRow behavior are functionally equivalent for the store's public contract.
- **New**: `TranscriptStoreWarmCacheTests` — regression net for review #3. Populate store; simulate VC dismount (registry keeps the store); simulate re-mount at the same width; assert `layouts.count` unchanged after `setLayoutWidth(sameW)`. Drive `setLayoutWidth(differentW)`; assert `layouts.count == 0`.
- **New**: `TranscriptViewControllerCancellationTests` — construct VC + stub loader that yields a slow stream; drive `prepareForRemoval` mid-stream; assert `loaderTask?.isCancelled == true` within one main-tick and no `insertRows` fires after teardown.
- **New**: `TranscriptViewControllerAnchorMathTests` — prepend anchor delta computation. Given a stable-height fixture (each row 60pt), viewport at clip.origin.y=1200, first visible row = 20 with rect.minY=1200; drive `insertOlderBlocksAtTop` with a 5-row batch. Assert clip.origin.y after commit = 1200 + 5×60 = 1500 (visual-top row preserved). Repeat with variable heights.
- **New**: `TranscriptViewControllerProgrammaticWidthTests` — regression net for review #5. Simulate a `viewDidLayout` call after initial attach with `tableView.bounds.width` changed; assert `retileAtNewWidth` fires (layout cache wipes and re-seeds; loader restarts). Simulate an unchanged-width second `viewDidLayout`; assert no-op (cache untouched, loader untouched).

## 13. Rollout

1. **SDK**: Add `SessionHistory.Cursor` + `Page` + `loadPage(sync)` + `stream(async)`. Delete old `load(id:order:)`. Delete `_ReverseBatchPairer`. Cursor tests.
2. Add `TranscriptClipView` + `BlockCellViewDelegate` + `TranscriptHighlightStore` (wraps existing `Transcript2HighlightStorage`).
3. Widen `RowLayout.make` signature (§ 6.1) — same shim as v5.
4. Refactor `BlockCellView` (`coordinator → delegate`); one-line `extension Transcript2Coordinator: BlockCellViewDelegate {}`.
5. Rewrite `TranscriptStore` + `TranscriptViewController` per this doc.
6. Wire `discard(_:)` (§ 10.2) — `SessionManager.onSessionArchived` closure.
7. Build clean; run new tests; manually verify (a) session open is snappy without blank flash; (b) scroll to top loads older pages; (c) sidebar switch-away/back preserves position and cache; (d) window resize rescales the 460..780 band and re-tiles visible rows.
8. Follow-up PR: cross-row **selection** (bring back `Transcript2SelectionCoordinator`-equivalent as a new `TranscriptSelectionStore` — see § 14 for the API sketch).
9. Follow-up PR: rip the old renderer stack out of `Session.swift`.
10. Follow-up PR: top/bottom scrim overlays.
11. Follow-up PR: user-bubble sheet + image preview sheets + in-transcript ⌘F search.

## 14. Out of scope

Every item below is a follow-up PR. None precludes the others.

- **Selection** (cross-row text drag + ⌘C copy). Style parity is this PR's focus; selection is orthogonal to the loader/store shape. Follow-up sketch: new `TranscriptSelectionStore` (owned by `TranscriptStore`, since selection state should survive sidebar switch-away like folds do), driven by mouse events forwarded from `BlockCellView` via the delegate protocol. Rendering path uses the same `SelectionAdapter` the old renderer uses; the store's `snapshot()` feeds `viewFor`'s `cell.selection = …` write.
- User-bubble full-text sheet and image-preview sheet (`BlockCellViewDelegate.requestUserBubbleSheet` / `requestImagePreview` log at `.info` and no-op).
- In-transcript ⌘F search.
- Removal of the old renderer stack from `Session.swift`.
- Top/bottom scrim overlays.

## 15. What this plan explicitly rejects (v5 → v9 postmortem)

For posterity — the shapes prior revisions tried and v9 will not:

| v5 (rejected) | Reason | v6 replacement |
|---|---|---|
| `store.events: PassthroughSubject<BlockDelta, Never>` + `.receive(on: .main).sink` in VC | Extra scheduling hop + one runloop tick of delay. `AsyncThrowingStream.next()` already yields on the awaiting task's actor. | VC owns the for-await loop; commits directly. |
| `visibleBlocks: [Block]` mirror in VC | Two sources of truth. Only needed because Store's `blocks[]` was mutated before VC's `insertRows` in a different tick. | Store mutates INSIDE the same MainActor tick as `insertRows`; dataSource reads `store.blocks` directly. |
| `applyChain: Task<Void, Never>?` — each new apply awaits the previous | Only needed because Combine could deliver two deltas in one tick without back-pressure. | for-await loop is inherently serial. |
| `isReleased: Bool` guarded on every commit path | Post-teardown protection against detached Tasks landing on a niled dataSource. | `Task.cancel()` + `Task.checkCancellation()` at three loop checkpoints. |
| `SessionHistory.load(id:order:)` async-only, no cursor | Couldn't support first-screen sync; couldn't resume from a saved position. | `loadPage(sync)` + `stream(async)` both cursor-based; sync used for first screen. |
| SDK's `_ReverseBatchPairer` (duplicates app-side `ReverseEntryBuilder.withheld`) | Two implementations of the same tool_use↔tool_result pairing invariant. | SDK yields raw pages; app-side `ReverseEntryBuilder` pairs. |
| Phase 1 typeset for tail forced off-main via detached typeset | Correct for older-page catchup, wrong for first screen — introduced a blank one-frame paint on session open. | First screen typesets on main (bounded); older pages detached. |
| Layout width guard silently drops the first `cacheRowLayouts` (`layoutsWidth == 0`) | Hidden perf bug — the intended cache primer was a no-op, `heightOfRow` lazy-typeset instead. | VC calls `store.seedWidth(w)` before any typeset. |
| `firstVisibleRow != NSNotFound` in `insertOlderBlocksAtTop` scroll anchor | `NSTableView.rows(in:)` returns `(0, 0)`, not `NSNotFound`, when empty. Guard was always true. | `visibleRange.length > 0`. |
| VC-owned `TranscriptHighlightStore` | Sidebar switch-away throws away highlight tokens; switch-back paints plain → colored one frame later. | Store-owned; tokens survive VC lifetime. |
| §14 quietly hiding selection as out-of-scope without user agreement | Selection was working in the old renderer; silently deferring it is a functional regression. | Selection remains out of this PR **explicitly** (§ 14) with a documented follow-up sketch. |
| v6 `insertOlderBlocksAtTop` wrote layouts BEFORE prepending blocks | `cacheRowLayouts` filters by `Set(store.blocks.map { $0.id })` — new-batch ids weren't yet live, so every layout pair was silently dropped and `heightOfRow` lazy-typeset on main | § 5.3 — swap ordering: `prependOlder` first, `cacheRowLayouts` second, `insertRows` third |
| v6 `applyFirstPage` could return zero blocks (open group not closed inside first 64 KB) | `ReverseEntryBuilder` never speculatively emits an open groupable-assistant run; a tail-heavy session would open with a blank pane until the async loader's first commit | § 5.1.1 — bounded loop (`maxPages: 8`, `deadline: 100 ms`) that keeps reading sync pages until either an older non-groupable message closes the run OR file top reached (`builder.finish()`) OR budget exhausted |
| v6 `seedWidth` unconditionally wiped the cache | Warm re-entry at same width would re-typeset every visible row on main, defeating the "instant switch-back" goal | § 5.4 — `seedWidth` guarded with `if w != layoutsWidth { … }`; no-op on same-width re-entry |
| v6 dropped the `rowViewForRow` reuse identifier | § 2.17 regression — NSTableView allocates fresh row views per scroll tick | § 4.2 — VC implements `tableView(_:rowViewForRow:)` with identifier `"TranscriptBlockRow"` |
| v6 handled width changes only in `viewDidEndLiveResize` | ⌥⌘S / sidebar collapse / split-view programmatic resize would leave `layoutsWidth` stale; next scroll would lazy-typeset every visible row on main | § 5.5 — every `viewDidLayout` post-attach compares `tableView.bounds.width` to `store.layoutsWidth`; drift triggers `retileAtNewWidth` (`viewDidEndLiveResize` remains as an optimization signal only) |
| v6 `AsyncThrowingStream` used default (unbounded) buffering | Fast disk read could accumulate the whole file in the stream buffer ahead of a paced consumer | § 2 SDK row — stream built via `AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))` |
| v6 loader kept committing after a width change already dropped the layouts | `prependOlder` still installed blocks, `cacheRowLayouts` was width-guard-dropped, `heightOfRow` then lazy-typeset each new row on main during resize | § 5.5 — width-change trigger `cancel()`s current `loaderTask` and calls `startOlderPagesLoader()` which re-awaits from `store.nextCursor` at the new width |
| v6 hover repainted via `reloadData(forRowIndexes:)` | Re-ran `viewFor` + reconciled SubviewPlan + reissued highlight schedule gate for every cell the cursor crossed — a viewFor round-trip per hover event | § 6 — hover path uses `tableView.view(atColumn: 0, row: r, makeIfNecessary: false)` + `cell.needsDisplay = true` directly; matches the old renderer's `markGutterRedraw` cost |
| v6 didn't spell out `contentWidth` | Implementer could pick `view.bounds.width` or `clipView.bounds.width` — both wrong; would silently re-introduce the v5 layoutsWidth mismatch bug | § 5.6 — `contentWidth = tableView.bounds.width`, read AFTER `view.layoutSubtreeIfNeeded()` |
| v6 `TranscriptHighlightStore` was described as a naming shim over `Transcript2HighlightStorage` | Rename-only wrapper violates the spirit of § 3 naming compliance | § 2 highlight row — wrapper adds two real behaviors (internalized `attachEngine` reschedule, O(1) full-dict `snapshot()`); naming is a byproduct, not the reason to exist |
| v6 `toggleFold(id:)` return semantics ambiguous | Child-header clicks would silently no-op if implementer forgot to resolve `id` against `Block.Kind.toolGroup.children` | § 6 — full resolution algorithm inline; searches both `blocks[*].id` and `blocks[*].kind.toolGroup.children[*].id`, returns host block id |
| v7 attach contract defined `loadFirstScreenSync` in § 5.1.1 but § 5.6 still called `loadPage(cursor: nil)` directly | The bounded loop that defends against open-group blank first screens wasn't wired — dead code | § 5.6 attach path calls `try store.loadFirstScreenSync()` |
| v7 SDK stream buffering claim (`.bufferingNewest(1)` "so the producer waits for the consumer") was wrong | `.bufferingNewest(1)` silently DISCARDS overflowing pages instead of blocking the producer; would introduce gaps in the reverse walk and silent transcript corruption at page seams | § 2 SDK row — stream uses `AsyncStream(unfolding:)`-style demand-driven iterator OR paired-continuation producer that awaits consumer demand explicitly; producer polls `Task.checkCancellation()` so consumer cancel terminates the producer |
| v7 `retileAtNewWidth` fired unconditionally on every `viewDidLayout` width drift | Live-resize drag with even 1-pixel jitter would cancel+restart the loader and spawn a Task.detached typeset every frame — drag thrash + producer leak | § 5.5 — `viewDidLayout` routes: `inLiveResize` path → cheap `handleLiveResizeTick` (invalidate visible only); non-drag drift → full `retileAtNewWidth`. `viewDidEndLiveResize` runs the deferred full retarget |
| v7 `loadFirstScreenSync` deadline described as a hard 100 ms cap | Deadline is checked at loop head only; one page's fileEdit-diff build can overshoot to ~200 ms | § 5.1.1 — deadline honestly labeled as soft; `maxPages` (8) is the hard bound; § 11.1 first-frame table updated |
| v7 `TranscriptStoreCommitOrderTests` assertion (2) tried to observe "no re-typeset happened" | RowLayout is a pure value; a cache-hit and a lazy re-typeset produce equal structs — no observable difference without a `RowLayout.make` call counter seam, which CLAUDE.md forbids adding | § 12 — assertion (2) dropped; assertion (1) is sufficient (cache populated ⇒ heightOfRow is a hit by construction) |
| v7 § 2 store API list missing `advanceCursor(to:)` and `markFinished()` | Loader body in § 5.2 references both; API surface incomplete | § 2 store row — both added to the sync-mutation API list |
| v7 log-only delegate methods documented as "log-only in v6" | Stale label from prior revision | § 8 — updated to v8 |
| v7 `SessionHistory.stream`'s detached producer didn't check cancellation | Consumer cancel would leave the producer walking to file top, spawning new producers on each width thrash — cumulative leak | § 2 SDK row — producer polls `Task.checkCancellation()` inside the yield loop; consumer cancel terminates it |
| v8 `loadFirstScreenSync(minBlocks:maxPages:deadline:)` — three magic numbers, none corresponding to the actual goal | The goal is "fill the visible pane once"; the three heuristics never expressed it. Over-read in typical case (8 pages when 1 fills the screen), under-fill in pathological case (bail out at 8 pages leaves blank pane) | § 5.1.1 — signature is `loadFirstScreenSync(viewportHeight:width:)`. One termination criterion (`heightSoFar >= viewportHeight` OR file top); per-block sync typeset inside the loop warms cache before `dataSource = self` |
| v8 first-screen path relied on `layoutSubtreeIfNeeded` to lazy-typeset visible rows | Two-step warm-up: build blocks in loop, then typeset in tile pass. Ambiguity around § 2.19 attach contract — "which width is the tile actually running at?" | § 5.1.1 — typeset happens INSIDE the loop via `store.layout(for:width:…)`. By the time `dataSource = self` fires, every relevant row has a cached layout at the exact same width. Attach tile is 100% cache hit |
| v8 attempted "safety bail-out" for pathological open-group runs (empty first-screen → hand off to async) | Both alternatives freeze the user on session open. Bail-out means "user sees empty pane then a delayed paint"; sync-walk-to-top means "user waits once for a real paint". Neither wins UX; simpler wins engineering | § 5.1.1 — no safety cap. Loop terminates only on viewport-fill or file top. Rare-worst-case (multi-second freeze on a huge open-group file) accepted |
| v9 kept `MessageEntry` + `MessageEntryBlockBuilder` for the history path just because the live path uses them | Reuse-because-it's-there instead of "does the new architecture need this?" MessageEntry is a pass-through nobody reads; the two-step builder pipeline forces `@MainActor` on Phase 1 unnecessarily | § 2 — new `MessageBlockBuilder` (nonisolated, forward, direction-agnostic). Direct `Message2 → [Block]`. Phase 1 can move off-main in a follow-up. History path drops `MessageEntry` reference; live path keeps its own separately |
| v9 pushed cross-page tool-result pairing to app-side (`ReverseEntryBuilder.withheld`) after v6 mis-identified the SDK's `_ReverseBatchPairer` as duplicate | Pairing is a stream-layer invariant (a page yielding orphan tool_result without its tool_use is incomplete data); pushing it up means the app builder must be reverse-directional to reason about the withheld state | § 2 SDK row — `_WithheldTools` restored inside SDK. SDK guarantees every yielded page is forward-ordered AND has complete tool pairs. App-side builder can be forward-only |
| v9 name `ReverseMessageBlockBuilder` | Traversal direction is a stream-layer concern (byte-walk in SDK), not a builder concern. Naming by SDK's implementation detail leaks up | § 2 — `MessageBlockBuilder`. Same builder is reusable by the live path (which is naturally forward) |
| v10 first-pass names `applyOlderBatch` / `startBackgroundLoader` / `runStructuralUpdate` / `commitOlder` / `performLiveResizeFrame` / `performWidthChange` | All vague — "batch" of what, "background" what, "structural" what, "commit" what, "perform frame" what. § 3 smell test: name still meaningful after deleting surrounding context? No | § 3.1 rename table — `prependOlderBlocks` / `startOlderPagesLoader` / `withoutImplicitAnimations` / `insertOlderBlocksAtTop` / `handleLiveResizeTick` / `retileAtNewWidth`. Verb = act; object = what's acted on |
| v9 names `cacheLayouts` / `invalidateLayout` / `layout(for:...)` / `handleHighlightFilled` / `schedule(block:)` | "Layouts" is under-specified; "handle" hides act; "schedule" hides subject | `cacheRowLayouts` / `invalidateRowLayout` / `rowLayout(for:...)` / `refreshRowForHighlight` / `scheduleHighlighting(for:)` |
| v10 initial `HistoryBlockBuilder` proposal | Named by caller (history path), not by what it is (Message2→Block) | `MessageBlockBuilder`. Third instance of the same anti-pattern this session (after `visibleBlocks` mirror and `MessageEntry` reuse) — hence § 3.1 rule promoted |
