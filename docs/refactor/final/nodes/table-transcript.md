# Ownership table — Transcript renderer (NativeTranscript2/) + bridge (NativeTranscript2Bridge/)

Scope: the AppKit Core-Text self-drawn transcript and the entry→Block translation
layer. **This entire scope sits behind the do-not-touch wall** (REFACTOR-PLAN §10.1
transcript §2 performance contract, §10.2 §2.19 single-width attach contract, §10.3
runloop-tick ordering, §10.4 bridge/builder parity). The plan states explicitly
(§8 P5/P6, §1.3): *"本方案无任何一步进入渲染器内部"* — no PR enters the renderer's
interior. Consequently **every row is `unchanged` / Renderer-internal** with two
classes of exception, both behavior-preserving:

- **Two SwiftUI sheet bodies** (`UserBubbleSheetView`, `ImagePreviewSheetView`) are
  the only hosting boundary in scope — regime **D** (modal sheet via `beginSheet`,
  BOUNDARY-SPEC §1 / §6). Unchanged.
- **`StableBlockID`** is grazed by **PR-A3** (P14) only for a *cross-file constant
  extraction* (`StableBlockID` scheme referenced ×3 — REFACTOR-PLAN §8 P14). No
  logic change; existing snapshot tests guard. Marked `PR-A3 (const only)`.

PR labels are mnemonic placeholders consistent with REFACTOR-PLAN §9 phases
(A = boilerplate/dead-code/rename; D = transcript-swap). The PRPlan phase finalizes
numbers. **No PR in this scope changes renderer behavior.**

Architecture facts cross-checked against `NativeTranscript2/CLAUDE.md` (§1 Controller
vs Coordinator split, §3 single source of truth, §4 layout boundaries, §6 file layout,
§7 highlight back-fill) and source declarations.

---

## Host VC facing — controller / coordinator / coordinator-siblings / sheet presenter

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Transcript2Controller` | Session-core | @Observable-SVC | `Session.init` (`Session.swift:166`) | `Session` (session-lifetime; survives mount/dismount) | ctor-injected (none) / @Observable pull by hosts | imperative controller call (`coordinator.apply`); @Observable write (`blockCount`/`searchState`/`pendingUserBubbleSheet`/`pendingImagePreview`/`loadingPillVisible`) | — | unchanged | ✓ |
| `Transcript2Coordinator` | Renderer-internal | AK-NSObject | `Transcript2Controller` (init) | Controller (session-lifetime) | ctor-injected (controller, syntaxEngine via `attachSyntaxEngine`) | imperative controller call (`NSTableView` insert/remove/reloadData); injected closure (`onBlockCountChanged`/`onUserBubbleSheetRequested`/`onLayoutWidthDidSettle`) | — | unchanged | ✓ |
| `Transcript2SelectionCoordinator` | Renderer-internal | AK-NSObject | `Transcript2Coordinator` (init) | Coordinator (session-lifetime) | ctor-injected (reads `layout.selectionAdapter` per query) | imperative controller call (`markCellSearchDirty` / cell repaint) | — | unchanged | ✓ |
| `Transcript2SearchCoordinator` | Renderer-internal | AK-NSObject | `Transcript2Coordinator` (init) | Coordinator (session-lifetime) | ctor-injected (reads `blockIds` + `selectionAdapter.searchableRegions`) | imperative controller call (`markCellSearchDirty` / `expandForSearchHit` / `scrollBlockIntoView`); injected closure (`onStateChanged`) | — | unchanged | ✓ |
| `Transcript2HighlightStorage` | Renderer-internal | @Observable-SVC | `Transcript2Coordinator` (init) | Coordinator (session-lifetime) | ctor-injected (syntaxEngine `highlightBatch`) | injected closure (`onDidFill(blockId)` → `reloadData(forRowIndexes:)`) | — | unchanged | ✓ |
| `Transcript2SheetPresenter` | Per-attach | AK-NSObject | `ChatSessionViewController.attachSession` (`:405`) | Chat VC (per-attach; reinstantiated per session attach; demo VCs own one for life) | @Observable pull (`withObservationTracking` on `controller.pendingUserBubbleSheet`/`pendingImagePreview`) | imperative controller call (`view.window?.beginSheet`) | D (sheet host wraps SwiftUI body) | unchanged | ✓ |

---

## AppKit table shell + cell (self-drawn) + factory

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `TranscriptScrollViewFactory` | Per-attach | translator | n/a (caseless `enum` namespace; static `make`/`bindData`/`dismantle`) | none (stateless factory) | n/a | imperative controller call (builds/binds scroll·clip·table shell) | — | unchanged | ✓ |
| `Transcript2ScrollView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | Chat VC / swap (per-attach) | n/a | none (composites children; `.never` layer + responsive scrolling — §2.3) | — | unchanged | ✓ |
| `Transcript2ClipView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | enclosing scroll view (per-attach) | n/a | imperative controller call (`scroll(to:)` + `reflectScrolledClipView`) | — | unchanged | ✓ |
| `Transcript2TableView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | enclosing scroll view (per-attach) | ctor-injected (dataSource/delegate = Coordinator) | imperative controller call (negative-width clamp on `setFrameSize` — §2.9) | — | unchanged | ✓ |
| `BlockCellView` | Renderer-internal | AK-View | `NSTableView` `makeView` (recycled) | table (row-reuse) | ctor-injected (`RowLayout` + `SubviewPlan` per `viewFor`) | injected closure (`SubviewPlan` entry closures); imperative controller call (`requestUserBubbleSheet`, fold/link hit) | — | unchanged | ✓ |
| `BlockCellView+SubviewPlan` (ext + `ToolGroupEntryView`, `ShimmerLayerSet`) | Renderer-internal | AK-View | `BlockCellView` reconciler | `BlockCellView` (cell-lifetime sublayers/subviews) | ctor-injected (current `SubviewPlan`) | imperative controller call (CALayer/subview reconcile) | — | unchanged | ✓ |
| `BlockCellView+Gutter` (ext) | Renderer-internal | AK-View | n/a (drawing extension on `BlockCellView`) | `BlockCellView` | n/a | none (self-draw) | — | unchanged | ✓ |
| `CenteredRowView` | Renderer-internal | AK-View | `NSTableView` `rowViewForRow` (`"BlockRow"` reuse key) | table (row-reuse) | n/a | none (no-op row view; stable reuse key only — §2.17) | — | unchanged | ✓ |
| `LoadingPillUsageView` | Renderer-internal | AK-View | `BlockCellView` subview-plan reconciler | `BlockCellView` (cell-lifetime) | ctor-injected (`apply(spec:)` from subview plan; owns 1 Hz timer + `StreamPacer`) | none (self-draws elapsed clock + token odometer) | — | unchanged | ✓ (pure `NSView`, **not** SwiftUI — the as-is component tree's "唯一的 SwiftUI 叶子" label is a doc drift; source is `final class … : NSView`) |

---

## Layout value types (`Layout/`) — pure `XxxLayout` + dispatch + decoration plans

All are immutable value types / caseless enums: `make(input, width, state) -> Layout`
(§4 "State is an input to the layout function, not a stored field"). `nonisolated static
makeLayout` purity (§2.5) is load-bearing. None is a hosting boundary.

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `RowLayout` (+ `InteractiveHit`, `HitAction`) | Pure-value | value/MDL | `Coordinator.makeLayout` (nonisolated static) | `layoutCache: [UUID: CachedLayout]` (derived; evict-safe) | ctor-injected (block + width + state snapshots) | none (pure; exposes `totalHeight`/`draw`/`subviewPlan`) | — | unchanged | ✓ |
| `TextLayout` | Pure-value | value/MDL | `RowLayout`/`makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `ImageLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `ListLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `TableLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `UserBubbleLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | imperative controller call (chevron `mouseDown` → `Coordinator.requestUserBubbleSheet`) | — | unchanged | ✓ |
| `UserAttachmentsLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | imperative controller call (attachment tap → image preview request) | — | unchanged | ✓ |
| `CodeBlockLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected (`tokens: [SyntaxToken]?` snapshot) | none (CopyChrome hit handled via cell) | — | unchanged | ✓ |
| `CopyChrome` | Pure-value | value/MDL | code/bash/diff layouts | embedding layout | ctor-injected (id + hitRect + center) | none (reusable copy-button primitive) | — | unchanged | ✓ |
| `BlockquoteLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `ThematicBreakLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected | none | — | unchanged | ✓ |
| `LoadingPillLayout` | Pure-value | value/MDL | `makeLayout` (loading-pill row) | layout cache | ctor-injected (status/dots/usage) | none (declares `SubviewPlan.LoadingDots`/`UsageCounter`) | — | unchanged | ✓ |
| `ToolGroupLayout` | Pure-value | value/MDL | `makeLayout` | layout cache | ctor-injected (foldStates/statusStates/highlights snapshots) | none (dispatches to `ToolGroupChildLayout`; emits `subviewPlan`/`selectionAdapter`) | — | unchanged | ✓ |
| `ToolGroupChildLayout` (+ nested `Kind`) | Pure-value | value/MDL | `ToolGroupLayout.make` | enclosing `ToolGroupLayout` | ctor-injected (child payload + state + errorText) | none (per-kind dispatch + uniform error card) | — | unchanged | ✓ |
| `ToolGroupChildHighlight` | Pure-value | translator | `Storage.plan(for:)` per kind | none (stateless `requests(for:)`/finalize) | ctor-injected | none (returns highlight `Plan`) | — | unchanged | ✓ |
| `TextCardSection` | Pure-value | value/MDL | per-kind child layouts | enclosing child layout | ctor-injected | none (shared sub-card geometry/draw) | — | unchanged | ✓ |
| `SelectionAdapter` (+ `LayoutPosition`, `SelectionRange`, `SearchableRegion`) | Pure-value | value/MDL | per layout (`struct + closures`) | enclosing layout | ctor-injected (closures over layout geometry) | injected closure (`rects`/`position`/`searchableRegions`) | — | unchanged | ✓ |
| `SubviewPlan` (+ `Chevron`/`Shimmer`/`LoadingDots`/`UsageCounter`/`Entry`) | Pure-value | value/MDL | layout `subviewPlan(...)` | consumed by cell reconciler | ctor-injected (resolved colors/rects/closures) | injected closure (entry `draw` closures) | — | unchanged | ✓ |
| `GutterSpec` | Pure-value | value/MDL | diff layouts | enclosing diff layout | ctor-injected | none (gutter line-number geometry) | — | unchanged | ✓ |

### Tool-group child payloads + layouts (`Layout/ToolGroupChildren/<Kind>/`)

Ten kinds, each a payload `struct` (`id`/`label`/`activeLabel`/`errorText`) +
`XxxChildLayout` value type (+ optional `XxxChildHighlight` translator). All pure,
all unchanged, none a hosting boundary. Representative rows (every kind is identical
in schema placement):

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `FileEditChild` / `FileEditChildLayout` / `FileEditChildHighlight` / `DiffBlock` / `DiffLayout` | Pure-value | value/MDL (+ translator for `…Highlight`) | bridge (`ToolUseToChild`) / `ToolGroupChildLayout.make` | layout cache | ctor-injected | none (diff body; `.diff` selection region) | — | unchanged | ✓ |
| `ReadChild` / `ReadChildLayout` / `ReadChildHighlight` | Pure-value | value/MDL (+ translator) | bridge / child layout | layout cache | ctor-injected | none (new-file diff card) | — | unchanged | ✓ |
| `BashChild` / `BashChildLayout` / `BashChildHighlight` | Pure-value | value/MDL (+ translator) | bridge / child layout | layout cache | ctor-injected | none (3 sub-cards) | — | unchanged | ✓ |
| `GrepChild` / `GrepChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (2 sub-cards) | — | unchanged | ✓ |
| `GlobChild` / `GlobChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (single card) | — | unchanged | ✓ |
| `WebFetchChild` / `WebFetchChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (single card) | — | unchanged | ✓ |
| `WebSearchChild` / `WebSearchChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (results list) | — | unchanged | ✓ |
| `AskUserQuestionChild` / `AskUserQuestionChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (Q&A list) | — | unchanged | ✓ |
| `AgentChild` / `AgentChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (progress + output cards) | — | unchanged | ✓ |
| `GenericChild` / `GenericChildLayout` | Pure-value | value/MDL | bridge / child layout | layout cache | ctor-injected | none (header-only, `totalHeight==0`) | — | unchanged | ✓ |

---

## Model value types (`Model/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Block` (+ `Block.Kind`, `ToolGroupBlock`, `Block.Child`, `ToolStatus`, `ListBlock`) | Pure-value | value/MDL | bridge (`MessageEntryBlockBuilder`/`MarkdownToBlocks`) + pipeline | `Coordinator.blocks: [Block]` (single source of truth — §3.1) | n/a | none (caller-supplied `id: UUID` drives identity — §2.18) | — | unchanged | ✓ |
| `InlineNode` | Pure-value | value/MDL | upstream Markdown parser | embedding `Block.Kind` | n/a | none (recursive inline IR; block layer holds, does not parse) | — | unchanged | ✓ |

---

## SwiftUI sheet bodies (`Sheets/`) — the only hosting boundary in scope

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `UserBubbleSheetView` | SwiftUI-view | SU-View | `Transcript2SheetPresenter` via `NSHostingController` in `beginSheet` | sheet (modal lifetime) | ctor-injected (request value) | injected closure (Done dismiss) | D (modal-sheet host, BOUNDARY-SPEC §1) | unchanged | ✓ |
| `ImagePreviewSheetView` | SwiftUI-view | SU-View | `Transcript2SheetPresenter` via `NSHostingController` in `beginSheet` | sheet (modal lifetime) | ctor-injected (request value) | injected closure (Done dismiss) | D (modal-sheet host) | unchanged | ✓ |

---

## Bridge — entry→Block translation (`NativeTranscript2Bridge/`)

All translators / feed sources. The bridge is the AppKit-side render channel
(REFACTOR-PLAN §6 Rule 3); the backfill pipeline is the cold-load bypass channel
(§2.6). Parity is do-not-touch (§10.4: history never goes through bridge, load has no
`.update`, cross-page withhold + doc-order).

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Transcript2EntryBridge` | Session-core | translator | `Session.init` (`Session.swift:167`) | `Session` (session-lifetime; wired to runtime once at init/promotion) | closure sink (`onMessagesChange` → `bridge.apply`) | imperative controller call (`controller.apply(change)`) | — | unchanged | ✓ |
| `TranscriptBackfillPipeline` | Per-load | translator | `Session.loadHistory()` (`Session.swift:551`) | `Session` (single cold load; bypasses bridge) | ctor-injected (reverse page source + controller + width) | imperative controller call (`controller.apply` `.append`/`.prepend` with `precomputed:`) | — | unchanged | ✓ |
| `MessageEntryBlockBuilder` | Per-load | translator | bridge + pipeline (caseless `enum`) | none (stateless) | ctor-injected | none (`MessageEntry` → `[Block]`) | — | unchanged | ✓ |
| `ToolUseToChild` | Per-load | translator | builder (caseless `enum`) | none (stateless) | ctor-injected | none (`ToolUse`/`ToolResult` → `Block.Child` incl. `errorText`) | — | unchanged | ✓ |
| `MarkdownToBlocks` | Per-load | translator | builder (caseless `enum`) | none (stateless) | ctor-injected | none (markdown IR → `[Block]`) | — | unchanged | ✓ |
| `StreamingMarkdownCommit` | Per-load | translator | bridge (caseless `enum`) | none (stateless) | ctor-injected | none (incremental streamed-markdown commit) | — | unchanged | ✓ |
| `StableBlockID` | Pure-value | translator | bridge/builder (caseless `enum`) | none (stateless deterministic id derivation) | ctor-injected | none (stable `UUID` from message coordinates) | — | **PR-A3 (const only)** — P14 cross-file constant extraction (scheme referenced ×3, §8 P14); behavior-preserving, snapshot-guarded | ✓ |
| `JSONLReversePageSource` | Per-load | actor-SVC | `TranscriptBackfillPipeline` | pipeline (single cold load) | ctor-injected (file URL) | closure sink (yields reverse pages) | — | unchanged | ✓ (`@unchecked Sendable` reverse-page producer) |
| `ReverseLineReader` | Per-load | translator | `JSONLReversePageSource` | reverse page source | ctor-injected (file handle) | none (reverse line iteration) | — | unchanged | ✓ |
| `PipelineInbox` | Per-load | translator | `TranscriptBackfillPipeline` | pipeline (single cold load) | ctor-injected | closure sink (main-owned buffer of pre-built pages) | — | unchanged | ✓ (`@unchecked Sendable` off-main→main buffer) |

---

## Non-conformant / design defects

**None.** Every type in the transcript renderer + bridge scope places cleanly in the
fixed schema with a single owner, a clear data-in channel (ctor-injected snapshots or
closure sink), a clear emit channel (imperative controller call, injected closure, or
`none` for pure values), and either no hosting boundary or a correct regime-D sheet
host. This is expected: the scope is the most disciplined part of the codebase, and
the plan keeps it entirely behind the do-not-touch wall (REFACTOR-PLAN §10.1–§10.4,
§11 "合并 Controller+Coordinator" explicitly rejected).

### Observations (not defects — documentation drift to fix elsewhere, no code change here)

1. **`LoadingPillUsageView` mislabeled as SwiftUI.** `analysis-component-tree.md` /
   REFACTOR-PLAN §2 call it "唯一的 SwiftUI 叶子" inside the transcript. Source is
   `final class LoadingPillUsageView: NSView` (`AppKit/LoadingPillUsageView.swift:29`)
   — a pure self-drawn `NSView`, **not** a SwiftUI leaf and **not** a hosting boundary.
   The transcript therefore contains *zero* embedded SwiftUI leaves; its only
   SwiftUI surface is the two `Sheets/` bodies (regime D). This is a doc-drift fix
   (out-of-scope for this scope's code; flag for the doc-cleanup PR, plan §8 P12),
   not a design defect.

2. **`Controller` vs `Coordinator` two-type split is intentional and conformant.**
   Both place cleanly (Controller = @Observable-SVC host surface, Coordinator =
   AK-NSObject table delegate). The merge is explicitly rejected (NativeTranscript2
   §1.1; REFACTOR-PLAN §11). Not a dual-layer straddle — the layer boundary is the
   host-surface/table-delegate seam, and each type is on exactly one side.

3. **`Transcript2SheetPresenter` is the one per-attach lifetime type in this scope**
   (reinstantiated per session attach by the chat VC; demo VCs own one for life).
   It places cleanly as Per-attach / regime-D host. Its construction site
   (`ChatSessionViewController.attachSession`) is touched by PR-D (TranscriptSwapCoordinator
   extraction, plan §8 P5: "per-attach scroll/presenter" move to the coordinator) —
   but that is a *change to the constructing VC*, not to the presenter class itself;
   the presenter's row stays `unchanged`. Recorded here so the seam is explicit.
