# AppKit skeleton refactor

Rebuild the top-level of the app as pure AppKit, following the conventions in the root `CLAUDE.md`. This session only lays the **framework + foundation** — SwiftUI component files themselves are untouched and will be migrated in follow-up PRs.

Branch: `refactor/appkit`.

## Goal

- Replace the SwiftUI-App entry (`CCTermApp: App` + `@NSApplicationDelegateAdaptor`) with a pure `@main NSApplicationDelegate` + hand-built `NSMainMenu`.
- Introduce a proper Coordinator tree: `AppCoordinator` → `MainWindowCoordinator` → `DetailFlowCoordinator`, plus `SettingsWindowCoordinator` / `AboutWindowCoordinator` as lazy children of `AppCoordinator`.
- Split routing (Coordinator) from containment (thin container VC).
- Replace `@Observable` window-level state (`MainSelectionModel` / `TranscriptSearchBus` / `AppState`) with Combine `@Published` stores + a composition-root-assembled `AppContext`.
- Migrate the two toolbar SwiftUI hosts (`TranscriptProjectChip`, `ArchiveFilterToolbarButton`) to pure AppKit (`NSView` + `NSPopover`), since the main window is being rewritten and must not depend on hosted SwiftUI to render its chrome.
- Wire only the **transcript** into the new detail slot. Every SwiftUI-hosted detail child (`ComposeSessionViewController`, `DraftSessionLandingViewController`, `ArchiveViewController`, hosted `ChatSessionViewController` bar/permission-card hosts) is replaced by an AppKit placeholder VC for this session.

## Non-goals for this session

- Do NOT migrate `InputBarView2`, `ArchiveView`, `SettingsView`, `NewSessionConfigurator`, `ComposeSessionView`, `DraftSessionLandingView`, permission cards, background tasks, popovers under `Content/Chat/InputBarControls/*`, sheets under `NativeTranscript2/Sheets/*`, or any `Content/Chat/InputBarChrome.swift` piece. The files stay on disk unchanged. They just aren't referenced anywhere any more; they get picked up one-by-one in follow-up PRs.
- Do NOT touch `Transcript2Controller` / `NativeTranscript2/` internals. They're reused as-is; only the way they're mounted changes.
- Do NOT touch `SessionManager` / `Session` / `SessionRuntime` / `SessionRepository`.
- Do NOT touch the sidebar's internal implementation (`SidebarTreeModel`, cell views, group-order store, context menu). Only the **plumbing** between `SidebarViewController` and the selection layer changes: it stops observing `@Observable` selection and starts reporting semantic events via a delegate; it observes the new `SelectionStore` through Combine for the model→view highlight path.
- Do NOT keep any DEBUG demo entries in the sidebar. All demo VCs are SwiftUI-heavy; they're excluded from the new routing table wholesale and re-introduced (as needed) after their bodies land in AppKit.

## Layer map (after this refactor)

```
AppDelegate  (@main, pure NSApplicationDelegate)
   │  composition root: applicationWillFinishLaunching assembles
   │       AppContext = { sessionManager, syntaxEngine, recentProjects,
   │                      inputDraftStore, sidebarGroupOrder,
   │                      activationTracker, notificationService,
   │                      openInService }
   │  builds NSMainMenu with target = appCoordinator
   │  new AppCoordinator(context:)
   ├─ applicationDidFinishLaunching  → appCoordinator.start()
   ├─ applicationShouldTerminate     → appCoordinator.gracefulShutdown(reply:)
   └─ applicationShouldHandleReopen  → appCoordinator.reopenMainWindow()

AppCoordinator                         (process-scope)
   │  holds AppContext + childCoordinators
   ├─ start() → build+run MainWindowCoordinator (added as child)
   ├─ showSettings() → lazy build+run SettingsWindowCoordinator
   ├─ showAbout()    → lazy build+run AboutWindowCoordinator
   └─ each auxiliary window closing removes itself upstream via a
      completion delegate

MainWindowCoordinator                  (window-scope)
   │  holds WindowContext (= AppContext + SelectionStore + SearchBusService)
   │  weak parent: AppCoordinator
   │  childCoordinators: [DetailFlowCoordinator]
   ├─ start() → build MainWindowController(windowContext:),
   │           showWindow, addChild DetailFlowCoordinator
   ├─ mainWindowController(_:sidebarDidSelect:) → detailFlow.route(to:)
   ├─ mainWindowController(_:archiveFilterDidSelect:) → selectionStore.setArchiveFolder(_:)
   ├─ mainWindowController(_:searchQueryDidChange:) → forward to current session's Transcript2Controller
   └─ window will-close → weak parent.removeChild(self)

MainWindowController                   (thin NSWindowController)
   │  owns NSWindow (frame autosave, minSize, title chrome)
   │  contentViewController = MainSplitViewController
   │  toolbar delegate — creates NSToolbarItem instances only,
   │  reports all events via `MainWindowControllerDelegate`
   └─ no observers, no session lookup, no SwiftUI

MainSplitViewController                (unchanged shape)
   ├─ [sidebar]  SidebarViewController(SidebarContext)
   └─ [detail]   DetailContainerViewController()

DetailFlowCoordinator                  (detail-scope)
   │  holds DetailContext (= AppContext-slice + SelectionStore)
   │  weak parent: MainWindowCoordinator
   │  strong ref to DetailContainerViewController
   ├─ start() → route(to: selectionStore.selection)
   ├─ route(to: MainSelection) →
   │     ① compute ChildKind
   │     ② if same as current, do nothing structural
   │     ③ else new child VC, container.setChild(...)
   │     ④ selectionStore.select(...)   ← write only if caller was a
   │                                     semantic event, not a store observer
   ├─ notifications.onActivateSession → route(to: .session(sid))
   └─ sessionManager.onLaunchFailure → present alert on container.view.window

DetailContainerViewController          (dumb swap slot)
   │  single-child container, crossfade capable
   │  API: setChild(_ new: (NSViewController & DetailContainerChild)?,
   │                 animated: Bool)
   │  private: addChild/removeFromParent + constraints + alpha
   └─ knows NOTHING about ChildKind

Child VCs mounted by DetailContainerViewController:
   ├─ HistorySessionViewController     (this session — reuses Transcript2Controller
   │                                    via TranscriptSwapCoordinator; input bar
   │                                    is an AppKit placeholder view)
   ├─ NewSessionPlaceholderViewController
   ├─ ArchivePlaceholderViewController
   └─ (draft landing) NewSessionPlaceholderViewController too — draft
       and new-session share the same placeholder in this session
```

## Data down / events up

Only `SelectionStore` and `SearchBusService` are stateful and shared. Both are pure Combine — no `@Observable`, no `import SwiftUI`.

- `SelectionStore` (`@MainActor final class`):
  - `@Published var selection: MainSelection = .newSession`
  - `@Published var draftSessionId: String? = nil`
  - `@Published var archiveSelectedFolderPath: String? = nil`
  - `func select(_:)`, `func promote(to:)`, `func setArchiveFolder(_:)` — mutation entry points.
  - Nobody outside DI wires this. **Coordinators never `sink` on it — they set it**; the sink consumers are the display-derived VCs (sidebar highlight, toolbar chips) that need to keep their view in sync with whatever caused the change.
- `SearchBusService` (`@MainActor final class`):
  - `let focusRequests = PassthroughSubject<Void, Never>()`
  - `func requestFocus()` — sends on the subject; the ⌘F menu item calls this.

Sidebar delegate contract:
```swift
@MainActor protocol SidebarSelectionDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController,
                 didSelect selection: MainSelection)
}
```
`SidebarViewController` stops writing to `MainSelectionModel.select(...)`; it calls `delegate?.sidebar(self, didSelect: newSelection)` instead. The delegate is `MainWindowCoordinator`. For the highlight-restore path it subscribes to `store.$selection` via Combine (sync in-place delivery; the store is `@MainActor` so sink runs on main).

Detail container contract:
```swift
@MainActor protocol DetailContainerChild: NSViewController {
    func prepareForRemoval()
}
```
`prepareForRemoval()` is called by `DetailContainerViewController.setChild(...)` **before** removing the outgoing child from the tree, matching the deterministic-teardown rule in the root CLAUDE.md.

## Toolbar migration (SwiftUI → pure AppKit)

Only two items switch. Rules that apply to both:

- Custom `NSView` subclasses; four rules from CLAUDE.md observed.
- Auto Layout (`translatesAutoresizingMaskIntoConstraints = false`, batched `NSLayoutConstraint.activate([...])`).
- Data comes in via `configure(with:)`; events go out via a `weak var delegate` or a closure.
- `intrinsicContentSize` implemented so the toolbar auto-measures the item's slot.

### Project chip → `ProjectChipView`
- Two labels stacked in a vertical `NSStackView`; leading padding 12pt.
- Data type: `struct ProjectChipViewModel { var directoryName: String?; var branchName: String? }`. Reused from a pure derivation function in `MainWindowCoordinator`, not held on the view.
- MainWindowCoordinator subscribes to `store.$selection` + reads the corresponding `Session` (via `sessionManager.existingSession(_:)`) and rebuilds the view model on selection change. Then calls `mainWindowController.updateProjectChip(with:)` — VC-thin, view-thin.

### Archive filter button → `ArchiveFilterButton`
- Base is a plain `NSButton` (image only, template).
- Popover content: `FolderFilterPickerViewController` — an AppKit `NSTableView` with fixed-height rows, one per folder option, backed by a small `struct FolderFilterRow`. Selection commits via a delegate closure.
- Popover is anchored to the button; `NSPopoverDelegate.popoverDidClose` frees the picker.

### Search item
- Stays as `NSSearchToolbarItem` (already AppKit). The bridge that wires `TranscriptSearchBus` (@Observable) → `NSSearchField` is deleted and replaced by:
  - the search field's `NSSearchFieldDelegate` reports typing / return / shift-return via a `SearchBridgeDelegate` closure back to `MainWindowController`, which forwards to `MainWindowCoordinator`.
  - the ⌘F menu item calls `SearchBusService.requestFocus()`; the window controller's Combine sink on that subject calls `window.makeFirstResponder(searchField)`.

## Placeholder VCs

All placeholder VCs share a base look (grouped background, one centered `NSTextField` with the message). They subclass a small `PlaceholderViewController` that takes a `message: String`:

- `PlaceholderViewController` (`DetailContainerChild`): grouped-background NSVisualEffectView + centered NSTextField.
- `NewSessionPlaceholderViewController(message: "New Session not yet migrated from SwiftUI")`.
- `ArchivePlaceholderViewController(message: "Archive not yet migrated from SwiftUI")`.
- `SettingsPlaceholderWindowController` — a window controller whose contentViewController is a `PlaceholderViewController(message: "Settings not yet migrated from SwiftUI")`.
- `AboutPlaceholderWindowController` — same pattern.

`HistorySessionViewController` is not a "placeholder VC" in the message sense; it renders the real transcript. Its bottom `restingBarPlaceholder: NSView` is a rounded rect the same height as the current InputBar (~68pt) with a centered "Input bar not yet migrated from SwiftUI" label. No functionality inside it.

## Files that survive; files that go

### Reused as-is (implementation layer, no touch)
- `Content/Chat/NativeTranscript2/**`
- `Content/Chat/NativeTranscript2Bridge/**`
- `Services/**`
- `Components/Markdown/**`
- `Sidebar/{SidebarTreeModel,SidebarItemModel,SidebarCellViews,SidebarLayout,SidebarLoadingDotsView,SidebarSessionGroupOrderStore,SidebarShimmerLabel,SidebarStatusIndicatorView,SidebarTitleSanitizer,SidebarContextMenuController}.swift`
- `Models/**`, `Extensions/**`, `Resources/**`
- All SwiftUI component files under `Content/**` (they lose their mount site; nothing wires them). They stay for future migration PRs.
- `App/BuildInfo.swift`, `App/AboutView.swift` (unused after this refactor; the About window is a placeholder; the file stays so a follow-up About migration has something to work with).

### Adapted (architecture layer, thin edit)
- `Sidebar/SidebarViewController.swift` — swap `context.model` / `withObservationTracking` for `SidebarContext.selectionStore` (Combine) + `SidebarContext.selectionDelegate`. Kill DEBUG demo tree entries.
- `Sidebar/SidebarContext.swift` — replace `model` field with `selectionStore` + weak `selectionDelegate`.
- `Sidebar/SidebarItemModel.swift` — its `selection` computed accessor keeps mapping to `MainSelection`; only the `.demo` cases are dropped from any construction site.
- `App/AppKit/MainSelection.swift` — `enum MainSelection` kept; `.demo` case removed (with the `DemoKind` type also removed).
- `App/AppKit/TranscriptSwapCoordinator.swift` — kept, but its `context: DetailContext` parameter refers to the new (SwiftUI-free) `DetailContext`. Same shape — `context.sessionManager.prepareDraftSession(sessionId)` + `context.syntaxEngine`. Drop `import SwiftUI` in its file (the only SwiftUI thing it referenced was `DetailContext`; the new one is pure Foundation/AppKit).

### Rewritten in new files (architecture layer, new-write)
- `App/CCTermApp.swift` — DELETED.
- `App/AppState.swift` — DELETED.
- `App/TranscriptSearchBus.swift` — DELETED.
- `App/AppKit/AppDelegate.swift` — DELETED, rewritten as `App/AppKit/AppDelegate.swift` (same path). `@main NSApplicationDelegate`, composition root, main-menu construction.
- `App/AppKit/MainWindowController.swift` — DELETED, rewritten thin.
- `App/AppKit/MainSplitViewController.swift` — DELETED, rewritten to consume `WindowContext`.
- `App/AppKit/MainSelectionModel.swift` — DELETED (replaced by `SelectionStore`).
- `App/AppKit/DetailContext.swift` — DELETED, rewritten pure (no `import SwiftUI`, no environment injection extension).
- `App/AppKit/DetailRouterViewController.swift` — DELETED, split into `DetailContainerViewController` + `DetailFlowCoordinator`.
- `App/AppKit/MountFillPaneHost.swift` — DELETED (SwiftUI hosting glue, no consumers post-refactor).
- `App/AppKit/ChatSessionViewController.swift` — DELETED (replaced by `HistorySessionViewController` — SwiftUI-free, transcript + input placeholder).
- `App/AppKit/SettingsWindowController.swift` — DELETED, replaced by `SettingsPlaceholderWindowController`.
- `App/AppKit/AboutWindowController.swift` — DELETED, replaced by `AboutPlaceholderWindowController`.

### New files
- `App/Skeleton/AppContext.swift` — process-scope DI manifest.
- `App/Skeleton/WindowContext.swift` — window-scope DI manifest.
- `App/Skeleton/DetailContext.swift` — detail-scope DI manifest (thin slice of AppContext + SelectionStore).
- `App/Skeleton/SelectionStore.swift` — `@MainActor final class`, Combine `@Published` store.
- `App/Skeleton/SearchBusService.swift` — Combine focus subject.
- `App/Skeleton/Coordinator.swift` — minimal `Coordinator` protocol + base class.
- `App/Skeleton/DetailContainerChild.swift` — the `prepareForRemoval()` protocol.
- `App/Skeleton/SidebarSelectionDelegate.swift` — sidebar-out delegate protocol.
- `App/AppCoordinator.swift` — the app-scope coordinator.
- `App/AppKit/MainWindowCoordinator.swift`.
- `App/AppKit/MainWindowControllerDelegate.swift` — thin protocol.
- `App/AppKit/DetailFlowCoordinator.swift`.
- `App/AppKit/DetailContainerViewController.swift`.
- `App/AppKit/HistorySessionViewController.swift` — transcript + input bar placeholder.
- `App/AppKit/Placeholder/PlaceholderViewController.swift` — shared placeholder base.
- `App/AppKit/Placeholder/NewSessionPlaceholderViewController.swift`.
- `App/AppKit/Placeholder/ArchivePlaceholderViewController.swift`.
- `App/AppKit/AuxWindows/SettingsPlaceholderWindowController.swift`.
- `App/AppKit/AuxWindows/AboutPlaceholderWindowController.swift`.
- `App/AppKit/AuxWindows/SettingsWindowCoordinator.swift`.
- `App/AppKit/AuxWindows/AboutWindowCoordinator.swift`.
- `App/AppKit/Toolbar/ProjectChipView.swift` — pure AppKit chip.
- `App/AppKit/Toolbar/ArchiveFilterButton.swift` — AppKit button + popover host.
- `App/AppKit/Toolbar/FolderFilterPickerViewController.swift` — AppKit picker VC.

## Contracts — pinned early so parallel shells can compile against them

The following file bodies are written by me first, committed to `refactor/appkit`, and then every parallel shell reads them from the branch head:

- `App/Skeleton/AppContext.swift`
- `App/Skeleton/WindowContext.swift`
- `App/Skeleton/DetailContext.swift`
- `App/Skeleton/SelectionStore.swift`
- `App/Skeleton/SearchBusService.swift`
- `App/Skeleton/Coordinator.swift`
- `App/Skeleton/DetailContainerChild.swift`
- `App/Skeleton/SidebarSelectionDelegate.swift`
- `App/AppKit/MainWindowControllerDelegate.swift`
- `App/AppKit/MainSelection.swift` (edited in place: `.demo` case removed)

Parallel workers may treat those as read-only; they only add their own files.

## Parallel worktree split

All shells fork off `refactor/appkit` (after the contracts commit). Each Agent gets: (a) the root `CLAUDE.md`, (b) this doc, (c) a curated list of files it may read, (d) an exact list of files it MUST write. No two shells write to the same file.

| Shell | Owns (writes) | Reads (context) |
|---|---|---|
| **A. App entry + AppCoordinator + NSMainMenu** | `App/AppKit/AppDelegate.swift` (new), `App/AppCoordinator.swift` | contracts; `App/AppKit/AuxWindows/*Placeholder*` filenames only (uses them via delegate stubs — actual files come from Shell E) |
| **B. Main window + toolbar AppKit** | `App/AppKit/MainWindowController.swift` (new), `App/AppKit/MainWindowCoordinator.swift`, `App/AppKit/MainSplitViewController.swift` (new), `App/AppKit/Toolbar/ProjectChipView.swift`, `App/AppKit/Toolbar/ArchiveFilterButton.swift`, `App/AppKit/Toolbar/FolderFilterPickerViewController.swift` | contracts; `Sidebar/SidebarContext.swift` (adapted signature); `App/AppKit/DetailContainerViewController.swift` filename only |
| **C. Detail container + coord + placeholders + HistorySessionVC** | `App/AppKit/DetailFlowCoordinator.swift`, `App/AppKit/DetailContainerViewController.swift`, `App/AppKit/HistorySessionViewController.swift`, `App/AppKit/Placeholder/PlaceholderViewController.swift`, `App/AppKit/Placeholder/NewSessionPlaceholderViewController.swift`, `App/AppKit/Placeholder/ArchivePlaceholderViewController.swift` | contracts; `App/AppKit/TranscriptSwapCoordinator.swift` (adapt import) |
| **D. Sidebar adaptation** | `Sidebar/SidebarViewController.swift` (edit), `Sidebar/SidebarContext.swift` (edit), `Sidebar/SidebarItemModel.swift` (edit if needed) | contracts; `Sidebar/CLAUDE.md`; `Sidebar/SidebarTreeModel.swift` (reads only, to check DEBUG entries) |
| **E. Aux windows** | `App/AppKit/AuxWindows/SettingsPlaceholderWindowController.swift`, `App/AppKit/AuxWindows/AboutPlaceholderWindowController.swift`, `App/AppKit/AuxWindows/SettingsWindowCoordinator.swift`, `App/AppKit/AuxWindows/AboutWindowCoordinator.swift` | contracts |

Each shell runs in its own git worktree (`Agent isolation: "worktree"`) branched from the tip of `refactor/appkit` (with contracts committed). Independent branches, independent HEADs; I merge them back sequentially.

## Merge / integration order

1. Land contracts commit on `refactor/appkit`.
2. Kick off shells A / B / C / D / E in parallel.
3. As each finishes, merge its branch into `refactor/appkit`. Order:
   - **E first** (aux windows are leaves that only Shell A depends on).
   - **D** (sidebar; nothing else depends on it beyond its context signature already fixed by contracts).
   - **C** (detail; provides `DetailContainerViewController` that Shell B references).
   - **B** (main window; depends on D + C symbols).
   - **A last** (entry point; depends on B + E symbols).
4. On the integration merge, delete the old files listed above under "Rewritten in new files → DELETED".
5. `make build` — fix any residual references (imports, delete call sites into deleted files).
6. `make fmt`.
7. Hand-smoke: open the app, click through sidebar entries, confirm history session renders transcript, confirm placeholders read correctly, confirm ⌘, / About / ⌘F menu items behave, confirm window frame autosave still works.

## Sign-off checklist

- [ ] `import SwiftUI` count in `App/**` and `App/AppKit/**` is zero (verify with `grep -R "import SwiftUI" macos/ccterm/App`).
- [ ] `NSHostingView` / `NSHostingController` count in `App/**` and `App/AppKit/**` is zero.
- [ ] `@Observable` and `@Bindable` usage in `App/**` and `App/AppKit/**` is zero.
- [ ] `.shared` singletons in `App/**` are limited to `ModelStore.shared` (existing process cache).
- [ ] `AppDelegate` has `@main`. `CCTermApp.swift` file no longer exists.
- [ ] `Info.plist` (if any) points at NSApplication as principal class; no Storyboard key.
- [ ] `make build` succeeds Debug.
- [ ] `make fmt` clean.
- [ ] Cold-launch → main window opens → history session renders transcript → placeholders render text.

## Follow-up PRs (not this session)

- Migrate `InputBarView2` + all `Content/Chat/InputBarControls/*` to AppKit; wire into `HistorySessionViewController` in place of the resting-bar placeholder.
- Migrate `ArchiveView` to AppKit; wire into `ArchivePlaceholderViewController`'s slot (rename to `ArchiveViewController`).
- Migrate `NewSessionConfigurator` + `ComposeSessionView` to AppKit; likewise.
- Migrate `SettingsView` to AppKit.
- Migrate `AboutView` to AppKit.
- Migrate the two transcript sheets (`UserBubbleSheetView`, `ImagePreviewSheetView`) — they can stay SwiftUI-hosted a bit longer since they only run inside `NSHostingController` from `Transcript2SheetPresenter`.
- Restore DEBUG demo entries once their bodies are AppKit-ready.
