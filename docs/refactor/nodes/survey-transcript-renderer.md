# Survey: NativeTranscript2 renderer (Controller / Coordinator / Layout / AppKit / Sheets)

Scope: `macos/ccterm/Content/Chat/NativeTranscript2/` — the host-facing `Transcript2Controller`,
the AppKit-facing `Transcript2Coordinator`, the two sibling coordinators (Selection / Search),
the AppKit shell (`AppKit/*`), the layout dispatch (`Layout/RowLayout.swift` + samples),
`Model/Block.swift`, and `Sheets/*` + `Transcript2SheetPresenter`.

This survey treats the renderer's **§2 performance contract** (NativeTranscript2/CLAUDE.md) as
fixed. Nothing below proposes weakening it. Findings are limited to structural / API / data-flow
clarity issues that are safe to change without touching perf-critical machinery.

FACT = visible in the code at the cited line. INFERENCE = my read.

---

## 1. Component / type inventory

### Host-facing surface

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Transcript2Controller` | `@MainActor @Observable final class` | Imperative command channel + `@Observable` mirror surface for hosts. Owns the coordinator. | Transcript2Controller.swift:42 |
| `Transcript2Controller.Change` | `enum (Sendable)` | Structural mutation vocabulary (`prepend`/`append`/`replace`/`remove`/`update`). Intrinsic-position only. | Transcript2Controller.swift:49 |
| `Transcript2Controller.PrecomputedLayouts` | `struct (Sendable)` | Off-main `(id, RowLayout)` + width, installed as cache hits before a structural change. | Transcript2Controller.swift:73 |
| `Transcript2Controller.ScrollState` | `enum (Sendable, Equatable)` | Scroll intent around an apply (`none`/`top`/`bottom`/`saveVisible`). | Transcript2Controller.swift:79 |
| `Transcript2Controller.InitialAnchor` | `enum (Sendable, Equatable)` | First-screen scroll anchor (`bottom`/`top`/`bottomTo`). | Transcript2Controller.swift:97 |
| `Transcript2Controller.SearchState` | `struct (Equatable, Sendable)` | `@Observable`-mirrored search snapshot (query / total / current). | Transcript2Controller.swift:137 |

### AppKit-facing engine

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Transcript2Coordinator` | `@MainActor final class : NSObject, NSTableViewDataSource, NSTableViewDelegate` | Single source of truth (`blocks`), layout cache + lazy/off-main layout, structural dispatch, scroll-anchor math, status/fold/turn-usage state, hover, gutter dispatch. ~1764 lines. | Transcript2Coordinator.swift:63 |
| `Transcript2Coordinator.CachedLayout` | `private struct` | `(width, RowLayout)` cache entry. | Transcript2Coordinator.swift:189 |
| `Transcript2Coordinator.ScrollAnchor` | `private struct` | Captured anchor row + reference Y for `.saveVisible`. | Transcript2Coordinator.swift:587 |
| `Transcript2SelectionCoordinator` | `@MainActor final class : NSObject` | Cross-row selection algorithm; sparse `selections: [UUID: SelectionRange]`; window-key observer. | Transcript2SelectionCoordinator.swift:53 |
| `Transcript2SearchCoordinator` | `@MainActor final class : NSObject` | In-transcript ⌘F scan + nav + per-cell highlight push; `hits` + derived `hitsByBlock`. | Transcript2SearchCoordinator.swift:37 |
| `Transcript2SearchCoordinator.Hit` | `struct (Equatable, Sendable)` | One match (`blockId`, `range`). | Transcript2SearchCoordinator.swift:43 |
| `SearchHighlightSpec` | `struct (Equatable, Sendable)` | Per-hit paint spec consumed by the cell (`range`, `isCurrent`). | Transcript2SearchCoordinator.swift:264 |

### AppKit shell

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Transcript2ScrollView` | `final class : NSScrollView` | Responsive scrolling, forced `.overlay` scroller, `tile()` keeps table sized to clip width. | AppKit/Transcript2ScrollView.swift:10 |
| `Transcript2ClipView` | `final class : NSClipView` | Layer-backed `.never`-redraw clip. | AppKit/Transcript2ScrollView.swift:36 |
| `Transcript2TableView` | `final class : NSTableView, NSMenuItemValidation` | Negative-width clamp, live-resize hook → `refillLayoutCache`, `mouseDown` selection tracking loop, Copy/SelectAll edit menu. | AppKit/Transcript2TableView.swift:32 |
| `CenteredRowView` | `NSTableRowView` subclass | No-op row view; stable reuse key (§2.17). Not re-read here; referenced in `rowViewForRow`. | AppKit/CenteredRowView.swift (Coordinator.swift:1421) |
| `TranscriptScrollViewFactory` | `enum` (namespace) | Two-step `make` (unbound shell) / `bindData` (wire dataSource+observers) / `dismantle`. | AppKit/TranscriptScrollViewFactory.swift:33 |
| `Transcript2SheetPresenter` | `@MainActor final class` | Observes `pendingUserBubbleSheet` / `pendingImagePreview`, opens AppKit-native sheets wrapping SwiftUI bodies. | AppKit/Transcript2SheetPresenter.swift:33 |
| `Transcript2SheetPresenter.OpenSheetTag` | `private enum (Equatable)` | Identity tag for the open sheet (userBubble/imagePreview UUID). | AppKit/Transcript2SheetPresenter.swift:40 |
| `BlockCellView` | `NSView` (self-drawn, `override draw`) | Per-row cell; `layout.draw`, hit testing, selection paint, hover tracking, subview-plan reconcile. (Not in survey scope detail, but referenced widely.) | AppKit/BlockCellView.swift |

### Sheet-request models + bodies

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `UserBubbleSheetRequest` | `struct (Identifiable, Equatable, Sendable)` | id + untruncated text for the full-message sheet. | AppKit/Transcript2SheetPresenter.swift:7 |
| `ImagePreviewRequest` | `struct (Identifiable, Equatable)` | per-request UUID + NSImage for the preview sheet. | AppKit/Transcript2SheetPresenter.swift:18 |
| `UserBubbleSheetView` | `SwiftUI View` | Full-text body; `Text.textSelection(.enabled)` + Done. | Sheets/UserBubbleSheetView.swift:8 |
| `ImagePreviewSheetView` | `SwiftUI View` | Aspect-fit image preview + Done; tap-to-dismiss. | Sheets/ImagePreviewSheetView.swift:10 |

### Layout dispatch + model

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `RowLayout` | `enum (@unchecked Sendable)` | Type-erased per-kind layout; uniform `totalHeight` / `measuredWidth` / `draw` / `selectionAdapter` / `interactiveHits` / `subviewPlan`. | Layout/RowLayout.swift:64 |
| `InteractiveHit` | `struct (Sendable)` | One hot zone (rect + `HitAction`) in layout-local coords. | Layout/RowLayout.swift:8 |
| `HitAction` | `enum (Sendable, Equatable)` | Click outcomes (openURL / openUserBubbleSheet / openImagePreview / copy / toggleFold). | Layout/RowLayout.swift:17 |
| `SelectionAdapter` | `struct + closures` | Per-layout selection-facing API; no protocol. | Layout/SelectionAdapter.swift:81 |
| `LayoutPosition` | `enum (Equatable, Hashable)` | Opaque per-layout position tag (text/cell/listItem/diff/textCard). | Layout/SelectionAdapter.swift:14 |
| `SelectionRange` / `SearchableRegion` | `struct` | Selection endpoint pair / searchable plain-text band + position closure. | Layout/SelectionAdapter.swift:45,67 |
| `Block` / `Block.Kind` | `struct / enum (@unchecked Sendable)` | Render-ready row datum; caller-supplied stable `id`; 12 kinds incl. `loadingPill`. | Model/Block.swift:11,15 |
| `ToolGroupBlock` / `ToolGroupBlock.Child` | `struct / enum (Equatable, Sendable)` | Tool-group payload + three-state titles; closed child enum. | Model/Block.swift:134,185 |
| `ToolStatus` | `enum (Equatable, Sendable)` | Runtime status (completed/running/failed/cancelled); stored on coordinator, not on Block. | Model/Block.swift:343 |
| `BlockStyle` | `enum (Sendable)` (namespace) | All typography + per-kind geometry constants + attributed builders + width clamp. ~1000+ lines. | Model/Block.swift:430 |
| `ListBlock` / `TableBlock` | `struct (Equatable, Sendable)` | List/table payloads. | Model/Block.swift:372,408 |

---

## 2. Component tree (this area)

Hosting / nesting. `[AK]` = AppKit, `[SUI]` = SwiftUI. Host-sizing options noted at each
`NSHostingController` / `NSHostingView` boundary.

```
ChatSessionViewController [AK NSViewController]          (App/AppKit/ChatSessionViewController.swift)
│   owns per session-attach:
├── session.controller : Transcript2Controller [@Observable, owned by Session — NOT by the VC]
│      └── coordinator : Transcript2Coordinator [AK, NSObject]
│             ├── selection : Transcript2SelectionCoordinator [AK, NSObject]   (let, owned)
│             ├── search    : Transcript2SearchCoordinator    [AK, NSObject]   (let, owned)
│             └── highlightStorage : Transcript2HighlightStorage              (let, owned)
│
├── transcriptScroll : Transcript2ScrollView [AK]    (built by TranscriptScrollViewFactory.make)
│      └── contentView : Transcript2ClipView [AK]
│             └── documentView : Transcript2TableView [AK]
│                    ├── dataSource/delegate ──► coordinator  (wired by factory.bindData)
│                    ├── weak coordinator ref  ──► coordinator
│                    └── rows: BlockCellView [AK, self-drawn]   (one per Block)
│                           └── (optional) ToolGroupEntryView / CAShapeLayer / shimmer / loading dots
│                                 — reconciled from RowLayout.subviewPlan
│                                 LoadingPillUsageView [AK] hosts live token counter
│
├── transcriptSheetPresenter : Transcript2SheetPresenter [AK]   (per-attach, owned by VC)
│      └── on demand: NSWindow(contentViewController:
│             NSHostingController<UserBubbleSheetView | ImagePreviewSheetView> [SUI])
│             presented via parent.beginSheet (AppKit-native modal)
│
├── topScrim / bottomScrim : Transcript*ScrimView [AK]   (overlays, hitTest passthrough)
└── composeOrBarHost : NSHostingView<AnyView> [SUI]   (chat resting bar; bottom-anchored,
        sizingOptions = [.intrinsicContentSize] per Chat/CLAUDE.md component-host rule)

Demo hosts (TranscriptDemoVC / PerfDemoVC / StressVC) [AK] mirror the same shape:
each constructs/owns its own Transcript2Controller + scroll + Transcript2SheetPresenter.
```

Key boundary facts:
- The transcript scroll/clip/table subtree is **100% AppKit** — no `NSHostingView` inside it.
  SwiftUI appears only at the two leaf surfaces: the sheet bodies and the loading-pill usage view.
- The host VC does **not** own the controller — `Session` owns it (Chat/CLAUDE.md ownership graph;
  Session.swift:166/190/213/237). The VC owns only the scroll view + sheet presenter + observation
  task, all re-instantiated per attach.

---

## 3. Data flow

### State entry (downward)

1. **Structural mutations** enter exclusively through `Transcript2Controller.apply(_:scroll:precomputed:)`
   (Transcript2Controller.swift:239), which forwards to `coordinator.apply([...])`
   (Transcript2Coordinator.swift:321). The coordinator owns `blocks: [Block]` (the single source of
   truth, Transcript2Coordinator.swift:180) and dispatches each `Change` to `applyStructuralChange`
   (Transcript2Coordinator.swift:366).
2. **Status / fold / turn-usage** bypass `Change.update` by design (§2.13, §2.13b) and write sparse
   coordinator dicts directly: `setStatus` (Transcript2Coordinator.swift:950), `toggleFold` (:867),
   `setTurnUsage`/`setTurnStartedAt` (:1016/:1027). Controller forwards (`setToolStatus` :365,
   `setTurnUsage` :379). These do a single-row `reloadData(forRowIndexes:)` with no `noteHeightOfRows`.
3. **Loading pill** is controller-side logic (not a forward): `setLoading` (:280) →
   `reconcileLoadingPill` (:317) inserts/removes a `.loadingPill` Block through the normal `apply`.
4. **Search** enters via `runSearch`/`next`/`previous`/`endSearch` (:448–462) → `coordinator.search.*`.
5. **Off-main precompute** (backfill pipeline producer, `refillLayoutCache`, `scheduleLayoutWarm`)
   precomputes `RowLayout`s and lands them through the *same* `apply`/`cacheLayouts` path
   (Transcript2Coordinator.swift:704). It is never a second mutation channel (Invariant §3.1).

### State egress (upward, to SwiftUI hosts)

The Controller is the **only** `@Observable` surface (the coordinator is `NSObject`, not observable):
- `coordinator.onBlockCountChanged` (closure, :68) → `controller.blockCount` (:109).
- `coordinator.search.onStateChanged` (:56) → `controller.refreshSearchState()` → `controller.searchState` (:134).
- `coordinator.onUserBubbleSheetRequested` / `onImagePreviewRequested` (:78/:86) →
  `controller.pendingUserBubbleSheet` / `pendingImagePreview` (:119/:127).
- `controller.onFirstScreenReady` (:430) — `@ObservationIgnored` synchronous closure to the host VC.
- `controller.onLayoutWidthDidSettle` lives on the **coordinator** (:95) and is consumed by the
  backfill pipeline, not by SwiftUI.

### Event flow (clicks, hover, selection)

- Cell `mouseDown` resolves an `InteractiveHit` → `HitAction` (Layout/RowLayout.swift:17) → calls
  back into `coordinator` (`toggleFold`, `requestUserBubbleSheet`, `requestImagePreview`, copy,
  open URL). The cell holds a non-weak back-ref `cell.coordinator = self`, reinjected every `viewFor`
  (Transcript2Coordinator.swift:1491).
- Selection drag runs a private event loop inside `Transcript2TableView.trackSelection`
  (AppKit/Transcript2TableView.swift:125) feeding `coordinator.selection.updateSelection`.
- Hover is coordinator-owned single source of truth: `hoveredBlockId` (:1594), `isLiveScrolling` (:1617).

### Direction summary

Mostly clean one-way fan-out: `host → Controller → Coordinator → AppKit cells → Layout → Model`,
with egress only as closures the Controller turns into `@Observable` writes. The documented downward
dependency rule (NativeTranscript2/CLAUDE.md §6: `host VC → Controller → Coordinator → AppKit/ →
Layout/ → Model/`) holds: I found no Layout/Model file importing or naming the coordinator/controller,
and the sheet bodies under `Sheets/` are imported only by the presenter.

### BIDIRECTIONAL / back-channel coupling (marked)

- **Coordinator ⇄ Selection/Search coordinators** are mutually referential by design: the coordinator
  *owns* them (`let selection`/`let search`, :100/:106) but they hold a `weak transcript:
  Transcript2Coordinator?` back-ref (SelectionCoordinator.swift:54, SearchCoordinator.swift:38) and
  reach back through helper methods (`block(atRow:)`, `selectionAdapter(...)`, `markCellNeedsDisplay`,
  `markCellSearchDirty`, `scrollRowToTopPublic`, `expandForSearchHit`). This is the documented pattern,
  but it is genuinely cyclic and the surface is wide (≈8 coordinator methods exist *only* to serve the
  two siblings — see smell S4).
- **Cell → Coordinator back-ref** (`cell.coordinator`, non-weak, reinjected per `viewFor`) is a hidden
  upward edge from AppKit cells into the coordinator. Necessary for click dispatch; acceptable but worth
  noting it violates the "downward only" headline if read literally (cells are AppKit, coordinator is one
  layer up).
- **Bridge → Coordinator** reaches *past* the Controller in 3 of 6 call sites (see smell S1).

---

## 4. Ownership & lifetime

- **`Transcript2Controller`** is constructed and retained by **`Session`** (Session.swift:166/190/213/237),
  one per session, surviving view mount/dismount. Demo VCs each construct/own one
  (TranscriptDemoVC init :30; PerfDemoVC :31; StressVC :32). Torn down with the Session; has a
  `nonisolated deinit {}` macOS-26 workaround (:218).
- **`Transcript2Coordinator`** is `let coordinator` on the Controller (Transcript2Controller.swift:148),
  constructed in `Controller.init` (:191). Lifetime == Controller. `nonisolated deinit {}` (:165).
- **`selection` / `search` / `highlightStorage`** are `let` on the Coordinator, constructed in
  `Coordinator.init` (:150–152). Their `weak transcript` back-ref is set immediately after `super.init`
  (:154/:155). `highlightStorage.onDidFill` closure captures `[weak self]` (:156).
- **`tableView`** is a **weak** ref on the coordinator (:64), wired by `factory.bindData` (:127) and
  nilled by `factory.dismantle` (:147). The table holds the coordinator strongly via `dataSource` /
  `delegate` until `dismantle` removes them — wait: `dismantle` only nils the coordinator's `tableView`
  and removes observers; it does **not** clear `table.dataSource`/`delegate`. The table is then
  `removeFromSuperview`'d by the host and deallocated, releasing the coordinator ref. (INFERENCE: fine
  because the host always drops the scroll view right after dismantle — attachSession:455, :515.)
- **`Transcript2ScrollView` (+ clip + table)** is constructed by `factory.make` (:48), owned by the host
  VC (`transcriptScroll`, ChatSessionViewController.swift:79), and dismantled per swap
  (attachSession:453, finishTranscriptFadeOut:503, tearDownTranscript:514).
- **`Transcript2SheetPresenter`** is constructed per attach (ChatSessionViewController.swift:402;
  demo VCs :99/:46/:49), owned by the host VC, torn down via `stop()` (:519) before the prior one is
  replaced (:401). Captures `controller` strongly and `hostView` weakly (:48). Its observation `Task`
  captures `controller` + `[weak self]` to avoid the retain cycle documented at :80–86.
- **SelectionCoordinator window-key observer** (`NotificationCenter.addObserver(self, ...)`,
  SelectionCoordinator.swift:61) is registered on `self` (the SelectionCoordinator) and removed in its
  own `deinit` (:69). It is **not** affected by `factory.dismantle`'s blanket
  `removeObserver(coordinator)` (which targets the *Coordinator*, a different object). FACT, and correct.

---

## 5. Smells / debt

### S1 — Bridge reaches past the Controller to `controller.coordinator.apply(...)` — MEDIUM
`Transcript2EntryBridge` uses the Controller's `apply` in 3 sites and bypasses it to
`controller.coordinator.apply(...)` in 3 others (Transcript2EntryBridge.swift:335, :350, :394 vs
:299, :357, :365). The two are identical except the Controller variant fires `onBlockCountChanged`
→ `reconcileLoadingPill` and accepts `precomputed`. Mixing them in one file is an inconsistency: a
reader cannot tell from the call site whether the pill re-pins after this change. INFERENCE: the
direct-coordinator calls were chosen because the affected changes (`.update`-only, `.remove`,
prefix `.update`s) can't move the pill off the tail — but that reasoning is undocumented at the call
sites and is exactly the kind of invariant a refactor will silently break. **Safe fix:** route all
six through `controller.apply` (with a variadic/array overload), or document why three bypass it.
The Controller's `apply` is `func apply(_ changes: Change..., ...)` (variadic, :239) while the
coordinator's is `apply(_ changes: [Change], ...)` (array, :321) — the bridge passes arrays, which is
*why* it reaches for the coordinator. Adding an array overload on the Controller removes the entire
reason to bypass it.

### S2 — `Transcript2Coordinator` is a ~1764-line god object — MEDIUM
Transcript2Coordinator.swift:63–1764. It currently carries: source-of-truth data, layout cache,
lazy + off-main + warm layout pipelines, structural dispatch, scroll-anchor math, fold state, status
state, turn-usage state, user-bubble/image sheet routing, width-change invalidation, gutter dispatch,
hover single-source-of-truth, live-scroll gating, and all the NSTableView delegate callbacks. The
CLAUDE.md (§1.1) explicitly defends Controller-vs-Coordinator *not* being merged, but says nothing
about splitting the Coordinator itself. Several cohesive clusters could become `extension` files (or
small owned helpers) without touching the perf contract or the public surface:
- hover + live-scroll (`hoveredBlockId`, `isLiveScrolling`, `scrollViewWill/DidStartLiveScroll`,
  `reevaluateHoverFromMouseLocation`, `markGutterRedraw`) — :1580–1673.
- the off-main warm pipeline (`pendingWarmLayouts`, `scheduleLayoutWarm`, `drainLayoutWarm`,
  `warmCandidateIds`) — :1292–1384.
- scroll-anchor math (`withScrollAdjustment`, `captureAnchor`, `applyAnchor`, `scrollRowToTop/Bottom`)
  — :551–689.
These are file-organization moves (Swift `extension`s in the same module), not behavioral changes;
the load-bearing inline ordering stays intact because the methods don't move relative to their callers.

### S3 — `BlockStyle` mixes typography, geometry, color, and the width clamp in one ~1000-line enum — LOW
Model/Block.swift:430–1489 (truncated). It is the de-facto theme + geometry + layout-math namespace.
`clampedLayoutWidth` / `cellOriginX` (:1106/:1114) are *layout algorithm*, not style, yet they live
beside font and color constants. Splitting `BlockStyle` into `BlockStyle` (typography/color) +
`BlockGeometry` (paddings, widths, clamp) would clarify which constants are perf-load-bearing (the
width clamp keys the cache — §2.4/§2.19) vs purely cosmetic. LOW because it is pure constants, no
runtime risk, and the perf contract cites specific symbols by name.

### S4 — Wide back-channel surface from the sibling coordinators into the parent — MEDIUM
The two sibling coordinators reach back into `Transcript2Coordinator` through a sprawling set of
public helpers that exist *only* for them: `block(atRow:)`, `block(forId:)`, `selectionAdapter(atRow:)`,
`selectionAdapter(forBlockId:)`, `markCellNeedsDisplay`, `markCellSearchDirty`, `expandForSearchHit`,
`scrollBlockIntoView`, `scrollRowToTopPublic`, `blockIds` (Transcript2Coordinator.swift:1536–1761,
:222). These are `internal` (default) so any module code can call them, blurring the "this is the
selection/search back-channel" intent. INFERENCE: a focused protocol (e.g.
`TranscriptSelectionHost` / `TranscriptSearchHost`) the coordinator conforms to and the siblings
hold instead of the concrete `weak transcript: Transcript2Coordinator?` would (a) narrow the surface
to exactly what each sibling needs and (b) make the cyclic dependency explicit and minimal. This is
the cleanest *unidirectional-ization* lever in the area. (Caution: the CLAUDE.md elsewhere prefers
"struct + closures over protocols" for the layout adapters — but that rule is about *enum
exhaustiveness for layout kinds*, not about narrowing a class back-channel; a host protocol here does
not lose any exhaustiveness checking.)

### S5 — Controller forwards are inconsistent in thickness — LOW
Most Controller methods are thin forwards (`apply`, `scrollToTail`, `setToolStatus`, `setTurnUsage`,
`runSearch`/`next`/`previous`/`endSearch`, `attachSyntaxEngine`, `setHistoryBackfilling`), but a few
carry real logic (`setLoading` + `reconcileLoadingPill`, `refreshSearchState`, the first-screen latch).
CLAUDE.md §1.1 acknowledges this and even suggests "make the forwards thinner (e.g. expose
`coordinator.search` as a property)". Today `coordinator` is exposed as a `let` (:148) but `coordinator.search`
is also reachable, so the four search forwards (:448–462) are pure indirection that the bridge already
bypasses elsewhere. LOW; the asymmetry is documented and intentional, but it is a real "why is this
here" cost for new readers.

### S6 — `pendingUserBubbleSheet` is mutated from three directions — LOW/MEDIUM
The field is written by the coordinator's request closure (Transcript2Controller.swift:203), and also
**directly nil'd by the presenter** in `presentBubble`'s window-missing guard (:135),
`beginSheet` completion (:150), and `dismissOpenSheet`. So the Controller's `@Observable` request
field is co-owned by two objects (Controller closures + Presenter). The presenter even guards against
"the field being mutated between observation and reconcile" (:118–127), evidence that this co-ownership
is racy enough to need defensive re-checks. INFERENCE: a cleaner shape is request-in / ack-out — the
presenter signals completion via a method (`controller.didDismissUserBubbleSheet(id:)`) that the
Controller turns into the nil-write, keeping the field single-writer. This is safe to change (pure
plumbing) and removes the "who cleared it" ambiguity. MEDIUM only because sheets are a rare path.

### S7 — `requestImagePreview` / `requestUserBubbleSheet` asymmetry — LOW
`requestUserBubbleSheet(id:)` (Transcript2Coordinator.swift:1097) looks up the block and re-extracts
the text from `Block.Kind.userBubble`, while `requestImagePreview(image:)` (:1108) just forwards the
NSImage the cell already handed it. Both are coordinator methods called from the cell's `HitAction`
dispatch. Minor inconsistency: one re-resolves from the source of truth, the other trusts the cell's
payload. Not a bug (the image is immutable per Block contract), but the two should pick one pattern.

### S8 — `scrollToInitialAnchor` double-duties as both "scroll to tail" and "record settled width" — LOW
Transcript2Coordinator.swift:1152. It is the canonical scroll-anchor entry, but it *also* opportunistically
writes `lastLayoutWidth` (:1161–1164) because `tableFrameDidChange` "can miss the first attach". This
side effect inside a scroll method is surprising; the comment explains it but it couples width-capture
to scroll timing. A dedicated `recordSettledWidth()` called from `bindData`/`scrollToTail` would be
clearer. LOW — it is correct and load-bearing for the warm cache; flagged only for clarity.

### S9 — Two near-identical "find host row for id (block or child)" scans — LOW
`toggleFold` (:876), `setStatus` (:961), and `clearAllRunningStatuses` (:1069) each re-implement the
same `blocks.firstIndex { block.id == id || (toolGroup children contains id) }` search. Extracting one
`private func hostRow(forSurfaceId:) -> Int?` removes the triplication and the risk of the three
drifting. Pure refactor, no behavior change.

---

## 6. Load-bearing invariants a refactor MUST preserve

These are the constraints that pin the area; the §2 performance contract is the authority and is
**not** to be weakened. Listed here so an over-eager refactor of *structure* doesn't break *behavior*.

1. **Single source of truth = `Transcript2Coordinator.blocks: [Block]`** (Transcript2Coordinator.swift:180).
   No `rows` mirror, no `pendingBlocks` side path. All off-main producers feed the same `apply` /
   `cacheLayouts` (§3.1). Any extracted helper must still mutate `blocks` only through
   `applyStructuralChange`.
2. **`apply(_:scroll:precomputed:)` is the sole structural mutation entry** (Controller :239 →
   Coordinator :321 → `applyStructuralChange` :366). Status/fold/turn-usage/search deliberately bypass
   `Change.update` and MUST keep doing so (§2.13, §2.13b) — routing them through `.update` re-typesets,
   drops selection/highlights, and forces `noteHeightOfRows`.
3. **Two-step attach: `factory.make` (unbound) → host `layoutSubtreeIfNeeded()` → `factory.bindData`
   → `scrollToTail`** (factory:48/:99; ChatSessionViewController.swift:341–386). One source-phase tick
   = one width per id (§2.19), guarded by `TranscriptReentryLayoutCacheTests` /
   `TranscriptHostReentryLayoutCacheTests`. Do not bind the dataSource inside `make`, reorder
   `layoutSubtreeIfNeeded` after `bindData`, or insert an extra tile before settle.
4. **`makeLayout` stays `nonisolated static`** (Transcript2Coordinator.swift:761). Off-main precompute
   (`refillLayoutCache` :1245, `drainLayoutWarm` :1366, backfill producer) depends on actor-free layout.
   Any new layout arm must remain actor-free and read only from the passed snapshot dicts.
5. **Layout is a pure function of `(block, width, state)`; state is an input, not a stored field**
   (§3.2). Fold/status/turn-usage live in coordinator sparse dicts and are threaded through `makeLayout`.
   Cache entries are derived — `removeCachedLayout` is always safe, `heightOfRow` lazy-recomputes.
6. **`layoutCache` is width-keyed; cross-width entries are misses, never corruption** (:187, :712, :730).
   `cacheLayouts` anti-poison skip (:712) must survive any refactor of the warm/refill pipelines.
7. **`Block.id` is caller-supplied stable identity** (Model/Block.swift:12; §2.18). The cache, diff,
   selection, search, highlight scope, fold state, and status state are all keyed by it. Never derive
   ids from content.
8. **Scroll-origin writes need `reflectScrolledClipView` follow-up** (`scrollRowToTop/Bottom`
   :655/:688; autoscroll :194) and `.saveVisible` mutations must stay wrapped in
   `NSAnimationContext.duration=0 + allowsImplicitAnimation=false + CATransaction.setDisableActions(true)`
   (:574–584). The forced in-tick `layoutSubtreeIfNeeded` before `applyAnchor` in `refillLayoutCache`
   (:1286) is load-bearing (§2.7).
9. **The Controller is the only `@Observable` surface; the Coordinator is `NSObject`** (§1.1). Hosts
   observe `blockCount` / `searchState` / `pendingUserBubbleSheet` / `pendingImagePreview` /
   `loadingPillVisible` on the Controller. A refactor must not move observable state down into the
   coordinator or merge the two classes (explicitly forbidden, §1.1).
10. **`factory.dismantle`'s blanket `removeObserver(coordinator)` is intentionally aggressive**
    (factory:145) and is why the host flushes a parked outgoing scroll *before* re-binding the same
    session (ChatSessionViewController.swift:298–306). Any change to observer registration must keep the
    SelectionCoordinator's window-key observer (registered on `self`, removed in its own deinit) out of
    that blanket removal.
11. **`Transcript2SheetPresenter` observation task must not retain `self` across the
    `withCheckedContinuation` suspension** (:80–101) — the documented leak fix. The presenter is
    re-instantiated per attach; `stop()` must precede replacement (:401).
12. **Sheet bodies stay SwiftUI; presentation stays AppKit-native (`beginSheet`)** so the host VC stays
    AppKit-rooted (Block.swift:48 note; §5 userBubble). Dismissal routes through an injected `onDismiss`
    closure, not `@Environment(\.dismiss)` (Sheets/*:7/:9).
