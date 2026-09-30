# macOS engineering conventions

Applies to all Swift under `macos/` — the app (`ccterm/`), `cctermTests/`, `TranscriptKit/`, `ExactList/`, `AgentSDK/`. Pure AppKit, programmatic. The app targets macOS 14; each package declares its own floor in `Package.swift`. Area-specific rules live in the nearest `CLAUDE.md`; the index is in the root `CLAUDE.md`.

## macOS runloop tick model

Most "why is this one tick off" puzzles in AppKit code resolve once you remember the order AppKit and CoreAnimation share a single runloop iteration. Every invariant phrased as "must run in AppKit's source phase" is written against this diagram:

```
┌─ source phase ─────────────── your code runs here ──────────┐
│  · NSEvent dispatch              (mouse / key / wheel)      │
│  · DispatchQueue.main.async      drained block-by-block     │
│  · Swift Concurrency @MainActor Tasks  resumed              │
│  · NotificationCenter posts                                 │
│  · Timer fires                                              │
│  · NSResponder selectors         (IBAction, performSelector)│
│                                                             │
│  setNeedsLayout / setNeedsDisplay / frame writes / bounds   │
│  writes land NOW — actual layout + draw + commit happen     │
│  in the next phase.                                         │
├─ beforeWaiting observer ─── AppKit + CoreAnimation flush ──┤
│  · NSWindow.update                                          │
│  · updateConstraints → layout → display walks the view tree │
│  · NSTableView's first display pass lazily queries          │
│    numberOfRows / heightOfRow and runs tile()               │
│  · CATransaction implicit commit → render server (IPC)      │
├─ sleep ──── thread blocks waiting for next event ───────────┤
│  render server animates on its own clock                    │
└─ afterWaiting ─ process the event that woke us → next tick ─┘
```

Load-bearing consequences:

- **Source-phase scroll / frame writes need the geometry they depend on already settled.** Anything in source phase that reads or writes lazy AppKit geometry (NSTableView row tile, NSClipView `constrainBoundsRect` against documentView.frame, NSScrollView tile) must have already triggered that geometry. Two ways to do that, in order of preference: (a) let the host's `view.layoutSubtreeIfNeeded()` size the subtree from its current frame — a size change to a freshly-attached scroll-host child cascades into the table and `NSTableView.tile()` runs inline **only if the table's `dataSource` is bound at that moment**; bound later, the tile fires on the next `layoutSubtreeIfNeeded` that runs with it bound; (b) explicitly invalidate via `noteNumberOfRowsChanged` / `insertRows` / `reloadData(forRowIndexes:)` if no enclosing frame change is going to happen. Writing first and waiting hands you a one-frame visual glitch.
- **`view.layoutSubtreeIfNeeded()` flushes autolayout, AND that triggers a chain of side effects that look like "not autolayout."** NSTableView's row layout, for example, is not directly an autolayout product — but the table's tile is gated on FRAME changes, and autolayout drives frame changes, so flushing the parent's autolayout transitively drives the table's tile when the table's size changes. The fragile case is the one where the table's frame *doesn't* change (e.g. a sibling-only invalidation, or `tableView.layoutSubtreeIfNeeded()` called on a table that's already at the right size); there `layoutSubtreeIfNeeded` is a no-op for row geometry and you have to invalidate explicitly. The takeaway: don't assume the doc surface ("autolayout product") is the boundary — frame-change-triggered re-tiles are the dominant case.
- **Implicit CALayer animations commit at beforeWaiting too.** Multiple property writes during one source phase coalesce into one transaction; wrap them in `CATransaction.setDisableActions(true)` + `NSAnimationContext.allowsImplicitAnimation = false` if you need them composited without animation rather than crossfaded.

Two stack-trace aliases worth memorising:

- `__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__` → you're inside a runloop observer (almost always CoreAnimation's beforeWaiting flush).
- `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` → source phase, draining `DispatchQueue.main`.

Subsystem-specific corollaries (e.g. how `TranscriptKit` loads and anchors scroll, [TranscriptKit §5](TranscriptKit/CLAUDE.md)) live next to the code; the diagram above is the only thing that's truly global.

## AppKit conventions

Pure AppKit (Swift), programmatic — no xib / Storyboard. The root discipline is two sentences: **slice responsibilities into single-direction layers** (Model has no UI, View only displays + reports, ViewModel derives presentation, Controller is a thin coordinator, Service/Store owns state, Coordinator owns flow), and **let data flow down, events flow up**. MVC is Apple's baseline; MVC+ / MVVM-C are the evolution path off it, not a replacement.

### Layering & unidirectional data flow

Every type maps to one baseline role — Model / View / Controller / Service·Store / Coordinator. **ViewModel** is an *optional* presentation layer you insert between View and Model only as a VC fattens toward MVVM-C — not a slot every feature must fill. A type that doesn't fit any role is usually where coupling hides.

| Layer | Typical type | Does | Never |
|---|---|---|---|
| **Model** | `struct` / `enum` | Carries data + domain rules; `Codable` at boundaries | No UI logic; does **not** `import AppKit` |
| **View** | `NSView` subclass, self-drawn | Only "display + report"; a dumb view | No business logic; no direct Service/network access |
| **ViewModel** | plain `class` (value type only when it holds no published stream) | Turns Model into ready-to-display values (formatting, state derivation); exposes `@Published`; unit-testable | Does **not** `import AppKit`; holds no `NSView` |
| **Controller** | `NSViewController` / `NSWindowController` | Coordinates view↔data, manages lifecycle | No business logic; no network/persistence |
| **Service / Store** | plain `class` (may be `@MainActor`) | Owns state, wraps I/O, publishes via Combine/callbacks | Does not reference View; does no UI |
| **Coordinator** | plain `class` | Navigation / flow orchestration, assembles Controllers | Does not render; does not own domain truth |

**Service vs. Store** — both are UI-free `class`es injected by initializer; split by what they primarily are. A **Service** is a *capability provider* — it wraps I/O and behavior (network, sync, notifications, parsing) and is mostly verbs (`sync()`, `loadUser(id:)`). A **Store** is a *state/cache holder* — its reason to exist is owning a body of state and publishing its changes (`RecentFilesStore`, an in-memory model store), mostly nouns + a change stream. When one type does both, name it for its dominant role; when a single type grows a large capability *and* a large owned state, that's the signal to split it into a Service + a Store.

### Data down, events up

The layers form one loop. With a ViewModel in place:

```
Service/Store  ── owns the single source of truth (@Published / callback)
     │  data down
     ▼
ViewModel      ── derives display values from Model (format, map, gate)
     │  data down (@Published)
     ▼
Controller     ── subscribes the VM, configures the View
     │  data down (configure(with:))
     ▼
View           ── renders only what it's handed (dumb)
     │  event up  (target-action / delegate / closure — intent only)
     ▼
Controller     ── translates the event into a VM/Service call
     │  event up  (viewModel.toggleRead() / service.markAllRead())
     ▼
ViewModel / Service ── mutates state → triggers the next data-down cycle
```

Without a ViewModel (plain MVC) the loop is the same minus that node: Service → Controller → View → Controller → Service.

- **State lives in exactly one source of truth.** The View caches no business truth; the Controller invents no truth (only subscribes). This is a "quasi"-unidirectional flow held by discipline, not a reducer framework — don't turn every click into an action object.
- **Never let a View mutate a Model directly, or hold+call a Service directly.** That makes a two-way / cyclic dependency and a second source of truth. A View reports intent via closure/delegate to its Controller; the Controller calls the injected VM/Service.

### SOP — placing a domain entity into MVVM-C

When a feature/entity arrives, split it across the layers instead of dropping it into one VC:

1. **Data → Model.** A value type (`struct`/`enum`), `Codable` at boundaries, zero UI. Domain rules that are pure functions live here (e.g. `isUnread: Bool`). Never put `NSColor`/`NSImage` or "how this field should look" here.
2. **State ownership + I/O → Service/Store.** A `class` with identity and lifecycle that holds the authoritative state, exposes it via Combine `@Published` / callback, and takes I/O (network, disk, sync). Injected by initializer — never `.shared`, never self-constructed.
3. **Presentation/derivation → ViewModel.** Formatting ("3 minutes ago"), state derivation (badge red vs. grey), "what to show" — a plain type with no AppKit import, unit-testable. This is the first step from MVC toward MVVM-C.
4. **Rendering → View.** A dumb `NSView` that `configure`s already-computed values and reports intent via closure/delegate. It never knows a Service exists.
5. **Assembly + lifecycle → Controller (+ Coordinator for navigation).** The VC subscribes the ViewModel (or the Service directly when there's no VM), feeds the View, translates the View's events into VM/Service calls. "Which screen next / who creates it" goes to a Coordinator (see below), not the VC.

Evolution direction is always the same: business & I/O sink from the VC into a **Service/Store**; presentation logic lifts into a **ViewModel**; navigation lifts into a **Coordinator** — so the VC stays a thin coordinator. Don't pre-pay: a small form is fine as plain MVC; introduce ViewModel/Coordinator when a VC starts to fatten.

### Project structure & modularization

Structure should make "locality of change" and "direction of dependency" hold by construction, not by discipline.

- **Organize by feature, not by file type.** Top-level dirs are feature names; a feature's VC, view, state, and coordinator live together (`Features/FeedList/…`). Never `Controllers/` + `Views/` + `Models/` — that scatters one feature across three dirs and invites cross-feature reference.
- **Sink the reusable, testable core into its own module (framework / local SPM package).** Data model / account / sync / parsing / persistence must not know `NSView` exists. Only the app (UI) target imports AppKit; the core packages never do. The dependency arrow is single-direction and downward (`App → Account → ArticlesDatabase → Articles`), enforced by the compiler — a stray `import AppKit` in a core module fails to build. Payoff: incremental compile boundaries, UI-free tests that run without a window/runloop, and hard (not conceptual) dependency edges.
- **One type per file**, named after the type (`FeedListViewController` → `FeedListViewController.swift`). A private nested type used only by its host may share the file; anything referenced across files gets its own. Protocol default impls go in an `extension` in the protocol's file.
- **Naming: role suffix for framework types, no suffix for data models.** `View` (custom `NSView`), `Controller`/`ViewController`/`WindowController`, `Service` (UI-free capability), `Coordinator` (navigation), `Store` (state/cache holder), `Delegate` (delegate protocol). Data models carry **no** suffix (`Article`, `Feed`), except that a type conforming to TranscriptKit's `Block` is named `…Block` (`CodeBlock`, `ParagraphBlock`), so a block reads apart from the markdown or AgentSDK model of the same content. The word also appears elsewhere without that meaning: `BlockStack` (a stack of blocks), the `Measured…Block` protocols (a block's measured result), and `MarkdownIR`'s node names inside that namespace. An internal child→parent protocol is `…Delegate`, never `…Owner`: Cocoa's delegates (`CALayerDelegate`, `NSTableViewDelegate`) also answer questions, not only report events, so the name fits every such protocol; `…DataSource` is only for a protocol that purely supplies data. A delegate or data-source method takes its sender first, labelled by the delegating type's name in lower camel case, or by the shorter label its public sibling already uses (`listView`, `editorArea`/`editorGroup`): `listAdapter(_:heightOfRow:rowWidth:)`, `listAdapterDidScroll(_:)`. An event is `did…`/`will…`, a question a noun, a void request `didRequest…`; a request whose answer the sender uses keeps Cocoa's verb (`doCommandBy:`, `acceptDrop:`). Why: the sender label names who is calling and keeps conformers that adopt several delegates unambiguous, and the verb tells the reader whether the method reports, asks, or commands. Avoid the vague `Manager` — pick the precise role word. Don't suffix models (`ArticleModel`/`FeedData` are redundant). Follow the Swift API Design Guidelines otherwise.
- **No `Utils` / `Helpers` / `Common` grab-bags.** They're entropy sinks that cross every dependency boundary. Extend the type the helper operates on (`extension String { var trimmed … }`) in the module that owns it, or make it a small named type — so each helper inherits its module's dependency constraints.

### Controllers & containment

The controller tree is a responsibility tree: `NSWindowController` at the root owns window-level logic; each `NSViewController` is one independently-existing UI region; containment propagates lifecycle/appearance and releases per-attach resources along the tree.

- **`NSWindowController` is the sole home for window-level logic.** Each independently-appearing window is owned by one window controller: create the `NSWindow` programmatically, mount the root VC via `contentViewController` (the window then delegates its content sizing to the root VC's Auto Layout tree), and keep frame autosave / title / toolbar / window-menu responses / close confirmation there. Never hold a bare `NSWindow` in `AppDelegate`, and never let a VC reach back to manipulate its own `window` lifecycle.
- **One VC per identifiable screen region.** Sidebar is a VC, timeline is a VC, detail is a VC — not one VC with three views + three data sources.
- **`loadView` builds the tree, `viewDidLoad` binds.** In programmatic `loadView()`: create views, add subviews, activate constraints, assign `self.view` — and do **not** call `super.loadView()` (its default loads a nib you don't have). No subscriptions or requests there. `viewDidLoad` (once) does dataSource/delegate wiring, subscriptions, one-time config. `viewWillAppear`/`viewDidAppear` (every time on-screen) do per-appearance refresh/focus/animation — and you **must** call `super` on the will/did-Appear family (skipping it breaks appearance propagation to child VCs).
- **Size before content.** Anything that depends on the view's size — measuring rows, a first scroll position, choosing a layout by width — runs once the view is mounted **and** laid out, never before. `viewWillAppear` is *before*: the view is not in the window yet and a container has not sized it (measured: a tab's view is 0×0 there under `NSTabViewController`). So a size-dependent first load goes in `viewDidAppear`, guarded to run once: `view.layoutSubtreeIfNeeded()`, then load. Loading earlier is not "slightly early" — it computes everything at a size of zero and then again at the real one, and whatever was drawn from the first pass shows until the second corrects it. Size-*independent* setup (data source wiring, subscriptions) stays in `viewDidLoad`.
- **Containment replaces the Massive VC.** System containers (`NSSplitViewController` / `NSTabViewController`) wrap each region in a child VC — and `addSplitViewItem`/`addTabViewItem` already call `addChild`, so don't call it again. Custom container (e.g. a "swap one child by selection" router): on insert, `addChild` → add `view` → activate constraints; on remove, remove `view` → `removeFromParent`.
- **SOP — when a VC must be split into a container + children.** Split when **any** of: (a) it implements more than one dataSource/delegate pair (two tables, etc.); (b) it holds several unrelated selection/scroll states; (c) `viewDidLoad` binds multiple subscriptions from different data domains; (d) a sub-region has its own appear/disappear lifecycle. The criterion is "how many independently-existing regions are inside", not line count.
- **Deterministic teardown of per-attach resources.** `removeFromParent()` severs the parent-child relationship, not the last strong reference — a removed child may be held briefly (swap animation, cache) and keep running timers/subscriptions against an off-screen view. So give detachable children an explicit hook (`prepareForRemoval()`), called by the container **before** removal, that releases per-attach resources (Combine subscriptions, in-flight `Task`s, timers, `dataSource`/`delegate` = nil, scroll view). Don't rely on `deinit` for this — its timing is unpredictable.

### Dependency injection & composition root

"Who needs what" is written on the type signature; "which concrete thing" is decided only at the composition root; nobody in between reaches for a global.

- **Initializer injection is the default.** Everything an object *needs to work* goes into `init` params, held as a **protocol** type, so the object is usable the moment it's constructed. Never reach for `SomeService.shared` inside a method body — that hides the dependency and leaves no test seam.
- **Property injection** for optional / late-set / weak collaborators — chiefly `delegate` (weak, defaultable; forcing it through `init` creates cycles and ordering problems). **Factory closure** (`(Args) -> T`) for "create on demand / each time a new instance" — keeps lazy creation without leaking the concrete type downstream.
- **Composition root: assemble the whole object graph in one place** — `AppDelegate.applicationDidFinishLaunching(_:)` (or an `assemble()` it calls). Here, and only here, concrete implementations are `new`'d and `import`ed; then handed top-down to window controllers. Reading the composition root reads the entire graph. Scattering `new SomeService()` across VCs destroys the single source of truth for the graph.
- **Aggregate dependencies into per-scope `Context` structs** to avoid constructor-param explosion — one per scope (process / window / session). Middle layers pass the `Context` through unchanged; leaf VCs read only the members they use. A `Context` is a **read-only dependency manifest**, not a shared mutable bag.
- **Singletons are compressed to "genuine process-level caches"** with a written-down reason (e.g. a model-list cache backed by a spawned CLI subprocess). A business service as `static let shared` is disguised global mutable state — route it through the composition root instead. It defeats injection and cross-test isolation.
- **`init(coder:)` is marked `@available(*, unavailable)` + `fatalError`** on every `NSViewController`/`NSView` subclass — pure-code, no Storyboard, so the coder path is closed off; this also blocks "empty-construct then assign piecemeal", which would bypass the dependency check.
- **This is what makes tests real:** construct the VC/VM directly, inject stubs through the same `init` seams, drive the public method, assert observable output — no singletons, no network. If a test can't reach a control, fix the **test** (drive the public surface); never add `forceXxxForTest()`, an env-var branch, or widened access.

### Coordinator & navigation

Navigation is flow knowledge, not view knowledge. A VC that knows "who's next" can't be reused; lift that decision into a Coordinator.

- **VC reports semantic events; Coordinator decides routing.** The VC exposes a `weak` delegate and reports *what happened* ("user selected session X", "user requested new session") — never creates/presents the next VC, never knows its type or presentation style, never constructs its dependencies. The Coordinator creates VCs, injects their dependencies, decides the route (present sheet / swap detail / swap `contentViewController`), and manages child-flow lifecycle. (For heavy navigation, a separate Router can execute the *how* — push/present/dismiss — while the Coordinator decides the *what*.)
- **Minimal `Coordinator` protocol: `start()` + a `childCoordinators` array.** Parent **strong**-references child (holds it in the array); child **weak**-references parent (or a completion delegate). This direction is a memory-correctness hard rule — a strong child→parent edge makes a parent⇄child cycle that never releases.
- **A child doesn't remove itself.** On flow end it reports up via delegate/closure; the **parent** calls `removeChild`. Every event that terminates a flow — including the non-standard ones (user hits the window close button, not your Confirm/Cancel) — must funnel into that one set of upward callbacks, or the parent's array keeps the child (and its dependencies) alive forever. For a sheet, drive it through `beginSheet`'s completion (or the host window's `NSWindowDelegate.windowWillClose`) so *any* close path normalizes to a "cancel" report.
- **Don't wrap a coordinator around every single-screen, no-branch VC.** Coordinators earn their keep on *multi-step, branching, reusable, or testable* flows; a screen with no next step is just created by its parent coordinator directly.

### View construction & layout

Keep the view dumb; keep layout declarative by default, imperative only by exception.

- **Programmatic view tree — no xib / Storyboard.** Declare subviews as `lazy var` whose closure does *only* self-configuration (no layout, no hierarchy). Keep "add to hierarchy" and "activate constraints" in two separate methods (`configureHierarchy()` / `configureConstraints()`), each called once from `viewDidLoad`, so a diff cleanly separates a structure change from a layout change. Never fuse create+configure+addSubview+constrain into one blob, and don't declare subviews as implicitly-unwrapped `!`.
- **Custom `NSView` subclass — four rules.** (1) Set `wantsLayer = true` when you touch `layer` (corner radius, background, CALayer animation), and refresh layer `CGColor`s in `updateLayer()` so they follow light/dark. (2) Override `isFlipped → true` **only** when doing manual `layout()` / self-drawing (top-left origin makes the arithmetic match reading order); a pure-Auto-Layout view must not override it. (3) Implement `intrinsicContentSize` when the view has a natural size, and call `invalidateIntrinsicContentSize()` on content change. (4) Reusable pieces expose a data entry point (`configure(with:)`) only — never expose internal subviews.
- **Auto Layout is the default.** (1) `translatesAutoresizingMaskIntoConstraints = false` on every participating view. (2) Batch with `NSLayoutConstraint.activate([...])` (one layout invalidation, one diff unit). (3) Prefer type-safe **anchor** APIs over VFL strings. (4) Use `NSStackView` for linear arrangements instead of hand-written equal-spacing constraints. Use content hugging / compression-resistance priorities to say who stretches and who stays fixed in a row.
- **Animate restrained, and only what appears or disappears.** A view coming or going (a find bar, a panel) is what gets motion; a selection change, a reorder, a relabel does not unless asked for. The component itself stays still inside while it moves. The AppKit way is one property through its animator — `NSAnimationContext.runAnimationGroup { _ in constraint.animator().constant = … }` (or `alphaValue`) — which moves that one thing and re-lays out the rest each frame without animating it. Never turn on `allowsImplicitAnimation` around a `layoutSubtreeIfNeeded()`: it animates *every* frame that layout changes, including a newly shown view's first layout, so its controls fly in from the origin. Honour Reduce Motion (`accessibilityDisplayShouldReduceMotion` → duration 0). Verify by looking — sample the moving view **and** its contents frame by frame, then watch it — not by checking that something moved.
- **Sink to manual `layout()` only when all three hold:** high-frequency re-layout (reused list cells, self-drawn views refreshed on a data stream) **and** simple layout rules (a few rects by fixed formula) **and** Instruments has confirmed Auto Layout is the bottleneck. Never hand-write `layout()` on ordinary one-shot UI "for performance", and never mix constraints with manual `frame` on the same subview.

Same "avatar + title" row, both ways — default to the left; switch to the right only when the three conditions above are met:

```swift
// Auto Layout (default) — declarative, self-adapting, insert/remove = edit the stack
let row = NSStackView(views: [avatarView, titleLabel])   // add to hierarchy + constraints once
row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
row.translatesAutoresizingMaskIntoConstraints = false
addSubview(row)
NSLayoutConstraint.activate([
    avatarView.widthAnchor.constraint(equalToConstant: 32),
    avatarView.heightAnchor.constraint(equalToConstant: 32),
    row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
    row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    row.centerYAnchor.constraint(equalTo: centerYAnchor),
])

// Manual layout() — imperative frames, no constraint solve; recompute on every size/content change
override var isFlipped: Bool { true }                    // top-left origin for the arithmetic
override func layout() {
    super.layout()
    let pad: CGFloat = 8, a: CGFloat = 32
    avatarView.frame = NSRect(x: pad, y: pad, width: a, height: a)
    let tx = pad + a + 10
    titleLabel.frame = NSRect(x: tx, y: pad, width: bounds.width - tx - pad, height: a)
}
```

### State & data flow

Without a framework doing dependency tracking, you wire "state → view" and "action → controller" by hand — and tear it down by hand. Pick the narrowest mechanism that fits; keep data down, actions up; never two-way.

Select by cardinality (1:1 vs 1:many) and direction (does it need to talk back):

| Mechanism | Cardinality | Talks back? | Use for | Lifecycle |
|---|---|---|---|---|
| target-action | 1:1 | no | control → controller action | weak target |
| delegate | 1:1 | yes (return/intercept/decide) | "should/how" collaboration | `weak var delegate` |
| NotificationCenter | 1:many | no (broadcast) | model change fanned out app-wide | remove observer / hold token before `deinit` |
| KVO | 1:many | no | observe a *system* object's property (prefer Combine for your own models; don't add `@objc dynamic` just to KVO them) | `NSKeyValueObservation` alive = observing |
| Combine (`@Published`) | 1:many | no | ViewModel → VC state push | `AnyCancellable` in a `Set` |
| closure callback | 1:1 | yes | one-shot / local completion | captured; mind `[weak self]` |

- **Combine ViewModel is the closest thing to a binding.** A ViewModel is a plain `class` that does **not** import AppKit; it exposes *already-computed presentation values* via `@Published` (`title: String`, `isEnabled: Bool`, formatted date). The VC subscribes in `viewDidLoad` — each `sink` uses `[weak self]`, stores its `AnyCancellable` in a `Set`, and updates UI on the main thread. `@Published` fires with `willSet` semantics, so use the value the `sink` closure receives — don't re-read the property inside the closure (you'd get the old value).
- **Data down, actions up — no two-way entanglement.** User action → VC calls `viewModel.someAction()` → VM mutates model + updates `@Published` → pipeline pushes back → VC refreshes controls. One loop; only the VM mutates state. Never have the VC both change a control *and* mutate the model (two truths), and never let a VM hold an `NSView` to write `label.stringValue` directly.
- **State lives at the lowest scope shared by all its readers.** Process/multi-window (settings, account) → app-level container, fanned out by NotificationCenter or a shared `@Published`. Window selection/navigation → a selection model owned by the window controller, handed to the detail side by delegate/closure. One VC's presentation state → that VC's ViewModel's `@Published`. Transient view-private UI state (is the search field expanded?) → a private stored property; no down-flow mechanism, no model field, no broadcast.

### Lists & data sources

Separate three things: **data truth** (dataSource/model, single), **visual projection** (view-based cell + idempotent view-model binding, purely functional), **update expression** (a snapshot declares "what it should be", the framework computes how to get there). Keep **identity** (stable id → item identifier) and **content** (Hashable value → re-bind trigger) strictly apart.

- **dataSource answers data, delegate answers looks.** `NSTableViewDataSource` = row count (+ which datum each row maps to); `NSTableViewDelegate` = `viewFor` (reused row view) / `heightOfRow` (or fixed `rowHeight`) / `selectionDidChange`. Never mutate the data array, fire a request, or write back from a cell inside `viewFor` — it's called high-frequency in unpredictable order; any side effect becomes a race.
- **Always view-based, never cell-based.** Row views subclass `NSTableCellView`, reused via `makeView(withIdentifier:owner:)`. Cell-based (`NSCell` + `dataCell`) is pre-10.7 legacy — no Auto Layout subviews, no control events, poor accessibility.
- **Reuse identifiers are centralized constants** (`extension NSUserInterfaceItemIdentifier { static let articleCell = … }`), referenced at both register and dequeue sites — a typo becomes a compile error instead of a silent `nil` (blank row).
- **Model each row as a `struct` cell view model** carrying already-formatted, directly-displayable values; the cell's `configure(with:)` binding must be **idempotent** (rewrites every field on reuse, no leftover state). A cell must not hold a domain object, read a global singleton, or format (`DateFormatter`) inside `viewFor`.
- **Diffable data source for dynamic data.** Use `NSTableViewDiffableDataSource` + `apply(snapshot:)` instead of hand-tracking `insert/remove/move` (the classic `NSInternalInconsistencyException` / lost-selection source). **Item identifier = *identity*** (a stable `id: String`/`UUID`), never the whole mutable model value — an identifier whose `hashValue` changes with content makes the framework treat an edit as delete+insert (wrong animation, lost selection). Express a content change via `reloadItems([id])` (macOS 11+) / cheaper `reconfigureItems([id])` (macOS 13+) — same item set, no insert/delete animation, no lost selection; prefer `animatingDifferences: false` for content-only updates.
- **Selection is a pull model — never cache indices.** The truth is `NSTableView.selectedRow(Indexes)`; when you need "who's selected", read it now and immediately convert to a stable identifier (`itemIdentifier(forRow:)`) to pass up. Restore selection by mapping the identifier back to a row (`row(forItemIdentifier:)`). Never store `selectedRow` in a model, and never hand an `NSTableCellView` instance out of the list (it gets reused).
- **Performance:** reuse (above) + fixed `rowHeight` (turn off automatic row heights when heights are uniform) + manual `layout()` inside hot cells only when Instruments proves constraint solving is the bottleneck.
- **`NSOutlineView` uses the same rules + hierarchy** (view-based, constant identifiers, cell view model, pull selection). Its diffable snapshot is flat (AppKit has no sectioned/tree snapshot), so for real trees, classic `NSOutlineViewDataSource` + manual `expandItem`/`collapseItem` is often clearer than forcing diffable. Drag-drop goes through `pasteboardWriterForItem` / `validateDrop` / `acceptDrop`.

### Memory, concurrency & testability

Three lines, one idea: make implicit relationships explicit — who retains whom, what runs on which thread, who can be replaced.

- **Default to strong; drop to `weak`/`unowned` only to break a cycle,** at fixed spots. `delegate` is always `weak` and its protocol is `AnyObject` (class-only). Any closure long-held by `self` that also uses `self` — stored closures, Combine `sink`, `NotificationCenter` block observers, long-lived `Task` — captures `[weak self]` + `guard let self else { return }`. (Don't blanket-weak *every* closure — a one-shot `DispatchQueue.main.async` UI update not held by `self` is fine strong.)
- **Combine subscriptions bind their lifecycle to the owner:** `[weak self]` in the `sink` **and** `.store(in: &cancellables)` into a `Set<AnyCancellable>` property — both, or the cycle (self → cancellables → closure → self) survives. The `Set` releasing on owner deinit cancels each subscription — that's the determinism.
- **Deterministic cleanup for out-of-band registrations.** `Timer` (RunLoop-retained) → block form + `[weak self]` + explicit `invalidate()`; old string-keyPath KVO / selector-based `NotificationCenter.addObserver` → explicit `removeObserver`. `deinit` is the last-resort backstop, not the plan. Closure-based `NSKeyValueObservation` and `AnyCancellable` self-remove when their property releases.
- **UI is main-thread only; `@MainActor` makes that a compile-time check.** Every `NSView`/`NSViewController` subclass and any UI-touching type is `@MainActor` (and keeps a `nonisolated deinit`). Push expensive compute/IO off the main actor via `await` on a non-isolated async function — a non-detached `Task {}` started from a `@MainActor` method stays on main and only leaves on `await`, returning automatically. Never write a UI property off-main, and never block the main RunLoop (sync network, `Thread.sleep`, semaphore `wait`, `DispatchQueue.global().sync`) — it freezes the UI.
- **Combine → UI must `.receive(on: DispatchQueue.main)` before `sink`.** `sink` runs on the thread the publisher sent on, regardless of the type's actor; `DispatchQueue.main` (not `RunLoop.main`, which drops delivery in tracking/scroll modes). The exception is a publisher owned by a `@MainActor` store or view model, whose values are only ever set on main: sink it directly, so the current value it emits on subscribing lands in the same tick and the first frame is already right (`.receive(on:)` would defer it a turn). Such a publisher's doc comment says it delivers on the main actor, and a consumer that takes one (`LibraryStore`, `SubscriptionService`, the settings sections) states it on its `init`.
- **Testability rides on DI.** Collaborators arrive as protocol types through `init`: production injects the real thing, tests inject a mock/spy. Drive the **public** method, assert **observable** output (`@Published` values, return values, mock call records). No `forceXxxForTest()`, no widening `private` → `internal` to peek, no env-var bypass; if the test can't reach a real control, fix the test. Drive async with `await` (never `sleep`+poll), keep the test `@MainActor` when reading UI state, and inject clock/randomness so runs are repeatable.

