# Survey: Sidebar (NSOutlineView source list)

Area: the AppKit-native sidebar that renders the session history list (fixed tabs +
grouped project folders + per-session history rows), writes the user's selection back to
`MainSelectionModel`, supports folder drag-and-drop reordering, and observes per-session
runtime state for its row indicators.

Scope read: all of `macos/ccterm/Sidebar/` plus the coupling surfaces it touches
(`MainSelectionModel`, `SessionManager`, `SessionRecord`, `Session`, `OpenInAppService`,
`MainSplitViewController`, `AppState`).

> All paths below are absolute. Line numbers are at the state of branch
> `epic-nightingale-1d6c6f`.

---

## 1. Component / type inventory

All types live under `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Sidebar/` unless noted.

| Type | Kind | One-line responsibility | file:line |
|---|---|---|---|
| `SidebarViewController` | `NSViewController` (`@MainActor final`) | The whole sidebar: builds the outline tree from `SessionManager.records`, owns the `NSOutlineView` + `NSScrollView`, is `NSOutlineViewDataSource` / `Delegate` / `NSMenuDelegate`, drives selection both ways, and arms per-row + records + selection observation. | `SidebarViewController.swift:33` |
| `NoDisclosureOutlineView` | `NSOutlineView` subclass (`private final`) | Suppresses the left-edge disclosure triangle (`frameOfOutlineCell(atRow:) -> .zero`) so the sidebar can draw its own right-edge chevron. | `SidebarViewController.swift:768` |
| `SidebarViewController.RecordGroup` | private `struct` | Ephemeral `(folderName, [SessionRecord])` bucket used only inside `groupedRecords()`. | `SidebarViewController.swift:299` |
| `SidebarViewController.OpenInRequest` | private `struct` | Captures `(path, target)` onto a menu item's `representedObject` at submenu-build time (clickedRow is stale by fire time). | `SidebarViewController.swift:253` |
| `SidebarItemNode` | `final class` (reference type) | Heterogeneous outline node: `.fixed` / `.folder` / `.history`. Reference type so `NSOutlineView` identity-keyed (`===`) row reuse survives `reloadData()`. Carries `kind`, optional `selection: MainSelection?`, and `children`. | `SidebarItemModel.swift:12` |
| `SidebarItemNode.Kind` | nested `enum` | `fixed(FixedKind)` / `folder(name:)` / `history(sessionId:fallbackTitle:isDraft:)`. | `SidebarItemModel.swift:13` |
| `FixedKind` | `enum: CaseIterable` | The fixed top tabs (newSession / archive + DEBUG demos). Each case maps to a `title`, `systemImage`, and `selection: MainSelection`. | `SidebarItemModel.swift:51` |
| `SidebarLayout` | `enum` (namespace) | Static layout constants: icon-slot width (16), gap (6), insets (6), uniform 32pt row heights, fonts, and the drag pasteboard type. | `SidebarLayout.swift:12` |
| `SidebarCellViewBase` | `NSTableCellView` subclass (`class`) | Shared base: a fixed-width leading `iconSlot`, vertically centered. Sub-classed by all three row cells. | `SidebarCellViews.swift:9` |
| `SidebarFixedCellView` | `NSTableCellView` subclass (`final`) | Fixed-tab row: SF Symbol icon + single-line title. Also hosts the shared `configureSingleLineTitle(_:)` static. | `SidebarCellViews.swift:40` |
| `SidebarFolderCellView` | `NSTableCellView` subclass (`final`) | Folder header: folder icon + dim title + spacer + right-edge chevron; `setExpanded(_:animated:)` crossfades chevron image. | `SidebarCellViews.swift:115` |
| `SidebarHistoryCellView` | `NSTableCellView` subclass (`final`) | History row: leading `SidebarStatusIndicatorView` + title; carries cell-side observation identity (`observedSessionId`, `fallbackTitle`, `isDraftRow`) and owns a `ShimmerOverlay`. | `SidebarCellViews.swift:218` |
| `SidebarStatusIndicatorView` | `NSView` subclass (`final`) | The 16pt leading slot in a history row. Three-state (`none` / `running` / `unread`); precedence unread > running. Hosts the dots view + an unread dot. | `SidebarStatusIndicatorView.swift:11` |
| `SidebarLoadingDotsView` | `NSView` subclass (`final`) | Three CALayer dots with a staggered keyframe "breath" opacity animation; attaches/detaches on window membership. | `SidebarLoadingDotsView.swift:18` |
| `ShimmerOverlay` | `final class` | Skeleton shimmer driven by a `CAGradientLayer` installed as the host `NSTextField.layer.mask`; idempotent `start()` / `stop()`. **Named `ShimmerOverlay`, but lives in file `SidebarShimmerLabel.swift`** (filename/type mismatch). | `SidebarShimmerLabel.swift:15` |
| `String.collapsedSingleLineForDisplay()` | `String` extension | Pure title sanitizer: collapses any whitespace/newline run to one space, drops control + zero-width/bidi formatting chars, trims. | `SidebarTitleSanitizer.swift:38` |
| `SidebarSessionGroupOrderStore` | `@MainActor final class` (service) | UserDefaults-backed source of truth for folder (project) display order. `arrange` / `prependIfAbsent` / `replace` / `storedOrder`. **Not `@Observable`** — order is read on demand inside `rebuildItems`, never observed. | `SidebarSessionGroupOrderStore.swift:21` |

External types this area depends on (defined elsewhere, surveyed for coupling):

| Type | file:line | Why it matters here |
|---|---|---|
| `MainSelectionModel` | `App/AppKit/MainSelectionModel.swift:35` | `@Observable` selection source-of-truth. Sidebar reads `model.selection`, writes via `model.select(_:)`. |
| `MainSelection` | `App/AppKit/MainSelection.swift:18` | Typed selection enum each node carries. |
| `SessionManager` | `Services/Session/SessionManager.swift:15` | `@Observable`. Sidebar reads `records`, `existingSession(_:)`; calls `archive(_:)`. |
| `SessionRecord` | `Services/Session/SessionRecord.swift:40` | Plain struct. Sidebar reads `sessionId` / `title` / `status` / `cwd` / `originPath` / `slug` / `lastActiveAt` / `groupingFolderName`. |
| `Session` | `Services/Session/Session/Session.swift` | `@Observable` façade. Sidebar reads `title` (302), `isRunning` (329), `hasUnread` (425), `isGeneratingTitle` (321). |
| `OpenInAppService` | `Services/OpenInAppService.swift:22` | `@Observable`. Sidebar reads `targets` and calls `open(path:with:)` from the context menu. |
| `HistoryLoader.locate(sessionId:slug:)` | `Services/Session/HistoryLoader.swift` | Resolves the JSONL path for the "Copy Session File Path" menu item. |

---

## 2. Component tree (this area)

Legend: `[AK]` = AppKit, `[SW]` = SwiftUI, `[svc]` = service. There are **no `NSHostingView` / `NSHostingController` boundaries inside the sidebar** — it is AppKit top-to-bottom (one of the project's documented AppKit exceptions). The only SwiftUI in the whole pane is zero.

```
AppDelegate [AK]
└─ MainWindowController [AK]
   └─ MainSplitViewController : NSSplitViewController [AK]            (App/AppKit/MainSplitViewController.swift:10)
      ├─ NSSplitViewItem(sidebarWithViewController:)  (min 220 / max 350 / frac 0.22, canCollapse)
      │  └─ SidebarViewController : NSViewController [AK]             (Sidebar/SidebarViewController.swift:33)
      │     └─ view: NSView (host, edge-pinned)
      │        └─ scrollView: NSScrollView [AK]  (.overlay, autohides, no bg/border)
      │           └─ documentView = outlineView: NoDisclosureOutlineView : NSOutlineView [AK]
      │              ├─ column: NSTableColumn("Sidebar")  (outlineTableColumn, autoresizing)
      │              ├─ menu: NSMenu  (Archive / Copy Session File Path / Open in ▸)   (delegate = VC)
      │              │  └─ Open in ▸ submenu  (rebuilt per right-click in menuNeedsUpdate)
      │              └─ rows (viewFor item, identity-keyed on SidebarItemNode ===):
      │                 ├─ .fixed   → SidebarFixedCellView : SidebarCellViewBase : NSTableCellView [AK]
      │                 │              └─ iconSlot(16) [NSImageView] + title [NSTextField]
      │                 ├─ .folder  → SidebarFolderCellView : SidebarCellViewBase [AK]
      │                 │              └─ iconSlot [folder NSImageView] + title + chevron [NSImageView, CATransition fade]
      │                 └─ .history → SidebarHistoryCellView : SidebarCellViewBase [AK]
      │                                ├─ iconSlot → SidebarStatusIndicatorView : NSView [AK]
      │                                │              ├─ dots: SidebarLoadingDotsView : NSView [AK] (3× CALayer + keyframe anim)
      │                                │              └─ unreadDot: NSView (cornerRadius, accent-colored layer)
      │                                ├─ title [NSTextField] (sanitized single-line)
      │                                └─ shimmerOverlay: ShimmerOverlay (CAGradientLayer mask on title)  [lazy]
      │
      └─ NSSplitViewItem(viewController: DetailRouterViewController)   ← sibling; not part of this survey
```

Injected dependencies into `SidebarViewController.init` (all owned by `AppState`, passed through `MainSplitViewController`): `model: MainSelectionModel`, `sessionManager: SessionManager`, `groupOrderStore: SidebarSessionGroupOrderStore`, `openInService: OpenInAppService` (`SidebarViewController.swift:79-90`, constructed at `MainSplitViewController.swift:23`).

---

## 3. Data flow

### 3.1 State INTO the sidebar (inbound, three observation channels)

The sidebar is a **reader** of three `@Observable` sources, observed through three independent self-re-arming `withObservationTracking` loops (the same async re-arm idiom used elsewhere in the app):

1. **Records → tree** (`startRecordsObservation`, `SidebarViewController.swift:401-418`).
   - Observes `sessionManager.records` (a single `_ = self.sessionManager.records` read inside `withObservationTracking`).
   - On change → `handleRecordsChanged()` (`:420-433`): diffs the current group set against `lastSeenGroups`, calls `groupOrderStore.prependIfAbsent(_:)` for newly-appeared folders, updates `lastSeenGroups`, then `rebuildItems()`.
   - `rebuildItems()` (`:265-273`): snapshots `currentSelection()`, rebuilds `rootChildren` via `buildRootChildren()`, **`outlineView.reloadData()`**, `expandAllFolders()`, then `selectRow(for:)` to restore selection.
   - `buildRootChildren()` (`:275-297`): `FixedKind.allCases` → fixed nodes, then `groupedRecords()` → folder nodes whose `children` are history nodes. **Direction: SessionManager → SidebarViewController → outline tree. One-way.**
   - `groupedRecords()` (`:304-319`): `Dictionary(grouping: records) { $0.groupingFolderName ?? "Unknown" }`, then `groupOrderStore.arrange(folderNames)` orders the buckets, then each bucket's records are `.sorted { $0.lastActiveAt > $1.lastActiveAt }`.

2. **Model selection → row highlight** (`startSelectionObservation`, `SidebarViewController.swift:385-399`).
   - Observes `model.selection`. On change → `applyModelSelection()` (`:375-383`): `.none` → `deselectAll`; otherwise `selectRow(for: model.selection)`.
   - Both paths set `isApplyingSelectionFromModel = true` around the programmatic select/deselect so the delegate's `outlineViewSelectionDidChange` doesn't echo the change back as a user action. **Direction: model → outline selection. (Guarded against feedback — see 3.3.)**

3. **Per-session runtime state → row indicators** (`armRowObservation`, `SidebarViewController.swift:692-715`).
   - One observation task per visible history cell, keyed by `sessionId` in `rowObservations: [String: Task]`.
   - Inside `withObservationTracking` it reads four fields off `sessionManager.existingSession(sessionId)`: `title`, `isRunning`, `hasUnread`, `isGeneratingTitle` (`:701-704`).
   - On change → `applyHistoryState(cell:…)` (`:717-738`) recomputes the display title (`title ?? fallback`, with `"New Draft"` / `"Untitled"` empty-fallbacks) and calls `cell.configure(...)`, then **re-arms itself**.
   - Guards: bails if the cell was recycled to a different `observedSessionId` (`:696-697`, `:709`). **Direction: Session → cell. One-way.**

### 3.2 Events OUT of the sidebar (outbound mutations)

- **Selection write** — user clicks a selectable row → AppKit fires `outlineViewSelectionDidChange` (`:639-649`) → if not echoing a model-driven select and the node has a `selection` and it differs → `model.select(selection)`. This is the sole production write to `MainSelectionModel`; `model.select` then synchronously drives the detail router (see Chat CLAUDE.md). **Direction: sidebar → model → router.**
- **Folder toggle** — folder rows are non-selectable (filtered in `selectionIndexesForProposedSelection`, `:626-637`); a click instead routes through `outlineView.action = #selector(handleOutlineClick(_:))` (`:437-444`) → `toggleFolder(node)` (`:446-471`): `outlineView.animator().expandItem/collapseItem` + eager chevron update on the cell. Expand/collapse state lives entirely in `NSOutlineView` (not mirrored into any model).
- **Archive** — context menu `Archive` → `archiveSelectedRow` (`:473-483`): if the archived session is the current selection, first `model.select(.newSession)`, then `sessionManager.archive(sessionId)`. **Two outbound writes (model + manager) in one handler.**
- **Copy Session File Path** — `copySessionFilePath` (`:485-495`) → resolves `jsonlPath` via `HistoryLoader.locate` → writes to `NSPasteboard.general`. (Side effect, no model write.)
- **Open in app** — `openInApp` (`:258-261`) → `openInService.open(path:with:)`. (Side effect.)
- **Folder reorder (drag-and-drop)** — `pasteboardWriterForItem` (`:520-527`) writes the folder name string; `validateDrop` (`:529-548`) clamps to the folder range and refuses on-drops / drops above fixed items; `acceptDrop` (`:550-580`) mutates `rootChildren` in place, calls `outlineView.moveItem(...)` to animate, then **`groupOrderStore.replace(with: newOrder)`** persisting the new full folder order to UserDefaults. **Direction: sidebar → groupOrderStore (UserDefaults).**

### 3.3 Bidirectional / back-channel coupling (flagged)

- **Selection is genuinely bidirectional**, but cleanly mediated. Inbound: `model.selection` → `applyModelSelection`/`selectRow`. Outbound: `outlineViewSelectionDidChange` → `model.select`. The loop is broken by the `isApplyingSelectionFromModel` flag (`:77`, set around `selectRowIndexes`/`deselectAll` at `:354-356`, `:377-379`) **and** by `model.select`'s own `guard newSelection != selection` no-op (`MainSelectionModel.swift:54`) and the delegate's `if model.selection != selection` check (`:646`). That's three independent guards against echo — defensible but redundant (see Smells).
- **`groupOrderStore` ↔ records observation hidden coupling.** `groupOrderStore` is *not* `@Observable`. A `replace(...)`/`prependIfAbsent(...)` write does NOT itself trigger a rebuild. The store's effect only materializes on the *next* `rebuildItems()`. In the drag path that's fine (the `moveItem` already animated the visual change, and `rootChildren` was mutated in place). In the `prependIfAbsent` path, the write happens *inside* `handleRecordsChanged` immediately before `rebuildItems()`, so it's read back in the same call. This is an implicit "write then read in the same function" contract, not an observed dependency — easy to break if someone moves the write.
- **`lastSeenGroups` is duplicated derived state.** It mirrors a projection of `sessionManager.records` (the set of `groupingFolderName`s). It exists purely to diff "new folder appeared" across two records-observation fires (`:69`, seeded in `viewDidLoad` at `:123`, updated in `handleRecordsChanged` at `:431`). It is a private cache of something derivable from the source of truth.

---

## 4. Ownership & lifetime

- **`SidebarViewController`** is constructed once in `MainSplitViewController.init` (`MainSplitViewController.swift:23-27`) and retained by the split as a private `let sidebarViewController` (`MainSplitViewController.swift:17`) wrapped in an `NSSplitViewItem(sidebarWithViewController:)` (`:47`). Lifetime = the main window's lifetime (single window app). Torn down with the window; its `deinit` (`SidebarViewController.swift:95-99`) cancels `recordsObservationTask`, `selectionObservationTask`, and every `rowObservations` task.
- **Injected services are owned by `AppState`** (process-scope) and merely referenced by the VC as `let` properties: `model`, `sessionManager`, `groupOrderStore`, `openInService` (`SidebarViewController.swift:36-39`; constructed in `AppState.swift:7-14`). The VC never constructs a service.
- **`scrollView` / `outlineView` / `column`** are `let` properties of the VC, constructed at property-init (`:41-43`) and wired in `loadView`/`configureOutline`. Owned by the VC for its lifetime.
- **`openInItem` / `copyPathItem`** are `let` `NSMenuItem`s held as fields (`:49-58`) so `menuNeedsUpdate` can re-enable/grey them; their submenu contents are rebuilt per right-click.
- **`rootChildren: [SidebarItemNode]`** is owned by the VC (`:64`), rebuilt wholesale on every records change and mutated in place during drag. Folder nodes own their `children` arrays (`SidebarItemModel.swift:30`). Nodes are reference types so `NSOutlineView` can identity-key them; AppKit holds them weakly via the data-source protocol while a row is realized.
- **Cells** (`SidebarFixedCellView` / `SidebarFolderCellView` / `SidebarHistoryCellView`) are created in `viewFor` (`:592-610`) and owned/recycled by `NSOutlineView`'s reuse machinery. `SidebarHistoryCellView` owns its `statusIndicator` (eager) and `shimmerOverlay` (lazy, allocated on first `isGeneratingTitle == true`, `SidebarCellViews.swift:292-294`); `prepareForReuse` (`:250-255`) clears `observedSessionId` / `isDraftRow` and stops the shimmer (but does **not** nil out `shimmerOverlay`, so the gradient layer persists on a recycled cell).
- **Per-row observation tasks** are owned by the VC's `rowObservations` dict (`:73`), keyed by `sessionId`. They are cancelled + re-created in `configureHistoryCell` when a cell's `observedSessionId` changes (`:681-684`) and on each re-arm (`:693`). Captured `[weak self, weak cell]` so neither the VC nor the cell is pinned across the `await`.
- **`SidebarLoadingDotsView`'s CA animations** are attached/detached on `viewDidMoveToWindow` (`SidebarLoadingDotsView.swift:44-51`) — lifetime tied to window membership, not the cell.

---

## 5. Smells / debt

> Severity reflects risk to a clean unidirectional refactor, not user-facing bugs.

### 5.1 `SidebarViewController` is an oversized "god VC" — **high**
`SidebarViewController.swift` is 770 lines and 7 concerns in one type: view construction, tree building, group ordering, three observation loops, drag-and-drop, context menu (build + validation + actions), and per-row state application. It conforms to `NSOutlineViewDataSource`, `NSOutlineViewDelegate`, and `NSMenuDelegate` all on itself. Evidence: the file spans `:33-770` with the data-source extension at `:500`, delegate at `:591`, per-row observation at `:677`, menu validation at `:743`. *Why it blocks the refactor:* the data-flow paths (records→tree, model→selection, session→row) are interleaved with menu/DnD plumbing, making the "what feeds what" graph hard to see. A clean split would be: a `SidebarTreeModel` (records → `[SidebarItemNode]` + group ordering, pure/testable), a thin VC that owns the outline + observation wiring, and a `SidebarContextMenuController`. This is the single biggest lever in the area.

### 5.2 Two-channel selection with triple-guarded echo suppression — **medium**
Selection is bidirectional with three overlapping guards: the `isApplyingSelectionFromModel` flag (`:77`, `:354-357`, `:377-379`, checked at `:640`), `model.select`'s own no-op (`MainSelectionModel.swift:54`), and the delegate's `if model.selection != selection` (`:646`). Any one of the latter two would prevent the echo loop; the flag is the belt, the value-comparisons are two suspenders. *Why:* three guards for one invariant is a maintenance hazard — a reader can't tell which is load-bearing, and removing the wrong one silently reintroduces feedback. (The flag *is* needed for the `deselectAll` path, since that has no value to compare against on the model side, but the history-row path is over-guarded.)

### 5.3 `lastSeenGroups` duplicates derived state — **medium**
`lastSeenGroups: Set<String>` (`:69`) is a private cache of `Set(records.compactMap(\.groupingFolderName))`, kept solely to diff "newly appeared folder" between two `records` observation fires (`:426-431`). It must be hand-maintained (seeded in `viewDidLoad` at `:123`, updated at `:431`) and is the only reason `handleRecordsChanged` is stateful rather than a pure `records → tree` function. *Why:* duplicated state that the refactor goal explicitly targets; the "new project rides to top" behavior could instead be derived (e.g. order-store seeding driven off `lastActiveAt` or a manager-level "session created" signal) so the tree build stays a pure projection of `records`.

### 5.4 Full `reloadData()` on every records change — **medium (perf-adjacent, but see invariant 6.2)**
`rebuildItems()` rebuilds `rootChildren` from scratch and calls `outlineView.reloadData()` (`:268`) on **every** `records` change — including a single session's `lastActiveAt` bump, a title generation completing, or a status flip. Reloading re-runs `viewFor` for all realized rows and re-arms every per-row observation. *Why:* for the bounded sidebar row count this is cheap enough today (no transcript-style perf contract here), but it's coarse: a unidirectional refactor that introduced a diff (insert/remove/move rows) would be both cleaner and cheaper. Note this is **not** a fine-grained-update area like the transcript — `reloadData()` is acceptable here, but it's the kind of coarseness a "clean data flow" pass would naturally tighten. Flagged so a refactor doesn't *assume* fine-grained diffing exists.

### 5.5 Filename/type mismatch: `ShimmerOverlay` in `SidebarShimmerLabel.swift` — **low**
The file is `SidebarShimmerLabel.swift` but the only type it defines is `class ShimmerOverlay` (`SidebarShimmerLabel.swift:15`). No `SidebarShimmerLabel` type exists. *Why:* violates the "file named after its type" convention; grep-by-filename misleads.

### 5.6 `ShimmerOverlay` is generic but Sidebar-scoped — **low**
`ShimmerOverlay` (`SidebarShimmerLabel.swift:15`) and the title sanitizer `collapsedSingleLineForDisplay()` (`SidebarTitleSanitizer.swift:38`) are both fully reusable, app-generic utilities (a `CAGradientLayer`-mask shimmer over any `NSTextField`; a pure string normalizer) that happen to live under `Sidebar/`. The sanitizer already has its own test (`cctermTests/SidebarTitleSanitizerTests.swift`). *Why:* mild misplacement — both belong under `Components/` / `Extensions/` if reused, but neither is used outside Sidebar today (verified: `collapsedSingleLineForDisplay` only at `SidebarCellViews.swift:285`; `ShimmerOverlay` only at `SidebarCellViews.swift:226,293`). Low priority; only matters if a second caller appears.

### 5.7 Hardcoded Chinese folder label in the model layer — **medium (correctness/localization; just outside Sidebar)**
`SessionRecord.groupingFolderName` returns the literal `"临时会话"` for temp-dir sessions (`Services/Session/SessionRecord.swift:142`). This string flows straight into the sidebar as a **user-visible folder header** (it becomes a `SidebarItemNode.folder(name:)` via `groupedRecords()` at `:308`, rendered by `SidebarFolderCellView`). Issues: (a) it's a raw Chinese literal in a Swift model, not `String(localized:)`, so an English-locale user sees Chinese; the CLAUDE.md localization rules require `String(localized:)` for user-visible names. (b) It also becomes the *grouping key* and the *drag/order key* (folder names are the identity for `groupOrderStore`), so localizing it naively would change the persisted-order key. *Why flagged here:* the smell surfaces in the sidebar even though the literal lives in the model; a sidebar refactor that touches grouping must be aware the display name doubles as a persistence/identity key. (It IS present in `Localizable.xcstrings` as a key, but the source-of-truth literal is not wrapped.)

### 5.8 Stale fallback group name `"Unknown"` is a non-localized magic string — **low**
`groupedRecords()` buckets records with no `groupingFolderName` under the literal `"Unknown"` (`:308`). Same class of issue as 5.7 (un-localized user-visible folder header), lower severity because records without a grouping path are rare.

### 5.9 `prepareForReuse` does not release the shimmer overlay — **low**
`SidebarHistoryCellView.prepareForReuse` calls `shimmerOverlay?.stop()` but leaves the instance allocated (`SidebarCellViews.swift:250-255`). The `CAGradientLayer` and its host reference persist on the recycled cell. Functionally fine (`stop()` removes the mask), but it's a small retained-resource asymmetry — the lazy-alloc has no matching lazy-free.

### 5.10 Context-menu state plumbed through `representedObject` + held `NSMenuItem` fields — **low**
The "Open in" path stores an `OpenInRequest` struct on each submenu item's `representedObject` (`:245`), and `openInItem`/`copyPathItem` are held as VC fields purely so `menuNeedsUpdate` can toggle `isEnabled`/`isHidden` (`:49-58`, `:744-759`) with `autoenablesItems = false`. This is idiomatic AppKit but is imperative state spread across three methods (`makeContextMenu`, `rebuildOpenInSubmenu`, `menuNeedsUpdate`) and the action handlers; a `SidebarContextMenuController` extraction (see 5.1) would localize it.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

### 6.1 `SidebarItemNode` MUST stay a reference type
`NSOutlineView` keys row identity and expansion state on object identity (`===`). `SidebarItemModel.swift:12` documents this explicitly ("Reference type so NSOutlineView's identity-based row reuse stays stable across reloadData()"). Converting to a `struct` would break expand/collapse persistence and row reuse across `reloadData()`.

### 6.2 Disclosure triangle suppression + zero indent + delegate row heights are interdependent
The custom right-edge chevron requires three coordinated settings: `NoDisclosureOutlineView.frameOfOutlineCell -> .zero` (`:769`), `indentationPerLevel = 0` (`:149`), and `outlineView(_:heightOfRowByItem:)` (`:612-619`) — because `style = .sourceList` resets `rowHeight`/`intercellSpacing`/indentation *after* assignment (`:144-154`). A refactor must keep `usesAutomaticRowHeights = false` and supply explicit per-kind heights, or long titles will stretch rows and bleed into neighbors. `outlineTableColumn = column` must remain set (`:139`) or child-of-item dispatch breaks.

### 6.3 Echo-suppression on selection MUST survive
The model→outline→model loop must stay broken. At minimum the `deselectAll` path needs `isApplyingSelectionFromModel` (`:377-379`) — that path has no model-side value to compare against (`outlineViewSelectionDidChange` would otherwise see a deselect and… find no node, so it bails at `:642-645`; but the flag is the documented guard). A refactor may simplify which guard is canonical (see 5.2) but must keep at least one that covers the deselect case.

### 6.4 Selection-change must reach the detail router in the SAME source phase
`model.select(_:)` synchronously notifies `DetailRouterViewController` (`MainSelectionModel.swift:53-57`, doc at `:4-17`). The sidebar's outbound write therefore MUST go through `model.select(_:)` (not a raw `model.selection =`) so the transcript mount lands in the same runloop tick as the click — this is the documented fix for the "switch fragments across frames" bug. A refactor that batched/deferred the sidebar's selection write would reintroduce that glitch.

### 6.5 Folder rows are non-selectable; clicks toggle expand/collapse
`selectionIndexesForProposedSelection` (`:626-637`) filters folder rows out of *every* proposed selection (click / keyboard / programmatic). Folder click is handled via `outlineView.action` + `clickedRow` (`:158`, `:437-444`), and the chevron is updated eagerly in `toggleFolder` to avoid a 1-frame lag. The `animator().expandItem/collapseItem` form is required — the doc at `:446-460` records that wrapping it in a manual `NSAnimationContext` group caused a "children fly in from the top" CoreAnimation race. Preserve both the non-selectable filter and the bare-animator call.

### 6.6 Drag-and-drop is folder-only, root-level, between-rows, clamped to the folder range
`validateDrop` (`:529-548`) and `acceptDrop` (`:550-580`) only accept folder-name pasteboard payloads (`SidebarLayout.folderDragType`), only at root level (`item == nil`), only between rows (refuse `NSOutlineViewDropOnItemIndex`), and clamp the index into `folderRange` (`:324-328`, fixed items occupy the first `FixedKind.allCases.count` slots). The same-parent index adjustment `if targetIndex > oldIndex { targetIndex -= 1 }` (`:567`) is required for correct `moveItem` semantics. After a commit, `groupOrderStore.replace(with:)` MUST persist the **folder-name** order (not session ids) (`:577-578`). Preserve all of these or reorder corrupts.

### 6.7 Per-row observation must re-arm and must guard against cell recycle
`armRowObservation` (`:692-715`) is a self-re-arming `withObservationTracking` loop keyed by `sessionId`, capturing `[weak self, weak cell]`. Two guards are load-bearing: cancel+replace the prior task when a cell switches `observedSessionId` (`:681-684`), and bail if the cell was recycled to a different session before applying (`:709`). Without these, a recycled cell renders another session's indicators, or two tasks fight over one cell. The four observed fields (`title`, `isRunning`, `hasUnread`, `isGeneratingTitle`) are read via `existingSession` (non-creating, `:701` → `SessionManager.swift:208`) so history rows don't force-spin-up a `Session` per record. The non-creating lookup is intentional — preserve it.

### 6.8 `existingSession` must NOT allocate
`SessionManager.existingSession(_:)` (`Services/Session/SessionManager.swift:208-210`) returns the cached `Session` or nil — never allocates. The sidebar relies on this so rendering N history rows does not instantiate N `Session` façades (each of which eagerly builds a `Transcript2Controller` + bridge). A refactor must keep row-state reads on the non-creating path.

### 6.9 Title rendering pipeline (sanitize + single-line) prevents row-height bleed
History/folder/fixed titles all run through `configureSingleLineTitle` (`SidebarCellViews.swift:95-106`) which flips both the field-level AND cell-level wraps/single-line flags (the comment notes field-level alone is insufficient), and history titles additionally run `collapsedSingleLineForDisplay()` (`:285`). Both are required: `usesSingleLineMode` only affects input layout, not an assigned `stringValue` with embedded `\n`/`\t`/zero-width chars (`SidebarTitleSanitizer.swift:9-37`). Dropping either lets a multi-line title overflow the fixed `heightOfRowByItem` and bleed into adjacent rows.

### 6.10 `lastSeenGroups` cold-start seeding semantics
`lastSeenGroups` MUST be seeded to the current group set in `viewDidLoad` *before* `startRecordsObservation` (`:123-127`), or the first observation fire treats every existing folder as "newly appeared" and prepends them all in arbitrary iteration order. If 5.3's duplicated-state smell is refactored away, the replacement must preserve "existing folders at launch are NOT treated as new."

### 6.11 `ShimmerOverlay` resting `locations` must equal `animationFrom`
`SidebarShimmerLabel.swift:31` documents that the static `gradient.locations` must match `animationFrom` `[0.0, 0.15, 0.3]`, or the frame the mask is installed renders the dim stripe at the wrong position ("title half-disappear before the animation kicks in"). `start()` also force-lays-out the host (`:68`) before sampling width. Preserve both.

### 6.12 Status indicator precedence: unread > running, never simultaneous
`SidebarStatusIndicatorView.update` (`:65-78`) resolves to a single state with unread outranking running (doc at `:7-10`: "needs you" outranks "busy"). The two visuals never render together. Preserve the precedence ordering.

---

## Appendix: cross-references

- **Construction chain:** `AppState.swift:7-14` (owns services) → `MainSplitViewController.swift:23-27` (constructs VC) → `SidebarViewController.swift:79-90` (init).
- **Selection contract:** `MainSelectionModel.swift:4-79` (the `select`/`promote` doc + `MainSelectionObserver`); detail-side consumer is `DetailRouterViewController` (Chat CLAUDE.md "Session switch").
- **Group ordering store:** `SidebarSessionGroupOrderStore.swift` — `arrange` (45), `prependIfAbsent` (60), `replace` (70). Not `@Observable`; read-on-rebuild only.
- **Tests touching this area:** `cctermTests/SidebarTitleSanitizerTests.swift` (pure sanitizer), `cctermTests/SidebarView2SnapshotTests.swift` (mounts the real `SidebarViewController` end-to-end — the `View2` in the name is a legacy filename, the test exercises the AppKit controller, not a deleted SwiftUI view). No unit test covers tree building, grouping, or drag-and-drop ordering directly — a `SidebarTreeModel` extraction (5.1) would make those testable.
```
