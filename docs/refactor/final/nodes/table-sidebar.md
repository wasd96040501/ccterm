# Ownership table — Sidebar

Scope: `macos/ccterm/Sidebar/*` plus the two target-new types (`SidebarTreeModel`, `SidebarContextMenuController`) introduced by REFACTOR-PLAN §5/§8 P3.

**Host-regime note (applies to every row):** the sidebar is **100% AppKit, no `NSHostingView` anywhere** (analysis-component-tree.md:104 "100% AppKit, no hosting boundary"). The closest BOUNDARY-SPEC regime would be **E (leaf SwiftUI in an AppKit cell)** — but the spec records E as having **no production instance** (BOUNDARY-SPEC.md:48, :341), and the sidebar cells are plain `NSTableCellView` subclasses, not hosts. Therefore every sidebar component's Host regime is **"—" (not a hosting boundary)**. This is conformant, not a defect.

**Construction note:** as-is, all four sidebar services arrive via `SidebarViewController.init(model:sessionManager:groupOrderStore:openInService:)` — a 4-bag (`SidebarViewController.swift:79-90`). Target (PR-DI, §5 "SidebarContext"): one `SidebarContext` value carrying `model` + the consumed services. Construction owner is unchanged (`MainSplitViewController`); only the parameter shape changes. "Constructed by" below reflects the target.

Layer mnemonic for AppKit sidebar pieces: the sidebar tree sits under the **Window-shell** (`MainSplitViewController` → sidebar item). The VC is its sub-controller; cells are per-row AppKit views; the tree model + group-order store are pure/value + app-scope-state respectively.

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SidebarViewController` | Window-shell | AK-VC | `MainSplitViewController` (target: `SidebarContext`; as-is: 4-bag init) | `MainSplitViewController` / window | `@Observable pull` (`withObservationTracking` on `model.selection`, `sessionManager.records`) | `model.select` (selection write-back, `:647`); `imperative controller call` (sessionManager.archive `:482`, groupOrderStore writes) | — | PR-Side2 (thin VC after split) | ✓ (as-is ✗: ~770-line god-VC, 7 responsibilities; PR-Side1/Side2 split fixes it) |
| `SidebarTreeModel` ★NEW | Pure-value | value/MDL | `SidebarViewController` (calls pure `build`) | n/a — pure function, no instance state | `ctor-injected` (records + groupOrder + previouslySeenGroups passed in) | `none` (returns `(nodes, newGroups)`) | — | PR-Side1 | ✓ |
| `SidebarContextMenuController` ★NEW | AppKit-coordinator | AK-NSObject (`NSMenuDelegate`) | `SidebarViewController` | `SidebarViewController` / window | `ctor-injected` (sessionManager, openInService, clicked-row resolver) | `imperative controller call` (sessionManager.archive, openInService.open, pasteboard write) | — | PR-Side2 | ✓ |
| `SidebarItemNode` | Pure-value | value/MDL (reference type — see issue) | `SidebarTreeModel.build` (as-is: VC `buildRootChildren`) | tree array on VC; lives across `reloadData()` | `ctor-injected` (kind/selection/children) | `none` | — | PR-Side1 (moves to tree model output) | ✓ (intentional reference type for `NSOutlineView` `===` identity, inv 6.1 — `SidebarItemModel.swift:3-12`; not a defect) |
| `SidebarItemNode.Kind` | Pure-value | value/MDL (enum) | inline | with node | n/a | none | — | unchanged | ✓ |
| `FixedKind` | Pure-value | value/MDL (enum) | inline | static | n/a | none (provides `title`/`systemImage`/`selection`) | — | unchanged | ✓ |
| `SidebarSessionGroupOrderStore` | App-scope-state | @Observable-SVC (plain `@MainActor` store, UserDefaults-backed) | `AppState.init` | `AppState` / process | `ctor-injected` (UserDefaults) | `@Observable write` (persists to UserDefaults via `arrange`/`prependIfAbsent`/`replace`) | — | unchanged | ✓ |
| `SidebarTitleSanitizer` (`String.collapsedSingleLineForDisplay()`) | Pure-value | value/MDL (`String` extension, pure fn) | n/a (free function) | n/a | n/a | none | — | unchanged | ✓ |
| `SidebarLayout` | Pure-value | value/MDL (constants enum) | n/a (namespace) | static | n/a | none | — | unchanged (P14 may de-dup pill/radius constants elsewhere, not here) | ✓ |
| `SidebarCellViewBase` | Per-attach (per-row) | AK-View (`NSTableCellView`) | `SidebarViewController` `viewFor` (recycled by outline) | `NSOutlineView` row reuse pool | `ctor-injected` (configured by VC each `viewFor`) | none | — | unchanged | ✓ |
| `SidebarFixedCellView` | Per-attach (per-row) | AK-View | VC `viewFor` | outline reuse pool | `ctor-injected` (`configure(kind:)`) | none | — | unchanged | ✓ |
| `SidebarFolderCellView` | Per-attach (per-row) | AK-View | VC `viewFor` | outline reuse pool | `ctor-injected` (`configure(folderName:isExpanded:)`, `setExpanded`) | none (chevron is local view state; expand/collapse is driven by VC) | — | unchanged | ✓ |
| `SidebarHistoryCellView` | Per-attach (per-row) | AK-View | VC `viewFor` | outline reuse pool | `ctor-injected` (`configure(...)` driven by VC per-row obs loop) | none | — | unchanged | ✓ (holds `observedSessionId`/`fallbackTitle`/`isDraftRow` view-local state for the recycle guard, inv 6.7/6.8 — `SidebarCellViews.swift:231-240`; legitimate cell state, not a layer straddle) |
| `SidebarStatusIndicatorView` | Renderer-internal (cell leaf) | AK-View (`NSView`) | `SidebarHistoryCellView` | parent cell | `ctor-injected` (`update(isRunning:hasUnread:)`) | none | — | unchanged | ✓ |
| `SidebarLoadingDotsView` | Renderer-internal (cell leaf) | AK-View (`NSView`, CALayer anim) | `SidebarStatusIndicatorView` | parent indicator | `ctor-injected` (visibility toggled by parent) | none | — | unchanged | ✓ |
| `ShimmerOverlay` | Renderer-internal (cell leaf) | AK-NSObject (CAGradientLayer mask helper) | `SidebarHistoryCellView` (lazy, `:293`) | parent cell (weak host ref) | `ctor-injected` (host `NSTextField`) | none | — | unchanged | ✓ |
| `NoDisclosureOutlineView` | Window-shell (sub-view) | AK-View (`NSOutlineView` subclass) | `SidebarViewController` (stored `outlineView`) | `SidebarViewController` | n/a (suppresses disclosure cell only) | none | — | unchanged (stays on VC after split — owns DnD/expand, inv per §8 P3 "DnD stays in VC") | ✓ |

## Non-conformant / design defects

None of the **target** rows are unplaceable — every sidebar type lands cleanly in exactly one layer with a clear in/out channel and "—" host regime (no hosting boundary). The two flagged ✗ entries are **as-is** states that the planned PRs resolve, recorded for the conformance trail:

- **`SidebarViewController` (as-is ✗ → target ✓):** today it is a ~770-line god-VC bundling 7 responsibilities — tree/grouping build, new-folder detection (hidden `lastSeenGroups` cache, `:69`/`:123`), 3 `withObservationTracking` loops, DnD, context menu + "Open in"/copy-path actions, per-row observation re-arm, and selection write-back. It straddles "pure tree derivation" + "AppKit coordination" + "menu controller." PR-Side1 (`SidebarTreeModel`, pure `build(records, groupOrder, previouslySeenGroups)` with the cache lifted to an **explicit input** to preserve inv 6.10) and PR-Side2 (`SidebarContextMenuController` + thin VC) place it cleanly. Channels are already clean (writes `model.select`, reads via `@Observable`), so this is a cohesion defect, not a data-flow defect.

Boundary/channel verification (no defects found):
- All four service inputs are ctor-injected; the VC never constructs a service (Rule 5 holds).
- Selection write-back goes through `model.select(_:)` (`SidebarViewController.swift:647`), never raw `selection` (inv 6.4 holds).
- Echo-suppression guard (`isApplyingSelectionFromModel`) prevents model→outline→model feedback (inv 6.3, `:354`/`:640`).
- `existingSession(_:)` is the non-allocating lookup used in the per-row obs loop (inv 6.8, `:700`); recycle guard checks `observedSessionId == sessionId` before re-applying (inv 6.7, `:697`/`:709`).
- Host regime "—" is correct for the entire scope: no `NSHostingView` exists in `Sidebar/*`; BOUNDARY-SPEC regime E ("leaf SwiftUI in cell") has **no production instance** (BOUNDARY-SPEC.md:48,341), and these cells are native `NSTableCellView`s. Classifying any sidebar cell as regime E would be wrong.
