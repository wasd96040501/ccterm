# TranscriptWorkspace

An IDE-shaped area of up to two editors, left and right, each with its own tabs. **It depends on nothing in the package**, not even `TranscriptKit`: a tab holds any `NSViewController` and the compiler guarantees the area can't reach into it. A transcript doesn't know it's in a tab.

```
EditorAreaViewController      NSSplitViewController — the divider, which editor is active
└─ EditorGroupViewController  one per editor — its tab bar + an NSTabViewController
   └─ NSViewController        one per tab — never looked inside
```

## Structure is AppKit's

- **The split is an `NSSplitViewController`** — dragging, cursor, minimum widths, accessibility come with it, and **a divider drag is a live resize** for every view under it (`viewWillStartLiveResize` / `inLiveResize` / `viewDidEndLiveResize`), so a transcript's drag-time rules apply with no coupling. `EditorAreaTests` asserts it.
- **Tabs are an `NSTabViewController` (`.unspecified` style):** a tab is an `NSTabViewItem` whose view loads on first selection and is out of the window when not selected. Labels follow the view controller's `title`, and the bar follows labels by KVO.
- **`EditorTabBar` is built from what `NSSegmentedControl`'s `.tabs` role is made of** (track `secondarySystemFill`, selected tab an `NSGlassEffectView` inset 2pt) because segments can't be dragged. It matches the control pixel for pixel in both appearances and inactive windows — measure against the real control before changing how a tab looks.
- **The bar is always there**, one tab or none: it is where the tabs are, not a control that appears when there is a choice. It hangs from the group's `safeAreaLayoutGuide`, so under a window's toolbar (full-size content view) it sits below the titlebar — which takes clicks for moving and zooming the window, and would take a tab's drag.
- **A tab is a view placed by two constraints** (leading + width), one view per tab identity, so a reorder moves views instead of relabelling them. Slides animate those constants through their animators. Don't use `animator().frame` — on a layer-backed view it lays out once at the final size, so the glass jumps to its end width while the title slides.
- **The delegate is AppKit-shaped:** `editorArea(_:didActivate:)`, `editorArea(_:willClose:)`, `editorArea(_:tabViewItemForDrop:)` and `editorArea(_:tabViewItemWithIdentifier:)`, all defaulted. `willClose` is the container's `prepareForRemoval()` hook — a tab's owner stops its stream or load there, before the controller leaves the tree.

## Behaviour (Xcode's unless noted)

- A new tab selects itself; closing the selected tab selects the next. The right editor's last tab closes the editor; the only editor's last tab leaves it empty, never gone.
- **Pinned is Xcode 26's: every tab but the temporary one.** The temporary tab (`previewTabViewItem`) has its title in italics and its pin hollow, and is replaced where it stands by the next one, as one change (the replaced tab closes through `willClose`). A double-click on it, its pin, the menu's Pin Tab or setting `nil` pins it; a pinned tab's pin or Unpin Tab makes it the temporary one (the one that was is pinned). One state, not a flag beside the temporary tab. Moved to the other editor, a tab is pinned there. Close Other Tabs closes pinned tabs too.
- **History is per editor, Xcode's:** every change of what the editor shows is recorded by `NSTabViewItem.identifier` (compared as `AnyHashable`, never looked inside). AppKit gives every item an opaque identifier of its own, so an open tab is returned to with no help; a host that sets its own (the app: the transcript's URL) also gets closed ones back. `goBack()` / `goForward()` select the entry's tab if it is open, else show a tab the delegate makes in `editorArea(_:tabViewItemWithIdentifier:)` as the temporary tab; an entry it can't make is dropped. Navigating doesn't record; any other change clears the forward list.
- **Hover is Safari's, with Xcode's pin:** a tab under the pointer lights up one system fill down and shows its close button — Safari's disc on the centre of the leading end — and its pin mirrored on the trailing end; each in a halo under the pointer, a step deeper while pressed.
- **Dragging along the bar** keeps the tab under the pointer and on the track (x only); a neighbour whose middle its edge passes slides into the gap. It is plain mouse events, no drag session.
- **Pulled to the bar's edge** it becomes a drag session **while still over the bar**, so the bar is the first destination and shows it as the tab it was, its place held open. Leaving the bar is AppKit taking that change off — the tab turns, with AppKit's animation, into a small picture of its content (the group's view via `cacheDisplay`), centred on the pointer, and the tabs close up. Begun past the edge, the drag starts as the picture and has nothing to animate from.
- **Each side draws its own image, when AppKit says:** the source hands over the picture as the drag begins, in formation `.none` so it keeps its size away from any bar; a bar turns it into a tab the gap's width in `updateDraggingItemsForDrag(_:)`, and AppKit reverts it on exit. Never swap an image mid-drag from the source or `draggingEntered` — every attempt shrank pictures, squashed tabs, or put the centre off the pointer. A test cannot start a real session, so how the change looks is the demo's to show.
- **Dropped:** over a bar the tabs part and it drops into the gap; on the other editor's content it goes to the end; on the trailing half of its own editor's content it opens a new right editor (refused for an editor's only tab). Something from outside the editors — a type given to `registerForDraggedTypes` — drops the same way, its tab made by the delegate; on a non-empty editor's trailing half it opens a new right editor while there is room.
- **The active editor follows the reader:** the one last clicked inside (a local event monitor that only observes) or the one holding first responder (KVO) — two signals, because a margin click moves no focus and Tab moves focus without a click.

## What a tab's owner routes itself

- **⌘F is not a responder-chain action a view controller answers** — `performTextFinderAction:` is answered only by `NSTextView` (field editor). The demo's Find menu targets its window controller, which forwards to the active editor's tab. That's host logic and stays in the host.
- **`FindBarView`** is a view + delegate: it reports the query and `NSTextFinder.Action`s, is told the count, and knows nothing about what it searches. No Aa / Contains / replace controls — `TranscriptView.find(_:)` takes no options, and controls that do nothing are worse than none. Return / ⇧Return step; Escape / Done hide; the count reads "No matches" / "1 match" / "N matches"; arrows enable only when there's somewhere to go.
