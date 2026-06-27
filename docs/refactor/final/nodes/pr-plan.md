# CCTerm refactor — the multi-PR execution plan

> **Purpose.** Reframe the whole refactor as an **ordered set of
> independently-shippable PRs**. Each PR is a stable id, compiles, passes
> `make test-unit`, leaves the app green, and after it merges every ownership-table
> row it touches is **Conformant ✓** under [`spec.md`](spec.md). No PR weakens a
> do-not-touch contract (REFACTOR-PLAN §10 / BOUNDARY-SPEC gates).
>
> The plan is the canonical realization of REFACTOR-PLAN **§9 migration (4 phases /
> 13 steps)**. The 13 steps map 1:1 to **PR1–PR13** in that order. Every placeholder
> mnemonic used in the six table fragments (PR-A1, PR-B7, PR-Card, PR-Side1,
> PR-C12, PR-D1, …) is resolved to a final PR number in the mapping table below;
> **every non-`unchanged` table row is claimed by exactly one PR.**
>
> Risk gradient honored: mechanical / dead-code / rename first (PR1–PR4); the
> headline permission-card overlay early and self-contained (PR5); boundary
> hygiene + DI collapse (PR6–PR8); god-object splits (PR9–PR12); the
> transcript-swap extraction + runtime projections **last**, behind the two
> reentry-layout merge gates (PR12–PR13). PR5 (card host) is sequenced **before**
> PR13 (`TranscriptSwapCoordinator`); both touch `ChatSessionViewController.loadView`,
> and PR13 must treat `permissionCardHost` as a 4th sibling host and keep transcript
> re-insertion `.below topScrim`.

---

## Mnemonic → final PR mapping

| §9 step | Final PR | Phase | Fragment mnemonics it absorbs |
|---|---|---|---|
| 1 | **PR1** | A | `PR-A1` (shell), `PR-DeadCode` partial (env edges) — dead `.environment` deletion |
| 2 | **PR2** | A | `PR-A2` (shell + session) — `searchEngine`→`syntaxEngine` |
| 3 | **PR3** | A | `PR-A3` (detail-vcs + session + `PR-A3 (const only)` transcript), `PR-DeadCode`, `PR-Naming` for `CompletionState` is **not** here (it is PR8) |
| 4 | **PR4** | A | `PR-A4` / `PR-Facade` — `Session.stopBackgroundTask` |
| 5 | **PR5** | B | `PR-B1` (detail-vcs), `PR-Card` (inputbar) — permission-card overlay |
| 6 | **PR6** | B | `PR-B2` (detail-vcs), `PR-B4` rename/un-erase of `restingBarHost` (the un-erase leg) — `mountFillPaneHost` + un-erase `AnyView` |
| 7 | **PR7** | B | `PR-B7` (shell), `PR-B3` (detail-vcs), `PR-DI` (inputbar/sidebar `SidebarContext`) — `DetailContext` + `injectDetailEnvironment` |
| 8 | **PR8** | B | `PR-B8` (shell doc), `PR-Naming` (`composeOrBarHost`→`restingBarHost` rename leg of `PR-B4`, `CompletionViewModel`→`CompletionState`), doc drift — naming/doc finalization |
| 9 | **PR9** | C | `PR-Side1` (sidebar) — `SidebarTreeModel` |
| 10 | **PR10** | C | `PR-Side2` (sidebar) — `SidebarContextMenuController` + thin VC |
| 11 | **PR11** | C | `PR-C11` (session/shell grouping leg) — grouping dedupe (shrunk/optional) |
| 12 | **PR12** | C/D | `PR-C12` (session projections), `PR-Layer`/`PR-D15` (layering nits) — `SessionRuntime` projections + layering nits |
| 13 | **PR13** | D | `PR-D1` (detail-vcs), `PR-D13` (optional crossfade helper — **default NOT done**) — `TranscriptSwapCoordinator` |

> Notes on splits across the mnemonic→PR seam:
> - `PR-B4` in the fragments bundles two legs: the **un-erase `AnyView`** of `restingBarHost` (compiler-forces injection) lands in **PR6** alongside the fill-pane un-erase (so PR7's `DetailContext` lands behind a compile-error guard, REFACTOR-PLAN §9 R1 step 6→7 ordering); the **pure rename** `composeOrBarHost`→`restingBarHost` lands in **PR8** with the other naming/doc work.
> - `PR-C11` appears twice in fragments: the *optional* AppState fold of `searchBus`/UserDefaults wrappers is folded into **PR8** (doc/low-risk) where cheap, and the grouping-dedupe leg is **PR11**. Neither is load-bearing; both may shrink to no-op (REFACTOR-PLAN §8 P7/P11, §9 deferred list).
> - The `CrossfadeController` row is a **declared design defect** (✗); it is **not introduced**. Its optional adoption is the only contents of `PR-D13`, which the plan downgrades to default-not-done; if ever attempted it rides inside PR13. No table row is created for it.

---

## Per-PR summary table

| PR | Title | Phase | Risk | Depends on | Headline rows created/changed |
|---|---|---|---|---|---|
| PR1 | Delete dead `.environment` injections | A | trivial | — | `NotificationService`, `TranscriptSearchBus` (drops out of detail injection), `DetailRouterViewController`, the 5 detail-VC hosts |
| PR2 | Rename `searchEngine` → `syntaxEngine` | A | trivial | — | `SyntaxHighlightEngine`, `DetailRouterViewController`, `MainSplitViewController` |
| PR3 | Delete dead code (dir-completion / `ClaudeCodeStats` / `invalidate*`) + extract `StableBlockID` const | A | low | — | `DirectoryCompletionItem/Provider`, `DirectoryTreeMonitor`, `ClaudeCodeStats`, `FileCompletionStore` (methods), `CompletionListView`, `StableBlockID` |
| PR4 | `Session.stopBackgroundTask(taskId:)` façade forwarder | A | low | — | `Session` (+method), `BackgroundTaskButton` |
| PR5 | Permission-card floating overlay (headline fix) | B | medium | PR4 (soft) | `PermissionCardOverlay`, `permissionCardHost`, `PassthroughHostingView`, `ChatRestingBar`, `PermissionCardView`, `ChatSessionViewController` (loadView) |
| PR6 | `mountFillPaneHost` helper + un-erase `AnyView` | B | low-med | PR5 | `mountFillPaneHost`, `ComposeSessionViewController`, `DraftSessionLandingViewController`, `ArchiveViewController` (+ their views), `restingBarHost` (un-erase leg) |
| PR7 | `DetailContext` + `injectDetailEnvironment` | B | low-med | PR1, PR2, PR6 | `DetailContext`, `injectDetailEnvironment`, `MainSplitViewController`, `DetailRouterViewController`, all 4 detail VCs, `SidebarContext` |
| PR8 | Naming + doc finalization | B | trivial | PR5, PR6, PR7 | `restingBarHost` (rename leg), `CompletionState`(+`.CompletionSession`), doc drift; optional AppState fold of `searchBus`/UserDefaults wrappers |
| PR9 | Extract `SidebarTreeModel` (pure) | C | medium | — | `SidebarTreeModel`, `SidebarItemNode` (moves to tree output), `SidebarViewController` (tree-build extracted) |
| PR10 | Extract `SidebarContextMenuController` + thin VC | C | medium | PR9 | `SidebarContextMenuController`, `SidebarViewController` (thin) |
| PR11 | Grouping dedupe (shrunk/optional) | C | medium | — | `SessionRuntime+Receive`, `ReverseEntryBuilder` (predicate already shared — may no-op) |
| PR12 | `SessionRuntime` projections + layering nits | C/D | med-high | — | `TodoTracker`, `TaskTracker`, `ContextUsageCache`, `SessionRuntime+{Todos,Tasks,ContextUsage}`, `GitProbe` (@MainActor), `ANSIAttributedBuilder`/`SyntaxTheme`/`PermissionMode+Color`/`Effort+Display` (move out of `Models/`) |
| PR13 | Extract `TranscriptSwapCoordinator` | D | high | PR5 (loadView), PR12 (projections) | `TranscriptSwapCoordinator`, `transcriptScroll`, `transcriptSheetPresenter`, `ChatSessionViewController` (sheds swap state machine) |

---

## Per-PR detail

### PR1 — Delete dead `.environment` injections
- **Scope.** Delete the 5 host-site `.environment(notifications)` / `.environment(searchBus)` injections (REFACTOR-PLAN §8 P1; grep-confirmed 0 SwiftUI reader). The router still *holds* `notifications` for the AppKit `onActivateSession` push; only the SwiftUI injection edges go. `searchBus` keeps reaching the toolbar bridge via `withObservationTracking`. Pure delete, no-op.
- **Rows touched.** `NotificationService` (→ places cleanly as push-only service ✓), `TranscriptSearchBus` (drops out of the detail-injection path), `DetailRouterViewController` (stops injecting; still holds), the 5 detail-VC hosts (`ChatSessionViewController`, `ComposeSessionViewController`, `DraftSessionLandingViewController`, `ArchiveViewController`, demo VC).
- **Depends on.** none.
- **Risk.** trivial (dead-edge deletion).
- **Gate tests.** full `make test-unit`; `DetailRouterContainmentTests`, `DetailRouterDraftRoutingTests` (containment/routing unchanged); manual smoke (notification activation still routes; ⌘F search still focuses).
- **Rollback.** `git revert` — restores the (dead) injections; behavior identical.
- **Independently shippable & green.** Removes edges with zero readers; no behavior change, every touched row already conformant before and strictly cleaner after.

### PR2 — Rename `searchEngine` → `syntaxEngine`
- **Scope.** End-to-end compiler-guarded rename of the `SyntaxHighlightEngine` param/property from the misleading `searchEngine` across `MainSplitViewController`, `DetailRouterViewController` (×4 sites) and the detail VCs (REFACTOR-PLAN §8 P10b). Type unchanged; channel name corrected (it is not transcript-search machinery).
- **Rows touched.** `SyntaxHighlightEngine` (as-is ✗ wrong channel name → ✓), `DetailRouterViewController`, `MainSplitViewController`.
- **Depends on.** none (orthogonal to PR1; either order).
- **Risk.** trivial (rename, compiler-enforced).
- **Gate tests.** compiler + full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Identifier-only change; the closed-set "Reads state via: ctor-injected" channel is unchanged, only its name.

### PR3 — Delete dead code + extract `StableBlockID` constant
- **Scope.** Behavior-preserving removal of (a) the never-triggered directory-completion wiring — `DirectoryCompletionItem` (0 construction sites), `DirectoryCompletionProvider`, `DirectoryTreeMonitor`, plus the live-but-never-firing `CompletionListView.onDeleteRecent`/`isRecent` recent-dir branches and `InputBarView2` swipe-delete-recent (data source permanently empty, REFACTOR-PLAN §8 C14); (b) `ClaudeCodeStats` (~460 lines, 0 production consumer) and its tests; (c) `FileCompletionStore.invalidate*` (0 caller, FSEvent leak). Also the cross-file `StableBlockID` constant extraction (scheme referenced ×3, P14) — logic-free, snapshot-guarded.
- **Rows touched.** `DirectoryCompletionItem` (DELETE), `DirectoryCompletionProvider` (DELETE), `DirectoryTreeMonitor` (DELETE), `ClaudeCodeStats` (DELETE), `FileCompletionStore` (methods deleted, store kept), `CompletionListView` (recent-dir wiring removed — touches live file), `StableBlockID` (const-only).
- **Depends on.** none.
- **Risk.** low (touches *live* completion files — not pure dead-file deletion).
- **Gate tests.** `CustomCommandTests`, `CompletionListSnapshotTests` (live-file guard); transcript snapshot tests guard `StableBlockID` extraction; full `make test-unit`. Delete `ClaudeCodeStats`' tests with it.
- **Rollback.** `git revert` (deletion-only; restores files verbatim).
- **Independently shippable & green.** Removes code with no live behavior; `StableBlockID` change is byte-equivalent under snapshot. **Does not enter renderer internals** (DNT-1).

### PR4 — `Session.stopBackgroundTask(taskId:)` façade forwarder
- **Scope.** Add a phase-aware `Session.stopBackgroundTask(taskId:) -> Void` forwarder mirroring `requestContextUsage` (uses the `guard let runtime` computed-accessor idiom, **not** `guard case .active`; `.draft` no-op; returns `Void` per REFACTOR-PLAN §7.4 M6 — do not re-leak `Bool`). `BackgroundTaskButton.stopAction` calls it instead of `session.runtime.markTaskStoppedLocally` (closes the single production unidirectional-flow violation, P4 / §6.1).
- **Rows touched.** `Session` (+ method), `BackgroundTaskButton` (as-is ✗ façade bypass → ✓). `SessionRuntime+Tasks` becomes reachable only through the façade.
- **Depends on.** none. (PR12 later *relocates* the storage into `TaskTracker`; PR4 is the façade and ships first so the violation is closed immediately.)
- **Risk.** low (additive forwarder + one call-site swap; reinforces an invariant in production code, no test-only seam — Engineering principle "never compromise production code for tests").
- **Gate tests.** `SessionRuntimeTasksTests` + a new `SessionFacadeTests` case asserting the forwarder routes through the runtime and is a `.draft` no-op.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Additive façade; the button keeps working; nullability contract change noted in the commit (button only renders with a live runtime).

### PR5 — Permission-card floating overlay (headline experience fix)
- **Scope.** The headline fix (REFACTOR-PLAN §7). Add a VC-resident sibling host `permissionCardHost: PassthroughHostingView<PermissionCardOverlay>` to `ChatSessionViewController.loadView`, added **after** `restingBarHost` for z-order (§7.4 M5). It uses **regime-A sizing + passthrough hit-testing**: `sizingOptions = []` + 4-edge pin (publishes no `fittingSize` → no window collapse) layered with `PassthroughHostingView` (`hitTest→nil` off-card + suppressed cursor/tracking rects, M2/M4). `PermissionCardOverlay` reads `session.pendingPermissions.first` routed by `model.selection` + `.id(sid)` (R4), bottom inset `chatBottomInset` = 36 (M1), and routes the 4 decision closures to `session.respond(...)` (moved **verbatim** from `ChatRestingBar`). `ChatRestingBar` collapses to "just the bar" — delete the card `ZStack`, the `if let pending` child, and the body-level `.animation`. Re-introduce `PassthroughHostingView` (only a tombstone comment exists today — re-add, do not reuse old). Migrate `PermissionSessionDemoViewController` to mount the overlay (M3 — explicit DEBUG subtask, else the demo silently breaks).
- **Rows touched.** `PermissionCardOverlay` (★NEW), `permissionCardHost` (★NEW), `PassthroughHostingView` (★NEW re-intro), `ChatRestingBar` (★CHANGED → bar only), `PermissionCardView` (★MOVED host; body bytes unchanged), `ChatSessionViewController` (loadView gains 4th sibling host).
- **Depends on.** none structurally; soft-ordered after PR4 (Phase A first). Sequenced **before** PR13 (both touch `loadView`); PR13 treats this host as the 4th sibling and keeps transcript `.below topScrim`.
- **Risk.** medium (touches `loadView`; new hosting boundary). Self-contained — VC-level host like the scrim, **not** per-attach, so it does not entangle with the PR13 swap state machine.
- **Gate tests.** `PermissionCardWiringTests` (★NEW — drives the overlay's 4 closures, asserts each decision reaches `session.respond` correctly: catches swapped allowOnce/allowAlways, lost `onAllowWithInput.updatedInput`); `PermissionCardSnapshotTests` (updated to render `PermissionCardOverlay`; pixel-equal after M1=36); `ChatComposeStackRoutingTests` (bar still routes by selection); `DetailPaneTranscriptHitTestTests` (real `hitTest` + `.leftMouseDown` — guards M4/M5 passthrough; the host must NOT mask the transcript I-beam). BOUNDARY merge gates remain green (`AppKitSwiftUIBoundaryTests`, `DetailRouterLayoutDiagnosticsTests`).
- **Rollback.** `git revert` — restores the `ZStack` bar (re-introduces the headline defect, but green).
- **Independently shippable & green.** The overlay replaces the bar's card subtree wholesale; bar host intrinsic height becomes a pure function of bar content; no other host moves. Conformant ✓ requires the documented A-hybrid filing (NOT B″) — `DetailPaneTranscriptHitTestTests` enforces it.

### PR6 — `mountFillPaneHost` helper + un-erase `AnyView`
- **Scope.** Add the `mountFillPaneHost(_:in:)` helper encoding regime A (`sizingOptions = []` + 4-edge pin) and route the 3 fill-pane VCs (`Archive`/`Compose`/`DraftLanding`) through it. Un-erase the 5 pane-host bodies from `AnyView` to concrete generic bodies (compiler enforces environment injection — a missed inject becomes a compile error). This is the un-erase leg of `restingBarHost` too (the regime-B chat bar is **deliberately NOT folded into** `mountFillPaneHost`, §10 rule 6). Must land **before** PR7 so PR7's `injectDetailEnvironment` lands behind a compile-error guard (REFACTOR-PLAN §9 R1, step 6→7).
- **Rows touched.** `mountFillPaneHost` (★NEW), `ComposeSessionViewController`/`ComposeSessionView`, `DraftSessionLandingViewController`/`DraftSessionLandingView`, `ArchiveViewController`/`ArchiveView` (un-erased), `restingBarHost` (un-erase leg; rename leg deferred to PR8).
- **Depends on.** PR5 (both touch chat-VC host region; card lands first).
- **Risk.** low-medium (host wiring; boundary-sensitive).
- **Gate tests.** `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse`, `.testArchiveBindingWriteStaysHeightNeutral`, `.testSizingRegimeGovernsPublishedFittingSize`, `.testDefaultSizingOptionsHostCollapsesWindowInLargeSplit`; `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow` (hardened `fittingSize.height <= 1`); `HostedComponentCenteringTests.testRestingBarCapsAndCentersInWidePane`, `.testRestingBarShrinksToFitAndCentersInNarrowPane`; `ArchiveViewSnapshotTests`, `MainWindowAppKitSnapshotTests`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Canonicalizes the existing `[]`+4-edge pattern (regime preserved, not changed); un-erase is a body-type change with identical render. **Honors DNT-6** (chat bar asymmetry preserved).

### PR7 — `DetailContext` + `injectDetailEnvironment`
- **Scope.** Replace the 7-arg detail-VC init fan-out + 5 duplicated `.environment` blocks with one `DetailContext` value (model + the 4 *consumed* services `{SessionManager, RecentProjectsStore, InputDraftStore, syntaxEngine}`) threaded whole through `makeChild`, and one `View.injectDetailEnvironment(_:)` modifier (REFACTOR-PLAN §8 P2, Rule 7). Same change shape for the sidebar: one `SidebarContext` value (model + consumed services) replacing the 4-bag `SidebarViewController.init`. **Not** whole-AppState injection (`model` is not on AppState; would over-expose). Adding/removing one app-scope dependency becomes a one-site edit.
- **Rows touched.** `DetailContext` (★NEW), `injectDetailEnvironment` (★NEW), `MainSplitViewController` (★CHANGED → builds one `DetailContext` + one `SidebarContext`), `DetailRouterViewController` (holds + threads `DetailContext`), `ChatSessionViewController`/`ComposeSessionViewController`/`DraftSessionLandingViewController`/`ArchiveViewController` (`init(context:)`), `SidebarViewController` (`SidebarContext`), `SidebarContext` (★NEW).
- **Depends on.** PR1 (dead edges gone — helper carries no dead deps), PR2 (`syntaxEngine` name), PR6 (un-erase landed → missed inject is a compile error).
- **Risk.** low-medium (wide wiring change, compiler-guarded).
- **Gate tests.** `DetailRouterContainmentTests`, `DetailRouterDraftRoutingTests`, `MainSelectionModelPromoteTests`; full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Mechanical DI collapse; same services reach the same consumers via one value bag. Every touched VC stays conformant before/after (the smell was wiring, not placement).

### PR8 — Naming + doc finalization
- **Scope.** The pure-rename + doc-drift cleanup (REFACTOR-PLAN §8 P12, §9 step 8): `composeOrBarHost`→`restingBarHost` (rename leg; constraints/regime unchanged — H-2), `CompletionViewModel`→`CompletionState` (+ nested `.CompletionSession`) to remove "VM in a no-VM zone" confusion, fix root `CLAUDE.md` "AppState via `.environment`" staleness, fix `RootView2` doc references across 8 files, fix `Content/Chat/CLAUDE.md` top-scrim base-name drift (`TranscriptScrimView`→`TranscriptTopScrimView`). Optionally fold the thin `searchBus`/UserDefaults wrappers (`EffortDefaultStore`, `NewSessionDefaultsStore`) onto `AppState` if cheap (low-risk; `ModelStore` stays `.shared`).
- **Rows touched.** `restingBarHost` (rename leg), `CompletionState` + `CompletionState.CompletionSession` (★RENAMED), `TranscriptSearchBus`/`AppState` (optional fold), doc-only rows.
- **Depends on.** PR5 (overlay landed), PR6 (un-erase landed), PR7 (DetailContext landed) — so the final names settle on the final structure.
- **Risk.** trivial (rename + docs).
- **Gate tests.** compiler + `make fmt-check`; full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Identifier/doc-only; no channel, owner, or regime changes.

### PR9 — Extract `SidebarTreeModel` (pure)
- **Scope.** Extract a pure `SidebarTreeModel.build(records, groupOrder, previouslySeenGroups) -> (nodes: [SidebarItemNode], newGroups: [String])` from `SidebarViewController` (REFACTOR-PLAN §8 P3-1). The hidden `lastSeenGroups` cache becomes an **explicit input**, preserving invariant 6.10 (folders already present at launch are not treated as new). First time tree-building / grouping / new-folder detection is unit-testable.
- **Rows touched.** `SidebarTreeModel` (★NEW), `SidebarItemNode` (moves to tree-model output; stays a reference type for `NSOutlineView` `===` identity, inv 6.1), `SidebarViewController` (tree-build extracted; still owns outline + 3 obs loops + DnD + selection).
- **Depends on.** none (sidebar is 100% AppKit, no host boundary; orthogonal to Phase B).
- **Risk.** medium (god-VC split; sidebar invariants 6.1–6.12 are do-not-touch, DNT-7).
- **Gate tests.** new `SidebarTreeModelTests` (asserts grouping/sort/recency + the explicit-cache inv 6.10), `SidebarTitleSanitizerTests`, sidebar snapshot; full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Pure-function extraction; the VC calls `build` and feeds the same nodes to the same `reloadData()` path (no fine-grained diff — DNT-8). Cohesion fix, channels already clean (`model.select`, `@Observable` reads).

### PR10 — Extract `SidebarContextMenuController` + thin VC
- **Scope.** Extract a `SidebarContextMenuController` (`NSMenuDelegate` + menu actions: archive, "Open in", copy-path, pasteboard write) from `SidebarViewController` (REFACTOR-PLAN §8 P3-2). The VC keeps outline + 3 `withObservationTracking` loops + DnD (needs live `outlineView.moveItem`) + selection. Echo-suppression guard and per-row obs re-arm fully preserved.
- **Rows touched.** `SidebarContextMenuController` (★NEW), `SidebarViewController` (thin — final conformant ✓ form).
- **Depends on.** PR9 (tree model extracted first).
- **Risk.** medium (god-VC split; DnD/menu invariants are do-not-touch, DNT-7).
- **Gate tests.** sidebar snapshot + manual DnD/menu smoke (folder drag persists; right-click menu; "Open in"/copy-path); full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Menu coordination moves to a single-owner coordinator; the VC's surviving responsibilities each place cleanly. `reloadData()` identity-keyed survival preserved (DNT-8).

### PR11 — Grouping dedupe (shrunk / optional)
- **Scope.** REFACTOR-PLAN §8 P7 — **verified to be much smaller than designed.** The core predicate `isGroupableAssistant` is **already shared** between `SessionRuntime+Receive` and `ReverseEntryBuilder`; only the traversal direction (forward fold off `messages.last` vs reverse fold) differs by design and is intentionally kept. This PR factors out any *residual non-predicate* grouping rule, or — if none meaningfully unifies — **ships as a doc-only correction** of the stale "bridge uses EntryGrouping" annotation (the logic lives in `SessionRuntime+Receive`, not the bridge). May legitimately be a no-op PR.
- **Rows touched.** `SessionRuntime+Receive` (residual factor, optional), `ReverseEntryBuilder` (predicate already shared — `unchanged` likely).
- **Depends on.** none.
- **Risk.** medium (touches the runtime `receive` path; runtime-I1 sync fire + runtime-I3 order are do-not-touch, DNT-3/DNT-4).
- **Gate tests.** `TranscriptReverseBuilderTests`, `MessageEntryBlockBuilderTests`, bridge tests; full `make test-unit`.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Either a small shared-helper extraction with identical output, or doc-only. Does not change fire/order.

### PR12 — `SessionRuntime` projections + layering nits
- **Scope.** Extract three self-contained projections from `SessionRuntime` (REFACTOR-PLAN §8 P8): `TodoTracker`, `TaskTracker`, `ContextUsageCache`. **`TurnUsageMeter` is explicitly excluded** (rides the imperative `publishTurnUsage` sink + `turnStartedAt` ordering — fails the "don't touch fire/ordering" rule, §11). **Observed-nesting trap:** `tasks`/`todos`/`contextUsage` are *observed* `@Observable` fields with live readers, so each tracker MUST be `@Observable` held by an `@Observable`-tracked property (nested change must propagate — this is NOT a value-type extraction). Runtime stays the `@Observable` owner + sync `onMessagesChange` fire (runtime-I1) + unchanged `receive` order (runtime-I3); projections update inline in the same sync `receive` stack. `TaskTracker` completes the P4 loop (popover reads `session.tasks`→tracker, writes via `Session.stopBackgroundTask`). Plus layering nits (P15): `GitProbe` gains `@MainActor`; `ANSIAttributedBuilder` / `SyntaxTheme` / `PermissionMode+Color` / `Effort+Display` move out of `Models/` (synced-group → no pbxproj edit). All new types carry `nonisolated deinit {}` (C-6 / DNT-5).
- **Rows touched.** `TodoTracker` (★NEW), `TaskTracker` (★NEW), `ContextUsageCache` (★NEW, `@Observable` not value), `SessionRuntime+Todos`/`+Tasks`/`+ContextUsage` (storage relocates), `GitProbe` (@MainActor), `ANSIAttributedBuilder`/`SyntaxTheme`/`PermissionMode+Color`/`Effort+Display` (file move).
- **Depends on.** none hard; PR4 should land first so the façade is closed before the storage relocates (PR4→PR12 close the P4 pair).
- **Risk.** medium-high (observed-nesting must propagate live re-renders; runtime invariants do-not-touch).
- **Gate tests.** `SessionRuntimeTodosTests`, `SessionRuntimeTasksTests`, `ContextUsageTests` — **must assert live re-render** (not just terminal value), per §8 P8.
- **Rollback.** `git revert`.
- **Independently shippable & green.** Compose-not-flatten extraction; readers keep reading `session.todos`/`tasks`/`contextUsage` (same façade surface). Excludes `TurnUsageMeter` and the wide `Session` façade (§11). File moves are pure relocation.

### PR13 — Extract `TranscriptSwapCoordinator` (highest risk, last)
- **Scope.** REFACTOR-PLAN §8 P5 / §9 step 13 / §9.1 — extract the transcript-swap state machine from `ChatSessionViewController` into `TranscriptSwapCoordinator` by **verbatim method-body move** (no "while I'm here" simplification): attach orchestration, same-session crossfade, `fadingOutTranscript` parking, the §2.19 single-width contract, chat-I3/I4/I5/I14, and the per-attach `transcriptScroll` + `transcriptSheetPresenter`. The VC keeps "what to show" (scrim, bar host, focus, turn-usage, running-obs, first-screen logging). **Seam contract (§8 P5 R6), all four must hold or the class straddles two owners:** (i) z-anchor stays `addSubview(scroll, .below topScrim)` — scrim owned by VC, handed in (or an insert closure); (ii) **single owner of `currentSession`** — one object holds it, the other reads through it, never duplicated (duplication desyncs mid-crossfade and lets a stale sink call `setTurnUsage`/`setLoading` on the wrong controller); (iii) `applyScrimCutouts` coord transform keeps working when the scroll view migrates but scrim/bar host do not; (iv) the split line **passes through** `attachSession`, not around it. Optional `CrossfadeController` helper (P6) is **default NOT done** — it is a declared design defect, must never own the chat-I5 `removeObserver` pre-flush; keep two copies ("repetition cheaper than risk"). PR13 must keep the PR5 `permissionCardHost` as the 4th sibling and NOT re-insert transcript above it (M5).
- **Rows touched.** `TranscriptSwapCoordinator` (★NEW), `transcriptScroll` (moves into coordinator), `transcriptSheetPresenter` (moves into coordinator), `ChatSessionViewController` (sheds swap state machine → final conformant ✓).
- **Depends on.** PR5 (card host already a sibling in `loadView`), PR12 (runtime projections settled so the running-obs/turn-usage sinks read final surfaces).
- **Risk.** **high** — the single highest-risk item; the load-bearing AppKit choreography.
- **Gate tests.** the two merge gates `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests` (run green **before**, re-run **after**; if host test reddens, read the per-stage offender report in xcresult first — a tolerated multi-width write **is** the bug, never `XCTSkip`/loosen). `DetailPaneTranscriptHitTestTests` guards cursor-cutout/hit-test through a real swap. **Coverage gap (§9.1):** the same-session-crossfade finish-before-attach order (`fadingOutTranscript`) is a different path **not** covered by the two gates — either add a test for that ordering or accept manual-only smoke (A→B→A→A switch + in-place draft→active promotion + mid-transcript resize + cross-kind switch; confirm no blank flash / first-frame jitter / stale scrollbar).
- **Rollback.** whole-PR `git revert` — because it is a verbatim move, revert exactly restores the prior orchestration.
- **Independently shippable & green.** Verbatim relocation behind the two reentry merge gates; the VC and coordinator each place on exactly one side of the host-surface/swap seam. Conformant ✓ **only if** the four-point seam contract holds (flagged conditional in the defect list); honors all of DNT-1/2/3/4/6.

---

## Conformance & contract notes

- **Every non-`unchanged` table row is claimed by exactly one PR** (mapping table above). The only un-claimed `★`/`✗` entity is `CrossfadeController` — a **declared design defect, deliberately not introduced** (REFACTOR-PLAN §8 P6/§11); no row is created.
- **After each PR merges, every row it touched is Conformant ✓** under spec §6: the as-is `✗` rows (`BackgroundTaskButton` P4, `ChatRestingBar` sizing pump, `SidebarViewController` god-VC, `SyntaxHighlightEngine` misnomer, `NotificationService` dead inject, dead-code entities, `GitProbe`/`Models/` layering nits) each flip to ✓ at their mapped PR.
- **No PR weakens a do-not-touch contract.** PR3/PR13 stay out of renderer internals (DNT-1); PR13 honors the §2.19 single-width attach contract + runloop-tick orderings behind the two merge gates (DNT-2/3); PR5/PR6 honor host-sizing discipline and the BOUNDARY-SPEC merge gates, which are never `XCTSkip`'d or loosened (DNT-6); PR9/PR10 honor sidebar invariants 6.1–6.12 + `reloadData()` identity survival (DNT-7); PR12 carries `nonisolated deinit {}` on all new types (DNT-5) and excludes `TurnUsageMeter`/`Session` façade collapse (DNT-8).
