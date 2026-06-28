# Sidebar

The source-list history sidebar, built on `NSOutlineView` (AppKit by exception — gives folder drag-and-drop via `pasteboardWriterForItem` / `validateDrop` / `acceptDrop` and built-in `expandItem` / `collapseItem` animations). Post-refactor the responsibilities are split three ways; the table below is the map.

| Component | Type | Responsibility |
|---|---|---|
| `SidebarViewController` | NSViewController (`NoDisclosureOutlineView`) | Owns the outline view, drag-and-drop, selection write-back, and the three `withObservationTracking` loops (records, selection, per-row). Delegates tree-building to `SidebarTreeModel` and the right-click menu to `SidebarContextMenuController`. |
| `SidebarTreeModel` | `enum` (static, **pure**) | `build(records:groupOrder:previouslySeenGroups:)` → `(nodes, newGroups)`; `currentGroupSet(_:)`. No `UserDefaults`, no VC, no store — the caller snapshots `storedOrder()` and passes it in. Unit-testable without mounting the controller. |
| `SidebarContextMenuController` | NSObject, `NSMenuDelegate` | Owns the context menu end to end: construction, per-click `menuNeedsUpdate`, and the three actions (Archive / Open in / Copy Session File Path). Touches none of the VC's private state. |
| `SidebarContext` | `@MainActor struct` | DI bag: `{ model, sessionManager, groupOrderStore, openInService }`. Built by `MainSplitViewController.init` and passed as one `context:` arg. |
| `SidebarSessionGroupOrderStore` | `@MainActor final class` | UserDefaults-backed folder ordering (`storedOrder` / `prependIfAbsent` / `replace`). |
| `SidebarItemNode` | `final class` (**reference type**) | Heterogeneous outline node: `.fixed(FixedKind)` / `.folder(name:)` / `.history(sessionId:fallbackTitle:isDraft:)`. |

## Why a reference-type node + full `reloadData()`

`NSOutlineView` keys row reuse and expand/collapse state on `===`, so node **identity must survive a refresh**. `SidebarItemNode` is therefore a class, and structural refresh is a deliberate **full `reloadData()`** (in `rebuildItems`) — **not** a fine-grained insert/remove diff. `build` produces fresh node instances each call; `expandAllFolders()` re-expands after every reload because the new instances start collapsed.

## Selection: the echo-suppression guard

Selection is bidirectional and must not feed back on itself. `isApplyingSelectionFromModel` is the guard:

- **outline → model**: a user click fires `outlineViewSelectionDidChange` → `context.model.select(node.selection)`. Guarded: returns early when `isApplyingSelectionFromModel` is set.
- **model → outline**: `startSelectionObservation` watches `context.model.selection`; on change `applyModelSelection` → `selectRow(for:)` / `deselectAll`, **wrapped in `isApplyingSelectionFromModel = true/false`** so the resulting `…DidChange` notification is swallowed instead of writing the same selection back to the model.

Folder rows are non-selectable — `outlineView(_:selectionIndexesForProposedSelection:)` filters them out of any proposed selection (click, keyboard, programmatic); a folder click toggles expand/collapse via `outlineView.action` + `clickedRow`.

## Observation loops (all re-arm by recursion)

Each loop is a `Task` that awaits a single `withObservationTracking` fire, applies the change, then **calls itself to re-arm**. All are cancelled in `deinit`.

- **Records** (`startRecordsObservation`) — reads `sessionManager.records` (drafts ride along as `.draft`-status rows, so one read covers adds, promotions, archives) → `handleRecordsChanged` → `rebuildItems`.
- **Selection** (`startSelectionObservation`) — see above.
- **Per-row** (`armRowObservation`, keyed by `sessionId` in `rowObservations`) — tracks `session.title` / `isRunning` / `hasUnread` / `isGeneratingTitle` for the cell's session; on change re-applies `applyHistoryState` and re-arms. `configureHistoryCell` cancels the prior task when a cell is recycled to a different `sessionId` (cells also `prepareForReuse`). Re-arm is guarded on `cell.observedSessionId == sessionId` so a recycled cell drops its stale observation.

## Grouping + order rules

- **Grouping key** is `SessionRecord.groupingFolderName`; `nil` folds into an `"Unknown"` folder. Within a folder, records sort by `lastActiveAt` descending.
- **`build` vs `currentGroupSet` are deliberately asymmetric**: `buildRootChildren` folds `nil` into `"Unknown"`, but `currentGroupSet` **skips** `nil` — new-folder detection never fires for the `"Unknown"` bucket.
- **Folder order** (`SidebarTreeModel.arrange`, the pure inline form of the store's logic): names in `storedOrder` keep their stored relative position; the rest are appended sorted by `localizedStandardCompare`.
- **New-folder detection** lives in the VC, not in `build`. `handleRecordsChanged` diffs `currentGroupSet` against `lastSeenGroups`; newly-appeared names are `prependIfAbsent`'d (so a brand-new project rides to the top). **Ordering is load-bearing**: prepends MUST run before `rebuildItems`, because `rebuildItems` reads `storedOrder()` to lay out folders. `build`'s returned `newGroups` is ignored on the rebuild path (it would use the pre-prepend order). `lastSeenGroups` is seeded in `viewDidLoad` from the current set so cold-start doesn't treat existing folders as new.

## Drag-and-drop (folders only)

Payload is the folder name as a string under `SidebarLayout.folderDragType`. `validateDrop` allows reorder only at root level, between children (no "on" drops, no drops into a folder), clamped into `folderRange` (refuses drops above the fixed top items). `acceptDrop` mutates `rootChildren` in place + `outlineView.moveItem` to animate, then persists the full new order via `groupOrderStore.replace(with:)` (folder names, not session ids). The `targetIndex > oldIndex` decrement compensates for NSOutlineView's "source still in place" child-index convention.

## Cells + indicators

`NoDisclosureOutlineView` overrides `frameOfOutlineCell(atRow:)` → `.zero` to suppress the left-edge disclosure triangle; folder cells draw their own right-edge chevron. `indentationPerLevel = 0` (children flush-left; alignment relies on the shared 16pt icon slot, not outline indent). Per-row heights come through `outlineView(_:heightOfRowByItem:)` because `style = .sourceList` resets `rowHeight` after assignment (all three `SidebarLayout` heights are 32pt).

- `SidebarCellViewBase` — shared 16pt leading icon slot; `SidebarFixedCellView` / `SidebarFolderCellView` / `SidebarHistoryCellView` subclass it.
- **Titles**: `configureSingleLineTitle` flips both field- and **cell-level** wrap flags (field alone is insufficient) so an overlong title never wraps past its fixed row height. Display strings run through `String.collapsedSingleLineForDisplay()` (`SidebarTitleSanitizer`) — `usesSingleLineMode` does not strip `\n` / `\t` / zero-width / bidi controls from an assigned `stringValue`; the model-layer raw title is preserved.
- **`SidebarStatusIndicatorView`** (history leading slot): `.none` / `.running` / `.unread`; **unread outranks running** ("needs you" > "busy"), never both at once.
- **`SidebarLoadingDotsView`** — three dots on a shared `CAKeyframeAnimation` cycle (pulse-then-rest); attach/detach on window membership; phase-synced to wall clock for lockstep across cell reuse.
- **`ShimmerOverlay`** — `CAGradientLayer`-as-`layer.mask` skeleton shimmer on the title while `isGeneratingTitle`. Started/stopped from the history cell; idempotent.
- **Draft rows**: `isDraft` is snapshotted into the node at build time (from the record's `.draft` status), so the cell renders the dimmed "New Draft" placeholder (vs "Untitled" for a real session awaiting title-gen) without a per-row session lookup — durable across cold restart where the row isn't a cached `Session`.

## Rules

- `SidebarContextMenuController` and the menu's `target` / `delegate` are **not retained by AppKit** — the VC holds `contextMenuController` strongly; dropping it silently disables the menu. Construct it in `configureOutline`, after `context` exists.
- `menu.autoenablesItems = false` — the controller manages enabled state itself (the autoenable path would route through `validateMenuItem` and override the explicit greyed-out "Open in" / "Copy Session File Path" states). Those items grey out when the clicked session has no openable dir / no JSONL on disk.
- The menu reads the row via the closures the VC injects (`nodeAtRow` / `clickedRow` / `selectedRow`) — `clickedRow` first, `selectedRow` as the Archive / Copy fallback. "Open in" captures `path` + `target` in the `NSMenuItem.representedObject` at build time because `clickedRow` is invalid by the time the item fires.
- Adding a sidebar-scope dependency = one field on `SidebarContext` (+ its build site in `MainSplitViewController.init`), read via `context.X`. Unlike `DetailContext`, there is no SwiftUI environment counterpart — the AppKit controller reads it imperatively.

## See also

- [Content/Chat/CLAUDE.md](../Content/Chat/CLAUDE.md) — `MainSelectionModel` / `MainSplitViewController` / detail-side routing.
- [Services/Session/CLAUDE.md](../Services/Session/CLAUDE.md) — `SessionManager` / `SessionRecord` / `Session` state the sidebar reads.
