# Design: Incremental migration plan — sequencing, risk, tests, parity

Turns the target component tree + data-flow cleanups (P1–P15 from
[analysis-component-tree.md](analysis-component-tree.md)) into an **ordered,
shippable-at-every-step** migration. Each step gives scope, dependencies on
prior steps, risk level, the merge-gate tests that protect it, new tests to add,
and rollback safety.

Source root abbreviated `…` = `macos/ccterm`. This plan is grounded against the
four CLAUDE.md docs (root runloop model; Chat UI; Session runtime; NativeTranscript2
§2 perf contract + §2.19 attach contract) and the 12 subsystem surveys.

> **Note on inputs.** The component-tree analysis is the synthesized cross-cutting
> doc; the separate `analysis-data-flow.md` / `analysis-dependencies.md` /
> `analysis-pain-points.md` files referenced in the task do **not** exist on disk
> (only `analysis-component-tree.md` plus the 12 surveys). The component-tree
> analysis already folds data-flow, dependency, and pain-point findings into its
> §3 (ownership) and §4 (ranked problems P1–P15), so this plan grounds against
> those plus the surveys directly. No conclusion below depends on the missing files.

---

## 0. Guiding principles for the sequence

1. **The data flow is already mostly clean.** Per analysis §Executive-summary, the
   two spines (selection + session/render) are unidirectional and well-layered. This
   is **not a rewrite** — it is a sequence of small extractions, dedup, and
   boilerplate collapse. Reject any step that re-architects a working spine.
2. **Lowest-risk-highest-leverage first; touch the load-bearing AppKit choreography
   last, behind green merge gates.** Mechanical, compiler-or-test-protected changes
   go first (they shrink surface and de-risk later steps). The transcript-swap /
   crossfade / attach-contract code is touched only at the very end, and only with
   the two reentry-layout merge gates green before and after.
3. **Shippable at every step.** Each step compiles, passes `make test-unit`, and is a
   self-contained PR. No step leaves the app in a half-migrated state across a merge
   boundary. No long-lived feature branch.
4. **Clean, not clever.** Several analysis items are explicitly *don't-gold-plate*
   (P9 façade boilerplate, P11 singleton reconciliation). Those are scoped down or
   dropped here, with the rejection stated.

---

## 1. LOAD-BEARING — do NOT touch (the invariant wall)

Every step below is designed *around* these. A step that appears to need one
relaxed is wrong — stop and redesign. Confirmation-required items are flagged.

### 1.1 Transcript §2 performance contract (user-confirm to weaken — NativeTranscript2 CLAUDE.md §2)
`NSTableView` + synchronous `heightOfRow` (§2.1); `wantsLayer + .onSetNeedsDisplay`
cell layer policy (§2.2); scroll/clip `.never` + responsive scrolling (§2.3);
`[UUID: CachedLayout]` no-LRU cache (§2.4); `nonisolated static makeLayout` off-main
purity (§2.5); off-main-built-then-sync-applied backfill (§2.6); `refillLayoutCache`
in-tick forced tile (§2.7); live-resize-visible-rows-only (§2.8); negative-width clamp
(§2.9); granular `insertRows`/`removeRows`, **never `reloadData()`** (§2.11); the
status/search/highlight channels that bypass `Change.update` (§2.12/§2.13/§2.13b);
`cacheLayouts` anti-poison (§2.14); per-scope generation guard (§2.15); shimmer
subpixel/image-cache techniques (§2.16). **No step in this plan enters the
transcript renderer's interior.** The closest any step gets is the *host* attach
sequence (Step 11), which is governed by §2.19 below.

### 1.2 §2.19 attach contract: one source-phase tick = one width per id
`present → attachSession` MUST run, in order: `factory.make` (unbound) →
`addSubview` + constraints → host `view.layoutSubtreeIfNeeded()` → `factory.bindData`
→ `controller.scrollToTail()`. The router MUST settle the child frame
(`layoutSubtreeIfNeeded`, `…/App/AppKit/DetailRouterViewController.swift:486`) BEFORE
`present`. Guarded by `TranscriptReentryLayoutCacheTests` (bare factory) +
`TranscriptHostReentryLayoutCacheTests` (real `ChatSessionViewController.present` →
`attachSession` end-to-end). **These two are the gate for Step 11.**

### 1.3 Runloop-tick orderings (root CLAUDE.md § macOS runloop tick model)
- Selection mutation is **synchronous + single-observer** in the click's source phase
  (chat-survey I1): `MainSelectionModel.select(_:)` writes `selection` then synchronously
  calls `selectionObserver?.selectionDidChange`. The router is the *sole* structural
  observer; the chat VC does NOT observe selection. Never revert to async
  `withObservationTracking` for structure (#195 regression).
- Crossfade structural work stays synchronous; only opacity defers (chat-I3). The
  build→settle→bind→`scrollToTail` runs inside the disabled-animation
  `CATransaction`/`NSAnimationContext` block; the alpha animation runs OUTSIDE it.
- Build-in-front-then-drop ordering (chat-I4): incoming transcript built + mounted in
  front, made live, THEN outgoing dismantled. No blank-pane flash.
- **Outgoing-scroll flush BEFORE bind on A→B→A re-entry (chat-I5).** `attachSession`
  calls `finishTranscriptFadeOut()` at its head, before the new `bindData`, because
  `dismantle` does a blanket `removeObserver(coordinator)` and a parked outgoing
  scroll for the SAME session shares the coordinator. **This is the single most
  fragile ordering in the whole app.** Step 11 preserves it verbatim.
- Draft-clear is imperative in the input bar (chat-I12); compose captures draft id by
  value not reactively (chat-I13). The synchronous `model.promote` teardown is why.

### 1.4 Session data-reaches-UI rules (Services/Session/CLAUDE.md)
One channel per piece of state (AppKit = synchronous closure push; SwiftUI =
`@Observable` pull). `Session` owns `controller` + `bridge` for its whole lifetime;
bridge wired once at `Session.init`/promotion, never at attach. History bypasses the
bridge via the off-main backfill pipeline. The `wireRuntimeMessagesSink` bridge-then-
external order, and the synchronous `onMessagesChange` fire, are load-bearing.

### 1.5 Deterministic teardown + macOS-26 deinit workaround
`DetailRouterChild.prepareForRemoval()` releases per-attach resources at swap time
(chat-I14); `nonisolated deinit {}` on every `@MainActor @Observable`/VC type
(chat-survey §4). Any new type these steps introduce carries both.

### 1.6 Sidebar invariants (sidebar survey §6 / analysis P3)
`SidebarItemNode` stays a reference type (identity-keyed row reuse); echo-suppression
(`isApplyingSelectionFromModel`) survives; selection writes go through `model.select(_:)`
not raw `selection`; per-row obs re-arm + recycle guard + non-allocating
`existingSession` survive.

### 1.7 Bridge/builder parity (analysis P7 / transcript-bridge survey)
History never flows through the bridge (bridge-I1); "no `.update` on load" (bridge-I9);
cross-page withhold buffer + doc-order parse (bridge-I8). The live `receive` and cold
`ReverseEntryBuilder` must produce identical grouping/pairing.

---

## 2. The migration at a glance

Ordered into four **phases**. Phase boundaries are natural "everything before me is
merged and green" checkpoints. Each step is one PR.

| # | Step | Phase | Problem | Risk | Primary gate test(s) |
|---|---|---|---|---|---|
| 1 | Delete dead `.environment` injections (`notifications`, `searchBus`) | A | P1 | **Trivial** | full `make test-unit`; manual smoke |
| 2 | Rename `searchEngine` → `syntaxEngine` (mechanical) | A | P10(b) | **Trivial** | compiler; full suite |
| 3 | Delete vestigial code paths (dir-completion, `ClaudeCodeStats`, dead `invalidate*`) | A | P13 | **Low** | `CustomCommandTests`, `ClaudeCodeStatsTests` (deleted with consumer-less code) |
| 4 | `Session.stopBackgroundTask` forwarder; `BackgroundTaskButton` stops piercing façade | A | P4 | **Low** | `SessionRuntimeTasksTests` + new `SessionFacadeTests` case |
| 5 | `DetailChildDependencies` struct + `injectAppEnvironment` helper | B | P2 | **Low-Med** | `DetailRouterContainmentTests`, `DetailRouterDraftRoutingTests`, full suite |
| 6 | `mountFillPaneHost` shared helper; un-erase `AnyView` at pane hosts | B | P12 (partial), S4 | **Low-Med** | `ArchiveViewSnapshotTests`, layout-diagnostics, full suite |
| 7 | Stale-name + doc-drift cleanup (`composeOrBarHost`→`restingBarHost`, doc edits) | B | P12 | **Trivial** | compiler; doc review |
| 8 | Extract `SidebarTreeModel` (pure tree builder) | C | P3 (part 1) | **Med** | new `SidebarTreeModelTests`; `SidebarTitleSanitizerTests`, snapshot |
| 9 | Extract `SidebarContextMenuController` + thin VC | C | P3 (part 2) | **Med** | snapshot + manual DnD/menu smoke |
| 10 | Unify live/cold grouping into one `EntryGroupingEngine` | C | P7 | **Med** | `TranscriptReverseBuilderTests`, `MessageEntryBlockBuilderTests`, bridge tests |
| 11 | Extract `TranscriptSwapCoordinator`; share crossfade helper | D | P5, P6, S9 | **HIGH** | `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests` (the gate) |
| 12 | Extract `SessionRuntime` self-contained projections (todos/tasks/usage) | D | P8 | **Med-High** | `SessionRuntimeTodosTests`, `…TasksTests`, `…StreamingTests`, `ContextUsageTests` |

**Explicitly dropped / deferred** (with rationale in §5):
P9 (façade forwarder boilerplate — *don't gold-plate*), P11 (singleton
reconciliation — judgment-call, low harm, deferred), P14/P15 (constant/layering nits —
opportunistic, fold into adjacent PRs, not standalone steps).

---

## 3. Phase A — mechanical, compiler/test-protected (zero behavior change)

These collapse the most surface for the least risk and **must land first** because
Steps 5/8 build on a smaller, drift-free dependency set.

### Step 1 — Delete dead SwiftUI-environment injections (P1)

**Scope.** Remove `.environment(notifications)` and `.environment(searchBus)` from the
five hosting boundaries. **Keep** the `notifications`/`searchBus` *stored props +
init params* on the VCs that actually use them through AppKit channels — only the dead
SwiftUI `.environment()` calls are deleted.

- FACT: no SwiftUI view reads either type (analysis P1 grep: `NotificationService.self`
  → 0; `@Environment(TranscriptSearchBus` → 0). `notifications` IS used by the router
  imperatively (`…/DetailRouterViewController.swift:162 onActivateSession`, `:173
  bootstrap`) — that stays. `searchBus` flows only through the toolbar bridge
  (`withObservationTracking`), never SwiftUI env.
- Sites: `…/DetailRouterViewController.swift:435` (demo), `…/ChatSessionViewController.swift:580-581`,
  `…/ComposeSessionViewController.swift:104-105`, `…/ArchiveViewController.swift:79-80`,
  `…/DraftSessionLandingViewController.swift:127-128`.

**Before → after** (each host):
```
.environment(sessionManager).environment(recentProjects)
.environment(\.syntaxEngine, …).environment(inputDraftStore)
.environment(notifications)   ← DELETE
.environment(searchBus)       ← DELETE
```
The consumed env set is exactly `SessionManager`, `RecentProjectsStore`,
`InputDraftStore`, `\.syntaxEngine`.

**Dependencies.** None. First step.
**Risk.** Trivial. A missed reader would be a runtime `@Environment` fatal on view
appear — but the grep proves there are zero readers, and the manual smoke (open chat /
compose / archive / draft-landing, send a message, trigger a notification, ⌘F search)
exercises every consumer.
**Verify.** Full `make test-unit` (all snapshot + routing + permission tests render the
bars). New test: none needed — absence-of-reader is the proof, and adding a "no env
crash" test would just re-render existing snapshots.
**Rollback.** Re-add four lines. Zero state.

### Step 2 — Rename `searchEngine` → `syntaxEngine` (P10(b))

**Scope.** Pure rename of the param/property that is actually the syntax highlighter
but is threaded as `searchEngine` across 6 types, then re-exposed as `\.syntaxEngine`.
A reader expects transcript *search* machinery; it is unrelated to `TranscriptSearchBus`.

- Sites: `…/MainSplitViewController.swift:34`, `…/DetailRouterViewController.swift:75,119,127,416`,
  `…/ChatSessionViewController.swift:69,129,137`, `…/ArchiveViewController.swift:25,36`,
  `…/ComposeSessionViewController.swift:38,49`, `…/DraftSessionLandingViewController.swift:30,45`.

**Dependencies.** Independent of Step 1 but ordered after it so the two trivial diffs
don't conflict in the same files. Land before Step 5 (which folds these params into a
struct) so the struct field is born with the right name.
**Risk.** Trivial — compiler-enforced rename, no behavior.
**Verify.** Compiler + full suite (`SyntaxHighlightEngineTests`, `DiffViewSnapshotTests`
exercise the engine reach).
**Rollback.** Reverse rename.

### Step 3 — Delete vestigial code paths (P13)

**Scope.** Remove provably-dead code:
- Directory-completion machinery: `DirectoryCompletionItem` (never constructed),
  `tryConfirmFromInput`/`hasInputValidation` (0 callers), `onDeleteRecent` + the
  "recent" pill (dead) — `…/Content/Chat/Completion/*`. Deleting removes 3 of 7
  `CompletionSession` closures with no behavior change.
- `ClaudeCodeStats` (~460 lines, no production consumer) + `ClaudeCodeStatsTests`.
- `FileCompletionStore.invalidate*` (0 callers; a slow FSEvent leak).

**Dependencies.** None. Ordered in Phase A so the smaller surface helps Steps 8/12.
Independent of Steps 1/2.
**Risk.** Low. The only risk is "is it really dead?" — each is grep-verified at 0
production callers in the survey. Mitigation: before deleting, re-run
`grep -rn <symbol> macos/ccterm --include=*.swift` excluding the file itself + its test.
**Verify.** `CustomCommandTests` (completion still works for the *live* paths),
`CompletionListSnapshotTests`, full suite. `ClaudeCodeStatsTests` is deleted alongside.
**Rollback.** Revert the deletion commit (pure removal — no migration).
**Parity note.** This is the one step that *removes* user-facing-looking code. Confirm
in the smoke test that completion (`@file`, `/command`) still works — the *live* paths
(`FileCompletionStore`, `SlashCommandStore`) are untouched; only the never-wired
directory + recent paths go.

### Step 4 — `Session.stopBackgroundTask` forwarder (P4)

**Scope.** The single unidirectional-flow violation in production UI:
`BackgroundTaskButton` reaches `session.runtime.markTaskStoppedLocally(...)` directly
(`…/InputBarControls/BackgroundTaskButton.swift:81-83` — confirmed: `guard let runtime
= session.runtime` then `runtime.markTaskStoppedLocally`). There is no
`Session.stopBackgroundTask` forwarder.

**Before:**
```swift
// BackgroundTaskButton
guard let runtime = session.runtime else { return nil }
runtime.markTaskStoppedLocally(taskId: taskId)
```
**After:**
```swift
// Session.swift — phase-aware forwarder mirroring requestContextUsage (Session.swift:393)
func stopBackgroundTask(taskId: String) {
    guard case .active(let runtime) = phase else { return }  // no-op on .draft
    runtime.markTaskStoppedLocally(taskId: taskId)
}
// BackgroundTaskButton
session.stopBackgroundTask(taskId: taskId)
```

**Dependencies.** None; independent of 1–3.
**Risk.** Low. **Strengthens** the invariant rather than weakening it — the fix is in
the product, not the test (engineering-principles compliant). `markTaskStoppedLocally`
keeps its signature; only the call site changes.
**Verify.** `SessionRuntimeTasksTests` (the runtime behavior is unchanged). **New
test:** add a `SessionFacadeTests` case asserting `session.stopBackgroundTask` forwards
to the runtime in `.active` and is a no-op in `.draft` (drive through the public façade,
per Session CLAUDE.md test rules — do NOT add a `forceXxx` hook).
**Rollback.** Re-inline the two lines; delete the forwarder.

---

## 4. Phase B — dependency-injection collapse + host-mounting dedup

Phase A removed the *dead* dependency edges; Phase B collapses the *boilerplate* that
made the dead edges easy to grow. Safe because the wiring is mechanical and protected
by the router-containment + routing tests.

### Step 5 — `DetailChildDependencies` struct + `injectAppEnvironment` (P2)

**Scope.** Collapse the 7-arg bundle (now 5 after Step 1 deletes 2 dead env edges, but
the *init params* stay — see below) re-declared across the router + 5 child VCs, and the
copy-pasted `.environment(...)` block (5×).

Two artifacts:
1. **`DetailChildDependencies`** — a small `struct` holding `model` + the consumed
   services (`sessionManager`, `recentProjects`, `inputDraftStore`, `syntaxEngine`, and
   the AppKit-channel `notifications`/`searchBus` that the VCs still *store* for their
   imperative use). Threaded whole through `makeChild` (replaces the 4× 7-arg call at
   `…/DetailRouterViewController.swift:363-404`). Each VC's `init` takes
   `(deps: DetailChildDependencies)` instead of 7 positional params; stored props read
   from `deps`.
2. **`func injectAppEnvironment<V: View>(_ deps: DetailChildDependencies) -> some View`**
   — a `View` extension applying exactly the consumed env set in one place. Replaces the
   5 verbatim copies.

**Crucial constraint (analysis P2 + survey S1).** Do NOT inject `AppState` itself: the
`model` (`MainSelectionModel`) is owned by `AppDelegate`, NOT on `AppState` (analysis
§3 ownership), so an `AppState`-as-whole injection would be wrong *and* would re-import
the over-broad bundle. The struct is the right granularity: it is the *consumed* set,
not the *owned* set. This keeps "views never construct services."

**Before** (×5 VCs):
```swift
let model: MainSelectionModel
let sessionManager: SessionManager
let recentProjects: RecentProjectsStore
let notifications: NotificationService
let syntaxEngine: SyntaxHighlightEngine   // renamed in Step 2
let searchBus: TranscriptSearchBus
let inputDraftStore: InputDraftStore
init(model:…sessionManager:…/* 7 params */) { /* 7 assignments */ }
@available(*, unavailable) required init?(coder:) { fatalError() }
```
**After** (×5 VCs):
```swift
let deps: DetailChildDependencies
init(deps: DetailChildDependencies) { self.deps = deps }
@available(*, unavailable) required init?(coder:) { fatalError() }
```

**Dependencies.** Steps 1 (dead env removed first, so the helper isn't born with dead
edges) + 2 (field named `syntaxEngine`). MUST come before Step 8/9 (sidebar split would
otherwise re-touch `MainSplitViewController`'s DI fan-out twice).
**Risk.** Low-Med. The risk is a **missed env injection becoming a runtime fatal**
(not a compile error) — but centralizing into one helper *removes* that risk class going
forward, and the conversion itself is covered by every snapshot/routing test that
renders a hosted bar. Convert one VC per commit-within-the-PR if reviewing carefully.
**Verify.** `DetailRouterContainmentTests` (exactly-one-child), `DetailRouterDraftRoutingTests`
(routing across kinds, incl. uncached-draft-after-restart), every snapshot test that
mounts a hosted view. **New test:** none required — but assert in the manual smoke that
all five panes mount without an `@Environment` fatal.
**Rollback.** Revert the PR; the struct is purely additive plumbing.
**Do-not-touch.** The router stays the sole structural owner + sole `MainSelectionObserver`
(chat-I1); `makeChild` stays the sole VC constructor (chat-survey §4). The struct changes
*how deps arrive*, never *who constructs whom*.

### Step 6 — `mountFillPaneHost` helper + un-erase pane `AnyView` (S4 + P12 partial)

**Scope.** Three full-pane VCs (compose, draft-landing, archive) + the demo cards repeat
the exact "fill-pane host" recipe: `NSHostingController(rootView:)` + `sizingOptions = []`
+ 4-edge pin, each with a multi-line rationale comment. Extract a tiny
`mountFillPaneHost(_:in:)` (or a `DetailRouterChild` default-impl) carrying the recipe +
the *one* canonical comment.

Concurrently, un-erase the `AnyView` at these hosts (analysis: incidental, single
concrete body each — un-erasing lets the compiler enforce env injection, pairs with
Step 5's helper).

**Dependencies.** Step 5 (the env helper is what the un-erased generic host will call).
**Risk.** Low-Med — host sizing is window-collapse-sensitive (chat-I7). The helper MUST
preserve `sizingOptions = []` + 4-edge pin **exactly**; flipping to `[.intrinsicContentSize]`
collapses the window (the documented Archive `545×276` fittingSize leak,
`…/ArchiveViewController.swift:84-101`). **Do NOT** fold the chat *bar* host into this
helper — it is the deliberate `[.intrinsicContentSize]` + bottom-anchor component
(chat-I7/I8); it is the asymmetry that must stay. The helper covers fill-pane hosts only.
**Verify.** `ArchiveViewSnapshotTests`, `NewSessionConfiguratorSnapshotTests`,
`DetailRouterLayoutDiagnosticsTests`, `MainWindowAppKitSnapshotTests` (these catch a
window-collapse / size leak). Manual: resize the window with each pane mounted.
**Rollback.** Revert; recipe re-inlines.

### Step 7 — Stale-name + doc-drift cleanup (P12)

**Scope.** Pure renames + doc edits, no behavior:
- `composeOrBarHost` → `restingBarHost` (`…/ChatSessionViewController.swift:94`,
  `makeComposeOrBarStack:545` → `makeRestingBarStack`). The host only ever shows the
  resting bar since compose moved to its own VC.
- Delete the stale `RootView2` references in `InputBarView2`/`NewSessionConfigurator`
  (deleted owner); `TranscriptSearchBus` doc describing the deleted `.searchable`
  design; the root CLAUDE.md "AppState injected through `.environment()`" sentence
  (FACT: never injected whole — analysis §3).
- Reconcile the Chat CLAUDE.md scrim name (`TranscriptScrimView` → the actual
  `TranscriptTopScrimView`/`TranscriptBottomScrimView` subclasses, survey S8).
- (Optional, deferred to whoever touches it) `CompletionViewModel` → `CompletionState`
  rename — flagged but not standalone; fold into a future completion PR.

**Dependencies.** After Step 5/6 (those rename adjacent symbols; avoid churn).
**Risk.** Trivial. Doc + symbol renames.
**Verify.** Compiler + doc review + `make fmt-check`.
**Rollback.** Reverse.

---

## 5. Phase C — God-object extraction + derivation dedup (test-guarded)

These are real structural wins (cohesion split + dedup) guarded by existing tests
plus new pure-logic tests. Higher risk than A/B, lower than D.

### Step 8 — Extract `SidebarTreeModel` (P3, part 1)

**Scope.** Pull the **pure** tree-building out of the ~770-line god-VC into a testable
value: `SidebarTreeModel` taking `(records, groupOrder)` → `[SidebarItemNode]`. Covers
`buildRootChildren` / `groupedRecords` / `RecordGroup` / the `groupOrderStore.arrange`
ordering + per-bucket `lastActiveAt` sort (sidebar survey §3.1). The VC keeps the
outline view + observation wiring + selection echo-suppression; it now *calls* the
model to rebuild.

**Dependencies.** Step 5 (the sidebar's 4-bag DI is reshaped consistently with the
detail-side struct — keep the two DI shapes parallel). Independent of Steps 6/7.
**Risk.** Med. **Must preserve** (sidebar-survey §6): `SidebarItemNode` stays a
reference type (identity-keyed `===` row reuse survives `reloadData()`); the
`groupOrderStore.prependIfAbsent` for new folders happens before rebuild; the
`currentSelection` snapshot → rebuild → `selectRow(for:)` restore order. The extraction
moves *pure* derivation only; the `reloadData()` + `expandAllFolders` + reselect dance
stays in the VC (it touches live `NSOutlineView` state).
**Verify.** `SidebarTitleSanitizerTests`, `SidebarView2SnapshotTests`. **New test:**
`SidebarTreeModelTests` — fixture `[SessionRecord]` + group order → assert node tree
(fixed tabs + folder ordering + per-folder recency sort + draft flagging). This is the
first unit coverage of tree building (analysis P3: "no unit test covers tree
building/grouping/DnD").
**Rollback.** Revert; the model is additive — the VC's old methods can be restored.

### Step 9 — Extract `SidebarContextMenuController` + thin VC (P3, part 2)

**Scope.** Pull the context-menu construction (`menuNeedsUpdate`, Open-in submenu
rebuild, Archive/Copy-Path/Open-in actions) into a `SidebarContextMenuController` that
the VC owns. Leaves the VC owning: outline view + the three `withObservationTracking`
loops + DnD + selection. This is the second cohesion split; after it the VC reads
top-to-bottom as "outline + observation wiring."

**Dependencies.** Step 8 (tree model already extracted — do menu after data).
**Risk.** Med. DnD + menu have no unit coverage; **must preserve** the per-right-click
submenu rebuild (clickedRow stale by fire time → `OpenInRequest` on `representedObject`),
echo-suppression on selection, the archive handler's two writes (model + manager) order.
**Verify.** `SidebarView2SnapshotTests` + **manual smoke** (drag-reorder a folder;
right-click → Archive / Copy Session File Path / Open in ▸). DnD/menu are interaction
flows — per project convention they're covered by driving the controller, but a full
menu unit test is out of scope; rely on the snapshot + manual.
**Rollback.** Revert; controller is additive.

> **Why split P3 into two steps (8 then 9):** the pure tree model (Step 8) is unit-
> testable and de-risks the noisier menu/DnD extraction (Step 9). Landing them
> separately keeps each PR reviewable and each rollback surgical.

### Step 10 — Unify live/cold grouping into one `EntryGroupingEngine` (P7)

**Scope.** Grouping + tool-pairing is implemented twice: live `receive`
(`…/SessionRuntime+Receive.swift:274 appendToTimeline` + `:310 attachToolResult`, grows
forward off `messages.last`) vs cold `ReverseEntryBuilder` (`…/ReverseEntryBuilder.swift:35`,
reverse-folds). They share only `isGroupableAssistant` + a single parity test. Factor the
grouping/pairing rules into one shared engine both directions call.

**Dependencies.** None on B/C structurally, but ordered after the sidebar split so each
PR stays single-subsystem. Independent of Step 11/12.
**Risk.** Med. **Must preserve** (bridge survey / analysis P7): history never flows
through the bridge (bridge-I1); "no `.update` on load" (bridge-I9); cross-page withhold
buffer + doc-order parse (bridge-I8). The forward (live) and reverse (cold) *traversal*
stay distinct — only the per-pair *grouping decision* is shared. Do NOT make cold history
emit `MessagesChange` events.
**Verify.** `TranscriptReverseBuilderTests`, `MessageEntryBlockBuilderTests`,
`Transcript2EntryBridgeTests`, `Transcript2EntryBridgeStatusTests`,
`TranscriptBackfillPipelineTests`, `TranscriptBackfillAnchorTests`. **New test:** a
direct parity test feeding the SAME message sequence through both directions and
asserting identical `[GroupEntry]` (today's lone parity test is implicit — make it
explicit and exhaustive across tool-pairing edge cases).
**Rollback.** Revert; the shared engine is additive — both callers can revert to their
inline logic.

---

## 6. Phase D — the high-risk choreography (last, behind the gate)

Touches the load-bearing AppKit ordering. **Do these last, one at a time, with the
relevant merge gates green before AND after each.** Never combine 11 and 12 in one PR.

### Step 11 — Extract `TranscriptSwapCoordinator` + shared crossfade helper (P5, P6, S9) — **HIGHEST RISK**

**Scope.** `ChatSessionViewController` (~680 lines) mixes "what to show" with the
transcript-swap state machine (`attachSession` + `crossfadeTranscriptSwap` +
`finishTranscriptFadeOut`, `…:281-506` — ~225 invariant-dense lines). Extract a
`TranscriptSwapCoordinator` owning the
build-in-front → settle → bind → `scrollToTail` → drop-outgoing choreography, and a
shared crossfade helper for the "park + flush-on-next-swap + guarded-completion + 0.18s"
shape that exists twice (router cross-kind `…/DetailRouterViewController.swift:96-104,336-361`
+ chat same-session `…/ChatSessionViewController.swift:113-122,476-506`).

**This step changes NO ordering and NO renderer interior.** It is a pure relocation of
the existing sequence into a coordinator object, with the two state machines sharing a
helper. Every byte of the §2.19 sequence and the chat-I5 flush ordering is moved
verbatim.

**Dependencies.** All of A/B (smaller VC, struct DI, renamed host). Should be the
last-but-one step.
**Risk. HIGH.** This is the single riskiest step in the plan. It touches:
- §2.19 single-width attach contract (1.2) — reordering `bindData` before
  `layoutSubtreeIfNeeded`, dropping the layout pass, or inserting any extra tile trigger
  before settle causes 2–3× typesetting of 60–10k blocks.
- chat-I5 outgoing-scroll flush BEFORE bind (1.3) — `finishTranscriptFadeOut()` at the
  head of `attachSession`, before `bindData`, because `dismantle`'s blanket
  `removeObserver(coordinator)` would otherwise rip the freshly-bound incoming scroll's
  observers off (shared coordinator on A→B→A).
- chat-I3 disabled-CATransaction scoping (structural inside, opacity outside).
- chat-I4 build-in-front-then-drop.

**De-risking protocol (mandatory):**
1. Run `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`
   **before** the change; confirm green. These are the merge gates; the host test drives
   `ChatSessionViewController.present` → `attachSession` end-to-end and is verified to
   fail against the three specific regression shapes (bindData reordered before
   layoutSubtreeIfNeeded; layoutSubtreeIfNeeded dropped; an extra attach-time tile
   inserted ahead of settle).
2. Extract by **moving** the existing method bodies into the coordinator unchanged —
   no "while I'm here" simplification. The shared crossfade helper must be a parameterized
   wrapper that the transcript variant still threads its `removeObserver` flush through;
   if the abstraction can't express chat-I5 cleanly, **keep the two implementations
   separate** (P6 dedup is the *lower* prize — P5 cohesion is the prize; do not sacrifice
   I5 to dedup the crossfade).
3. After the change, re-run both gates. If the host test goes red, **read the per-stage
   offender report it attaches to xcresult before changing anything** — a tolerated
   multi-width write IS the bug; never `XCTSkip` or widen tolerance.
4. Additionally run the broader transcript host suite: `TranscriptColdAttachTests`,
   `TranscriptDetachedWarmTests`, `TranscriptAsyncLoadSwitchRaceTests`,
   `Transcript2SheetPresenterLifetimeTests`, `DetailPaneTranscriptHitTestTests`,
   `TranscriptScrollFirstFrameSnapshotTests`, `TranscriptScrollLivePresentationSnapshotTests`.
5. Manual smoke: A→B→A→A session switching (re-entry), draft→active promotion in place,
   window resize mid-transcript, cross-kind swaps (chat↔archive↔compose), and confirm no
   blank-pane flash and no first-frame stutter.

**New tests.** If the coordinator gains a testable seam (e.g. a pure "compute attach
plan" function), add a focused test — but do NOT widen production access purely for a
test hook (engineering principle). The two existing gates already drive the real path
end-to-end; prefer them.
**Rollback.** Revert the whole PR atomically. Because the bodies are moved verbatim, a
revert restores the exact prior choreography. This is why the step is a *move*, not a
rewrite — rollback is a clean `git revert`.
**Preserve.** chat-I3/I4/I5/I6/I14 verbatim; `prepareForRemoval` still releases the
per-attach scroll/presenter/task at swap time.

### Step 12 — Extract `SessionRuntime` self-contained projections (P8) — **MED-HIGH**

**Scope.** `SessionRuntime` (~3000 lines / 9 files / 23 `@Observable` fields + 7 sinks)
owns CLI lifecycle, timeline, streaming/typewriter, token accounting, background-task
tracking, todo tracking, context-usage caching, title generation, permission queue,
config persistence. The *self-contained projections* (todos / tasks / turn-usage meter /
context-usage cache) have their own scratch state and are extractable as value or
sub-objects the runtime composes.

**Scope discipline:** extract ONLY the self-contained projections
(`TodoTracker`/`TaskTracker`/`TurnUsageMeter`/`ContextUsageCache`). Do **not** touch the
CLI lifecycle, the `receive` side-effect ordering, or the permission queue — those are
the entangled core and are out of scope.

**Dependencies.** Independent of Step 11 (different subsystem) but ordered last because
it's the largest and benefits from a fully-stabilized tree. Can run in parallel with 11
on a separate branch if reviewer bandwidth allows — they don't share files.
**Risk. Med-High.** **Must preserve** (Session/runtime survey + analysis P8): the
synchronous `onMessagesChange` fire contract (runtime-I1) and `receive` side-effect
ordering (runtime-I3) — these are why the AppKit bridge stays one tick ahead of SwiftUI.
The extracted projections must update *inside* the same synchronous `receive` call stack,
not via an async hop. Pick-one-channel-per-state must hold (no projection emits on both
channels).
**Verify.** `SessionRuntimeTodosTests`, `SessionRuntimeTasksTests`,
`SessionRuntimeStreamingTests`, `ContextUsageTests`, `SessionRuntimeReceiveStatusTests`,
`SessionRuntimeUnreadTests`, `SessionRuntimeIsRunningTests`, `SessionTurnFinishedWiringTests`,
`SessionFacadeTests`, `SessionPromotionTests`. **New tests:** focused
`TodoTracker`/`TaskTracker`/`TurnUsageMeter`/`ContextUsageCache` unit tests driving each
projection in isolation (now possible once extracted) — these *add* coverage the
monolith lacked.
**Rollback.** Revert per-projection commits (extract one projection per commit-within-PR
so a single problematic projection rolls back without losing the others).
**Drop note.** P9 (the `Session` façade forwarder boilerplate) is explicitly NOT part of
this step — see §7.

---

## 7. Rejected / deferred (and why)

| Item | Decision | Rationale |
|---|---|---|
| **P9 — `Session` façade forwarder dedup** (shared phase protocol) | **Rejected** | Analysis P9 flags this as *do-not-gold-plate*: the draft and runtime read-surfaces genuinely diverge (status/messages/tasks/todos are runtime-only). A naive shared protocol would fabricate runtime-only fields on the draft. The boilerplate is mechanical, not tangled flow. Leaving it is the clean-not-clever choice. |
| **P11 — singleton reconciliation** (`ModelStore`/`EffortDefaultStore`/`NewSessionDefaultsStore` + completion stores) | **Deferred** | Judgment call balanced against no-over-engineering. `ModelStore` (mutable observable + spawns a CLI subprocess) is the only questionable one; the UserDefaults wrappers are low-harm. Moving them onto `AppState` is a large blast radius (views + runtime reach `.shared` directly) for low flow-clarity gain. Reconcile the *doc* (Step 7) and revisit only if a concrete bug appears. |
| **P14 — duplicated derivation / magic constants** (`StableBlockID` scheme ×3, task title/color ×2–3, pill radius `16` ×2) | **Folded opportunistically** | Each is a silent coupling a refactor can break invisibly. Not worth a standalone step; fix the ones adjacent to a step you're already in (e.g. task title/color while in Step 12; `StableBlockID` constant while in Step 10). Each is a 1-line `let` extraction guarded by existing snapshot tests. |
| **P15 — layering nits** (view concerns under `Models/`, `GitProbe` missing `@MainActor`) | **Folded opportunistically** | File moves only; the synced-group project structure means moves are free. Do alongside an adjacent step touching the file. `GitProbe` `@MainActor` is a 1-line fix guarded by `GitProbeTests`. |
| **Merge Controller + Coordinator** (transcript) | **Rejected — explicitly forbidden** | NativeTranscript2 CLAUDE.md §1.1: "Don't merge." Three load-bearing reasons (NSObject conformance vs `@Observable`, file size, real Controller-side logic). Not in scope. |
| **SwiftUI-ify any AppKit spine surface** | **Rejected** | The five AppKit exceptions are measured + documented. SwiftUI-by-default applies to *new* leaves only. |
| **Big-bang rewrite of the swap/crossfade** | **Rejected** | Step 11 is a verbatim *move*, not a rewrite, precisely so rollback is `git revert` and the §2.19/I5 orderings are preserved byte-for-byte. |

---

## 8. Highest-risk steps + how they're de-risked (summary)

| Step | Why risky | De-risk |
|---|---|---|
| **11 (transcript swap)** | Touches §2.19 attach contract + chat-I5 flush ordering — the most fragile sequence in the app | Verbatim move (no simplification); two merge gates green before+after; broader transcript suite + manual A→B→A; keep the two crossfade impls separate if the shared helper can't express I5; atomic `git revert` rollback |
| **12 (runtime split)** | Largest object; `receive` ordering + synchronous `onMessagesChange` are load-bearing | Extract only self-contained projections; one projection per commit; projections update inside the same `receive` stack; full runtime test battery + new per-projection tests |
| **8/9 (sidebar)** | DnD + menu have no unit coverage | Split pure-model (testable, Step 8) from menu/DnD (Step 9); new `SidebarTreeModelTests`; manual DnD/menu smoke; preserve reference-type node + echo-suppression |
| **10 (grouping dedup)** | Two traversal directions must stay distinct; bridge invariants | Share only the per-pair decision, not traversal; explicit bidirectional parity test; full bridge/backfill battery; never emit `MessagesChange` from cold path |
| **5 (DI struct)** | Missed env injection is a runtime fatal, not a compile error | Centralize into one helper (removes the class going forward); every hosted-view snapshot test renders the bars; manual mount of all five panes |

---

## 9. Functional-parity checklist (every user-facing feature must survive)

Run this list as the acceptance gate before merging each Phase boundary, and the full
list before declaring the migration done. Each maps to the merge-gate or snapshot test
that protects it; **(M)** = also verify manually.

**Selection / routing**
- [ ] Click a session in the sidebar → transcript mounts in the same tick — `DetailRouterContainmentTests`, `DetailRouterDraftRoutingTests` (M)
- [ ] Click New Session → compose card; Archive → archive pane; demo tabs (DEBUG) — `DetailRouterContainmentTests` (M)
- [ ] A draft row restored after cold restart routes to the landing VC (not transcript) — `DetailRouterDraftRoutingTests.test_uncachedDraftRow_afterRestart_mountsLandingVC`
- [ ] Draft promotion (first send) swaps landing → transcript in place — `DetailRouterDraftRoutingTests.test_draftPromotion_swapsLandingForTranscript`, `MainSelectionModelPromoteTests`
- [ ] No blank-pane flash on any swap; no first-frame stutter on re-entry — `TranscriptScrollLivePresentationSnapshotTests` (M)

**Transcript**
- [ ] Session A→B→A re-entry: blocks intact, scrolled to tail, single-width typeset — `TranscriptReentryLayoutCacheTests`, `TranscriptHostReentryLayoutCacheTests`
- [ ] Cold history load: off-main build, anchored prepend, no freeze — `TranscriptBackfillPipelineTests`, `TranscriptBackfillAnchorTests`, `TranscriptColdAttachTests`
- [ ] Live streaming assistant text + typewriter — `SessionRuntimeStreamingTests`, `TypewriterRevealTests`, `StreamingMarkdownCommitTests`
- [ ] Tool groups: fold/expand, status colors, shimmer, error cards — `ToolGroupErrorCardTests`, `ToolGroupErrorCardSnapshotTests`, `ToolGroupSearchableRegionsTests` (M fold/expand)
- [ ] Loading pill + turn usage token counter — `LoadingPillLayoutTests`, `LoadingPillUsageSnapshotTests`
- [ ] In-transcript ⌘F search: scan, next/prev, folded-child reveal — `TranscriptSearchCoordinatorTests`, `TranscriptSearchHighlightRenderTests` (M ⌘F)
- [ ] Selection + copy across rows; user-bubble sheet; image preview sheet — `Transcript2SheetPresenterLifetimeTests`, `CopyChromeTests` (M)
- [ ] Window resize reflow with no jump — `TranscriptScrollFirstFrameSnapshotTests` (M)

**Input bar / compose / draft-landing**
- [ ] Send / stop button swap on `isRunning` — `InputBarSnapshotTests`, `SessionRuntimeIsRunningTests`
- [ ] `@file` + `/command` completion (live paths only after Step 3) — `CustomCommandTests`, `CompletionListSnapshotTests` (M)
- [ ] Draft persists across New-Session re-entry but clears on send — `InputDraftStoreTests` (M)
- [ ] Permission mode picker, model/effort picker, todo button, context ring, background-task button — `PermissionModePickerVisibilityTests`, `UltracodeEffortTests`, `TodoListSnapshotTests`, `BackgroundTaskSheetSnapshotTests`
- [ ] **Background task stop** (Step 4) — `SessionRuntimeTasksTests` + new `SessionFacadeTests` case (M)
- [ ] Permission cards (all kinds) — the full `Permission*CardBodyTests` battery + `PermissionCardWiringTests`
- [ ] `/new` + `/clear` builtin order (create→archive→select) — `BuiltinSlashCommandTests`
- [ ] No input chrome floats over archive/compose/demo — `ChatComposeStackRoutingTests` (regression #222)

**Sidebar**
- [ ] History list groups by folder, ordered, recency-sorted — new `SidebarTreeModelTests`, `SidebarView2SnapshotTests`
- [ ] Per-row status (running dots / unread / shimmer) — `SidebarView2SnapshotTests` (M)
- [ ] Folder drag-reorder persists — (M, Step 9 manual)
- [ ] Context menu: Archive / Copy Session File Path / Open in ▸ — `SessionManagerArchiveTests` (M menu)
- [ ] Title sanitization — `SidebarTitleSanitizerTests`

**Session lifecycle / data**
- [ ] Draft → active promotion copies config verbatim, wires bridge — `SessionPromotionTests`, `SessionFacadeTests`
- [ ] Live CLI events flow into detached sessions (switch-back O(1)) — `TranscriptDetachedWarmTests`
- [ ] Todos / tasks / context-usage / turn-finished (Step 12) — `SessionRuntimeTodosTests`, `…TasksTests`, `ContextUsageTests`, `SessionTurnFinishedWiringTests`
- [ ] Worktree create / archive — `WorktreeProvisionerTests`, `SessionManagerArchiveWorktreeTests`
- [ ] Notification activation routes to the session — `NotificationActivationRoutingTests`
- [ ] Title generation — `TitleGeneratorTests`

**Aux windows / app shell**
- [ ] Settings + About windows open and size correctly — `AboutViewSnapshotTests` (M Settings)
- [ ] ⌘, never opens a SwiftUI Settings window (placeholder scene invariant) — (M)
- [ ] Archive pane filter + unarchive — `ArchiveViewSnapshotTests`

---

## 10. Parity guarantee (explicit)

**No step removes or alters a user-facing behavior.** The guarantee rests on four
structural facts:

1. **Every step is either (a) a pure deletion of provably-dead code (Steps 1, 3), (b) a
   compiler-enforced rename (Steps 2, 7), (c) additive plumbing that changes *how
   dependencies arrive* not *what runs* (Steps 5, 6), or (d) a verbatim *move* of
   existing logic into a more cohesive owner (Steps 8–12).** None rewrites a working
   algorithm. The one new behavior (`Session.stopBackgroundTask`, Step 4) is a façade
   forwarder to the same `markTaskStoppedLocally` the UI already called — identical effect,
   cleaner path.
2. **The load-bearing invariant wall (§1) is preserved verbatim by every step**, and the
   two transcript merge gates + the runloop-ordering tests run on every PR as the merge
   gate. A tolerated multi-width write or a broken attach ordering fails CI — it cannot
   merge.
3. **Each step is independently revertible** (`git revert` of one PR), and the
   highest-risk step (11) is a verbatim move specifically so its rollback restores the
   exact prior choreography byte-for-byte.
4. **The functional-parity checklist (§9) maps every user-facing feature to a protecting
   test** (existing merge-gate, existing snapshot, or a new pure-logic test added by the
   step), run at each phase boundary and in full at completion.

Improvements that *are* allowed and expected: new unit coverage for previously-untested
surfaces (sidebar tree building, grouping parity, runtime projections, façade
forwarding); removal of a slow FSEvent leak (`FileCompletionStore.invalidate*`, Step 3);
elimination of a phantom dependency edge (dead `.environment`, Step 1) that would have
misled a future refactor; and a strengthened façade boundary (Step 4).
