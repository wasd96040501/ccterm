# Design: Concrete pain-point fixes (permission card first)

Self-contained implementation design for the ranked pain points in
`analysis-component-tree.md §4` (P1–P15) and the priority item from
`survey-permission-cards.md §6/§7`. Read-only investigation produced this;
nothing here is applied. Every claim is cited file:line against the worktree
`/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f`,
source root abbreviated `…` = `macos/ccterm`.

FACT = read in code. INFERENCE = my design read. Each fix is given as
**current mechanism → target mechanism → why cleaner → parity guarantee**,
with the load-bearing invariant a fix must not break called out explicitly.

> Scope note: the four cross-cutting analysis files named in the brief do not
> all exist yet on disk — only `analysis-component-tree.md` (whose §4 *is* the
> ranked pain-points list) and the 12 surveys. This design grounds itself in
> `analysis-component-tree.md §4/§5`, `survey-permission-cards.md`, and the
> source. The pain-point ranks below use the P-numbers from
> `analysis-component-tree.md §4`.

---

## 0. Priority — the permission card becomes a true floating overlay

### 0.1 The defect, precisely (FACT, from `survey-permission-cards.md §0`)

The card *is* drawn on the z-axis over the bar (`ZStack(alignment: .bottom)`,
`…/Content/Chat/InputBarChrome.swift:126`). The bar pill does **not** translate
inside that stack. But the **host that contains the stack grows upward** when the
card appears, and that growth is animated:

- `composeOrBarHost` is `NSHostingView<AnyView>`, `sizingOptions =
  [.intrinsicContentSize]`, bottom-anchored with **no height constraint**
  (`…/App/AppKit/ChatSessionViewController.swift:169,202-207`). Its height *is*
  the SwiftUI body's `fittingSize.height`.
- A `ZStack` reports the **union** of its children's sizes. When
  `pendingPermissions` goes empty→non-empty, the stack's intrinsic height jumps
  from `barHeight` to `max(barHeight, cardHeight)`; AppKit re-reads the host's
  intrinsic height, and because the host is pinned at the bottom its **top edge
  rises** (`…/InputBarChrome.swift:143-162`).
- `ChatRestingBar.body` ends with `.animation(.smooth(duration: 0.25), value:
  session.pendingPermissions.first?.id)` (`…/InputBarChrome.swift:166`). That
  single body-level animation drives **both** the card's own `.transition`
  **and** the host's intrinsic-height change. The visible band the host occupies
  expands upward over 0.25s — the "喧宾夺主 / shove" effect.

What does **not** move: the transcript scroll-view frame and its content inset
(fixed `contentInsets.bottom = 112`,
`…/Content/Chat/NativeTranscript2/AppKit/TranscriptScrollViewFactory.swift:40`).
So "transcript inset jumps" is FALSE; only the bar host resizes over the static
transcript.

**Root coupling (one sentence):** *card size → bar-host intrinsic height →
animated band growth.* A floating overlay must not resize its host.

### 0.2 Why the existing `ZStack` exists — the constraint the fix must honor

PR #235 (`7bf9918`) deliberately chose `ZStack` over `.overlay`
(`…/InputBarChrome.swift:93-101`). An `.overlay` is sized to its host; under the
bottom-anchored bar host the card's upper half would fall **outside the host's
hit-test bounds**, killing its buttons. `ZStack`-union-grows the host precisely so
the card stays hit-testable. So the fix is **not** "go back to `.overlay`" — that
re-introduces the exact bug #235 fixed. The fix must give the card a tall-enough,
hit-testable surface **whose size is constant and decoupled from the bar host**
(`survey-permission-cards.md §6 invariant 1`).

The same survey enumerates the other hard constraints (§6):
- **inv 2** — host must not publish a *required* intrinsic height that leaks into
  the window solver and collapses the window (root CLAUDE.md "host sizing").
- **inv 3** — the transcript must keep receiving clicks in the band above/around
  the bar; a plain `NSHostingView` claims every point in its bounds.
- **inv 4** — `pendingPermissions` stays a read-only `@Observable` forward; the
  card never caches/writes it.
- **inv 5** — decision path routes `Session.respond(to:decision:)` → `runtime.respond`
  → `pending.respond` (pinned by `PermissionCardWiringTests`).
- **inv 6** — `ChatComposeStack` routing + `.id(sid)` reset survive.
- **inv 7/8** — transcript §2 perf contract untouched; scrim/inset constants stay.

### 0.3 The mechanism already in the codebase that solves this

The scrims are the proof. `TranscriptScrimView` is a full-bleed-band `NSView`
whose `hitTest(_:)` returns `nil` (`…/Components/TranscriptScrimView.swift:61`) —
it draws over the transcript but is **transparent to the mouse**, so the table
below keeps receiving clicks (`…/Components/TranscriptScrimView.swift:160-162`).
`TranscriptBottomScrimView` even punches cutouts so the bar's attach button + pill
hit-test through it (`…/Components/TranscriptScrimView.swift:140-155`).

So the codebase **already runs an AppKit overlay that is full-bleed in size but
hit-test-passthrough where it doesn't "own" a point.** The permission card is
exactly that shape: a full-bleed surface, transparent everywhere except the card
rect, sized by the container (not by the card).

### 0.4 Chosen design — **(A) a dedicated, full-bleed, hit-test-passthrough card host**

This is option (A) from `survey-permission-cards.md §7`, made concrete. Reject
option (B) ("keep the ZStack, just don't animate the geometry") — see §0.8.

**Add one sibling overlay to `ChatSessionViewController`,** a peer of the three
existing full-bleed overlays (`topScrim`, `bottomScrim`, `composeOrBarHost`):

```
ChatSessionViewController.view : NSView                         [AppKit, full pane]
├── transcriptScroll        (pinned 4 edges)                    [AppKit]
├── topScrim                (pinned top, hitTest → nil)         [AppKit]
├── bottomScrim             (pinned bottom, hitTest → nil+cutouts) [AppKit]
├── composeOrBarHost        (bottom-anchored, intrinsic height) [AppKit↔SU]
│     └── ChatComposeStack → ChatRestingBar → InputBarChrome    [SwiftUI]
│           (⚠ card removed from here)
└── permissionCardHost      (pinned 4 edges, sizingOptions=[])  [AppKit↔SU]   ← NEW
      └── PermissionCardOverlay(model:)                          [SwiftUI]
            (full-bleed ZStack, hit-test-passthrough background,
             card bottom-anchored above the bar band, fades in place)
```

#### 0.4.1 The new AppKit host

A new stored property + constraints in `loadView()`, mirroring the scrim
pattern. It is the **fill-pane** sizing regime (`sizingOptions = []`, pin all 4
edges), because — unlike the bar host — its *job* is to be full-bleed and let the
container drive its size (root CLAUDE.md "Fill-a-pane host → `sizingOptions =
[]`"). It does **not** publish an intrinsic size, so it cannot leak height into
the window solver (inv 2 satisfied — this is the *opposite* failure mode of the
bar host, and `[]` is exactly the documented cure).

```swift
// ChatSessionViewController, new stored prop (peer of composeOrBarHost):
private var permissionCardHost: PassthroughHostingView<AnyView>!

// in loadView(), after composeOrBarHost is added:
permissionCardHost = PassthroughHostingView(
    rootView: AnyView(PermissionCardOverlay(model: model)
        .environment(sessionManager)
        .environment(\.syntaxEngine, searchEngine)   // DiffView in shell/file bodies
        .environment(recentProjects)))
permissionCardHost.translatesAutoresizingMaskIntoConstraints = false
permissionCardHost.sizingOptions = []                // fill-pane: container drives size
view.addSubview(permissionCardHost)                  // ABOVE the bar host in z-order
NSLayoutConstraint.activate([
    permissionCardHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    permissionCardHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    permissionCardHost.topAnchor.constraint(equalTo: view.topAnchor),
    permissionCardHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
])
```

`PassthroughHostingView` is a 6-line `NSHostingView` subclass whose `hitTest`
returns `nil` for points the SwiftUI body treats as background, identical in
spirit to `TranscriptScrimView.hitTest`. The simplest correct rule: forward
`hitTest` to `super`, but return `nil` when the hit lands on the body's
transparent background rather than the card. SwiftUI gives us this for free if the
overlay's background is `Color.clear.allowsHitTesting(false)` and only the card
subtree is hit-testable — then `super.hitTest` already returns `nil` over the
clear area (a `Color.clear` with hit-testing disabled is not a hit target). So in
practice **no subclass override is even required** if the body is built with an
`.allowsHitTesting(false)` clear background; `NSHostingView` already returns `nil`
where SwiftUI reports no hit.

> INFERENCE worth a one-line guard: `NSHostingView` historically claimed its whole
> bounds for tracking-area/cursor purposes even when SwiftUI reported no hit. The
> scrims sidestepped this by being pure `NSView` with an explicit `hitTest → nil`.
> To be safe and to match the proven scrim pattern exactly, ship the tiny
> `PassthroughHostingView` override (`hitTest` returns `super`'s result, but maps a
> hit on the host's own backing view to `nil`). This guarantees inv 3 regardless
> of `NSHostingView` cursor-rect behavior, at the cost of 6 lines. **Verify the
> plain-clear-background approach first via `PermissionCardSnapshotTests` + a
> click-through unit test; only add the subclass if a hit leaks.**

#### 0.4.2 The new SwiftUI overlay view

A small view that owns the card placement, reading the same `Session` the bar
reads, with the **identical** decision wiring lifted verbatim from
`ChatRestingBar` (inv 4/5 preserved by construction — it is a move, not a rewrite):

```swift
/// Full-bleed, hit-test-passthrough overlay that floats the permission
/// card above the resting bar band. Its OWN size is constant (it fills
/// the pane); the card fades in/out *inside* it with opacity+scale, so
/// nothing else in the pane moves. Replaces the card child of
/// `ChatRestingBar`'s ZStack.
struct PermissionCardOverlay: View {
    @Bindable var model: MainSelectionModel
    @Environment(SessionManager.self) private var manager

    var body: some View {
        // Only the chat selection has a bar to float above.
        let card: AnyView = {
            guard case .session(let sid) = model.selection,
                  let pending = manager.existingSession(sid)?.pendingPermissions.first
            else { return AnyView(EmptyView()) }
            let session = manager.prepareDraftSession(sid)
            return AnyView(
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce:     { session.respond(to: pending.id, decision: pending.request.allowOnce()) },
                    onAllowAlways:   { session.respond(to: pending.id, decision: pending.request.allowAlways()) },
                    onDeny:          { session.respond(to: pending.id, decision: pending.request.deny()) },
                    onAllowWithInput:{ session.respond(to: pending.id, decision: pending.request.allowOnce(updatedInput: $0)) }
                )
                .frame(maxWidth: BlockStyle.maxLayoutWidth)
                .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
                .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                .id(pending.id))
        }()

        ZStack(alignment: .bottom) {
            Color.clear.allowsHitTesting(false)        // passthrough background, fills pane
            card
                // Sit the card's bottom edge exactly where the bar's top edge is:
                // resting bar band ≈ chatBottomInset(36) + chrome row + pill.
                .padding(.bottom, Self.cardLiftAboveBar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25),
                   value: currentPendingID)            // animates ONLY the card transition
    }

    /// Distance from pane bottom to the card's bottom edge. Equal to the
    /// resting bar's total height so the card sits flush above the bar,
    /// exactly as the old ZStack(alignment:.bottom) placed it. Derived
    /// from the SAME constants the bottom scrim uses (§0.6).
    static let cardLiftAboveBar: CGFloat =
        ChatSessionViewController.bottomFadeScrimHeight   // 100, == bar band top

    private var currentPendingID: AnyHashable? { /* pending.id or nil */ }
}
```

Key points:

1. **The overlay's own frame is constant** (`maxWidth/maxHeight: .infinity`,
   pinned 4-edge by the host). The card appearing/disappearing changes only the
   *card subtree*, never the overlay's size. There is no union-height feedback,
   because the overlay is already full-size — the card growing inside it is a
   layout *within* an already-tall container. **The bar host's intrinsic height
   never changes**, so nothing else moves. (This is the entire fix.)
2. **The `.animation(.smooth)` now animates only the card's `.transition`** —
   opacity + scale-in-place — because the only thing keyed by `currentPendingID`
   is the card's presence inside a fixed-size container. No host geometry is in
   the animation path. The card "fades in in place." (inv: matches §0.1 defect
   directly.)
3. **The card is bottom-anchored to sit flush above the bar** via
   `.padding(.bottom, cardLiftAboveBar)`, reproducing the old
   `ZStack(alignment:.bottom)` + shared-`chatBottomInset` placement exactly
   (`…/InputBarChrome.swift:126,164`). Visual position is identical.
4. **Hit-test:** the clear background is `.allowsHitTesting(false)`; only the card
   subtree takes clicks. Clicks anywhere else fall through the host to the
   transcript (inv 3). The bar host is a *separate* sibling and is unaffected — the
   bar still hit-tests itself.

#### 0.4.3 Z-order and the bar host

`permissionCardHost` is added **after** `composeOrBarHost` (drawn on top). When a
card is pending it floats above and slightly over the bar's top edge — identical to
today's z-ordering where the card drew on top of the bar inside the ZStack. The bar
remains fully interactive: the card only covers the bar's chrome row region while
pending, exactly as before, and clicks on the visible bar pill (below the card) still
land because the card subtree only occupies the card rect.

#### 0.4.4 Remove the card from `ChatRestingBar`

`ChatRestingBar` (`…/Content/Chat/InputBarChrome.swift:111-168`) collapses back to
"just the bar": drop the `ZStack`, the `if let pending` card child, and the
body-level `.animation(.smooth)`. It becomes:

```swift
struct ChatRestingBar: View {
    // … same params …
    var body: some View {
        InputBarChrome( … )                              // unchanged params
            .frame(minWidth: BlockStyle.minLayoutWidth,
                   maxWidth: ChatSessionViewController.composeMaxWidth)
            .padding(.horizontal, ChatSessionViewController.detailHorizontalInset)
            .padding(.bottom, ChatSessionViewController.chatBottomInset)
            .frame(maxWidth: .infinity)
    }
}
```

Now the bar host's intrinsic height is a pure function of the bar content
(multi-line input still grows it, as the comment at `:167` always intended) and is
**never** a function of card presence. The stale comment block
(`…/InputBarChrome.swift:84-110`) describing the ZStack rationale is deleted /
replaced with a one-liner pointing at `PermissionCardOverlay`.

### 0.5 Before → after (the card composition)

| Aspect | Before (`ChatRestingBar` ZStack) | After (`PermissionCardOverlay` host) |
|---|---|---|
| Card surface size | `ZStack` union → grows bar host | full-bleed overlay, **constant** size |
| Bar host height on card show | rises (top edge moves up) | **unchanged** |
| What animates | card transition **+ host geometry** | card transition **only** |
| Hit-test surface for card | bar host grown tall (#235) | dedicated passthrough overlay |
| Bar host sizingOptions | `[.intrinsicContentSize]` (kept) | unchanged (bar only) |
| New host sizingOptions | — | `[]` (fill-pane; cannot leak height) |
| Card placement | bottom-anchored in bar ZStack | bottom-anchored in overlay, same offset |
| Decision wiring | 4 closures → `session.respond` | **identical 4 closures, moved verbatim** |
| `pendingPermissions` read | `session.pendingPermissions.first` | same, via `existingSession(sid)` |

### 0.6 Constants & the scrim/inset coupling (inv 8)

`PermissionCardOverlay.cardLiftAboveBar` reuses
`ChatSessionViewController.bottomFadeScrimHeight` (= 100,
`…/App/AppKit/ChatSessionViewController.swift:59`), the *same* hand-derived "bar
band top" the bottom scrim already uses. No new magic constant; the card sits
exactly where the resting bar's top is. `contentInsets.bottom = 112` and the
scrims are untouched (inv 7/8). The card is opaque (`PermissionCardSurface`, solid
`controlBackgroundColor`, `survey-permission-cards.md §1b`), so it floats over the
static transcript exactly as today — we are **not** introducing a dynamic
transcript inset (explicitly rejected by inv 7; the survey warns it risks the §2.7
anchor path).

### 0.7 Parity guarantee (priority item)

- **All card kinds:** `PermissionCardView` and its 14 per-kind bodies are reused
  **verbatim** — only their *host* changes. `PermissionCardKind` dispatch, the
  `bodyOwnsChrome` short-circuit for `askUserQuestion`, `PermissionShellCardBody`'s
  `DiffView`/`BoundedHeightScrollView`, every body file — untouched
  (`survey-permission-cards.md §1b`).
- **All four decisions** (allow once / always / deny / allow-with-input): the 4
  closures are copied character-for-character from `…/InputBarChrome.swift:146-155`
  into `PermissionCardOverlay`; they call the identical `session.respond(to:decision:)`.
  `PermissionCardWiringTests` (drives `session.respond` directly, not SwiftUI taps)
  passes unchanged (inv 5).
- **Read path:** `session.pendingPermissions.first` read via `@Observable`, no
  cache, no write (inv 4).
- **Routing:** card shows only for `.session(_)` (the overlay guards `case
  .session`), matching `ChatComposeStackRoutingTests` semantics (inv 6); the bar's
  `.id(sid)` reset stays on `ChatComposeStack`/`ChatRestingBar` (unchanged).
- **Snapshot:** `PermissionCardSnapshotTests` is updated to render
  `PermissionCardOverlay` over the bar instead of mirroring the ZStack manually
  (it already mirrors the composition by hand, `survey-permission-cards.md §1e`);
  the rendered card body is byte-identical.
- **Demo:** `PermissionSessionDemoViewController`'s hand-rolled
  `GeometryReader`+`PreferenceKey`+height-constraint loop
  (`…/Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:105-146`)
  is replaced with the same `permissionCardHost` overlay so the demo and production
  share one mechanism (kills smell #6).
- **Window-collapse:** the new host is `[]`+4-edge (fill-pane) — the *documented
  safe* regime; the bar host keeps `[.intrinsicContentSize]`. Neither leaks height.
- **Transcript §2 contract:** the overlay never touches the coordinator / layout
  cache / contentInsets (inv 7).

### 0.8 Rejected alternatives (priority item)

- **(B) Keep the ZStack, drop the geometry animation** (`survey §7`). Smaller
  diff, but the band still *snaps* taller (un-animated) on card show, and the
  card→host coupling remains. The user's complaint is the band moving at all;
  removing only the animation is a partial fix. **Rejected** — doesn't remove the
  coupling, only hides it.
- **Revert to `.overlay` on the bar host.** Re-introduces the exact #235 bug (card
  clipped + buttons outside hit-test bounds, inv 1). **Rejected.**
- **Make the transcript inset dynamic so it shifts to clear the card.** Violates
  inv 7 (risks §2.7 scroll-anchor path), and the user explicitly does *not* want
  the transcript to jump. **Rejected.**
- **Reserve a fixed tall bar-host height always.** Keeps the host in one sizing
  regime but wastes a permanent tall hit-opaque band over the transcript (inv 3
  regression — the band swallows transcript clicks even with no card). **Rejected.**
- **Present the card as a real `NSWindow`/popover/sheet.** Heavyweight, focus-steal,
  loses the "belongs to the bar, floats in the pane" feel, and `beginSheet` blocks
  the window. **Rejected** — the in-pane overlay is lighter and matches the design.

---

## 1. P1 — Delete the dead `notifications` + `searchBus` environment injections

**Current mechanism (FACT).** Every detail-VC hosting boundary injects
`.environment(notifications)` and `.environment(searchBus)` — e.g.
`…/App/AppKit/ChatSessionViewController.swift:580-581`,
`…/App/AppKit/DetailRouterViewController.swift:434-435`,
`ComposeSessionViewController.swift:104-105`,
`ArchiveViewController.swift:79-80`,
`DraftSessionLandingViewController.swift:127-128`. **No SwiftUI view reads either
type** (`analysis-component-tree.md P1`: grep for `NotificationService.self` /
`@Environment(TranscriptSearchBus` → 0). Both reach their consumers through AppKit
channels only.

**Target mechanism.** Delete the two `.environment(...)` lines at all 5 (+1 demo)
host sites. Keep the actually-consumed env set: `SessionManager`,
`RecentProjectsStore`, `InputDraftStore`, `\.syntaxEngine`. (The VC stored props
`notifications`/`searchBus` are *separately* still needed by AppKit code — only the
*SwiftUI injection* is dead; this fix removes only the injection.)

**Why cleaner.** The injection implies a SwiftUI dependency edge that doesn't
exist; an env-driven refactor (P2) would chase a phantom. Removing it makes the
real consumed-env set exactly four, which P2's helper then formalizes.

**Parity.** Pure deletion of unread injections — no view reads them, so no body
changes. No test references them (`analysis-component-tree.md P1`). AppKit channels
(`onActivateSession` push, `withObservationTracking` toolbar bridge) are untouched.

---

## 2. P2 — Collapse the 7-arg DI bundle into one `DetailContext` + one env helper

**Current mechanism (FACT).** `MainSplitViewController.init` destructures
`appState` and threads a **7-arg bag** into the router, which forwards it to all 4
children; each child VC re-declares the identical 7 stored props + identical
`init(model:sessionManager:recentProjects:notifications:searchEngine:searchBus:inputDraftStore:)`
+ identical `init?(coder:)`; `makeChild` repeats the 7-arg call 4×
(`analysis-component-tree.md P2`, sites:
`DetailRouterViewController.swift:114-131,363-410`,
`ChatSessionViewController.swift:124-141`,
`ComposeSessionViewController.swift:44-61`,
`DraftSessionLandingViewController.swift:26-60`,
`ArchiveViewController.swift:31-51`).

**Target mechanism.** One value struct threaded whole:

```swift
struct DetailContext {                 // app-scope deps the detail side needs
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let syntaxEngine: SyntaxHighlightEngine     // ← renamed (P10b)
    let inputDraftStore: InputDraftStore
    let notifications: NotificationService       // AppKit consumers only
    let searchBus: TranscriptSearchBus           // AppKit consumers only
}
```

Each child VC takes `init(context: DetailContext)` and stores the one struct (or
unpacks the few fields it actually uses). `makeChild` passes `context` once. Add one
SwiftUI helper for the *consumed* env set (after P1 prunes the dead two):

```swift
extension View {
    func injectDetailEnvironment(_ ctx: DetailContext) -> some View {
        self.environment(ctx.sessionManager)
            .environment(ctx.recentProjects)
            .environment(ctx.inputDraftStore)
            .environment(\.syntaxEngine, ctx.syntaxEngine)
    }
}
```

**Why cleaner.** Adding/removing one app-scope dep becomes a **1-site edit** (the
struct) instead of 5–6. The 6-line `.environment` block stops being copy-pasted 5×.
The DI fan-out point stays at `MainSplitViewController` (one construction site;
"views never construct services" preserved — `DetailContext` is assembled from the
already-destructured `appState`, not by a view). Does **not** require injecting
`AppState` whole (the `model` isn't part of `AppState`, `analysis-component-tree.md
§3 "DI fan-out"`).

**Parity.** Mechanical re-bundling; identical objects reach identical consumers.
The `init?(coder:)` stays `@available(*, unavailable)`. No behavior change. Best
sequenced *after* P1 (so the helper carries the correct 4-entry env set) and *with*
P10b (the rename lands inside the struct field name in one pass).

**Rejected.** Injecting `AppState` itself as one env value — the analysis flags
(P11) that `AppState` is *never* injected whole and the root-CLAUDE doc claiming
otherwise is drift; widening to inject the whole container would over-expose
services no detail VC needs (e.g. `sidebarGroupOrder`, `activationTracker`).

---

## 3. P4 — Add a `Session.stopBackgroundTask` forwarder (close the façade hole)

**Current mechanism (FACT).** `BackgroundTaskButton` reaches
`runtime.markTaskStoppedLocally(taskId:)` directly
(`…/Content/Chat/InputBarControls/BackgroundTaskButton.swift:80-85`) — the only
production UI that pierces `session.runtime`. No `Session.stopBackgroundTask`
forwarder exists (`markTaskStoppedLocally` defined only at
`…/Services/Session/Session/SessionRuntime+Tasks.swift:124`). Violates the
documented rule "views write through `Session` methods, never `session.runtime.X`"
(`Content/Chat/CLAUDE.md` Rules; `Services/Session/CLAUDE.md` Rules).

**Target mechanism.** One phase-aware forwarder on `Session`, mirroring the
existing `requestContextUsage` pattern (`…/Services/Session/Session/Session.swift:393-402`):

```swift
/// Mark a background task as locally stopped. No-op on `.draft`
/// (no runtime, no tasks).
func stopBackgroundTask(taskId: String) {
    runtime?.markTaskStoppedLocally(taskId: taskId)
}
```

Then `BackgroundTaskButton.stopAction` becomes
`{ taskId in session.stopBackgroundTask(taskId: taskId) }`, dropping its
`session.runtime` unwrap entirely.

**Why cleaner.** Restores the single-channel rule: all writes go through the
`Session` façade, which dispatches on phase. The button no longer knows the phase
enum exists.

**Parity.** `runtime?.x` is exactly the behavior of the old `guard let runtime`
unwrap (no-op when nil). The fix is in the *product* and *strengthens* the
invariant — explicitly endorsed by `analysis-component-tree.md P4` and the
engineering principle "the fix is in the product, not a test hook." Add a one-line
`SessionFacadeTests` case asserting the `.draft` no-op + the `.active` forward
(drive the public surface, per `cctermTests/CLAUDE.md`).

---

## 4. P10b — Rename `searchEngine` → `syntaxEngine` across the detail VCs

**Current mechanism (FACT).** The `SyntaxHighlightEngine` is threaded under the
param/property name `searchEngine` across 6 VCs, then re-exposed as
`\.syntaxEngine` (`analysis-component-tree.md P10b`, sites:
`MainSplitViewController.swift:34`, `DetailRouterViewController.swift:75,119,127,416`,
`ChatSessionViewController.swift:69,129,137`, `ArchiveViewController.swift:25,36`,
`ComposeSessionViewController.swift:38,49`, `DraftSessionLandingViewController.swift:30,45`).
A reader expects transcript *search* machinery; it is unrelated to
`TranscriptSearchBus`.

**Target mechanism.** Pure rename `searchEngine` → `syntaxEngine` everywhere
(it becomes the `DetailContext.syntaxEngine` field in P2). No type change, no
behavior change.

**Why cleaner.** Removes a genuine cross-wire confusion (`searchEngine` vs
`searchBus`); the name now matches the `\.syntaxEngine` env key it feeds.

**Parity.** Identifier-only edit; the compiler enforces correctness. Best folded
into P2's struct migration (one pass touches the same sites).

> P10a (the closure-sink triple-declaration in `Session.swift:103-149,259-263`) is
> *intentional* (set-before-promotion vs set-at-promotion timing,
> `analysis-component-tree.md P10a`). **Leave it**; keep the doc. Not worth a helper
> that obscures the timing.

---

## 5. P3 — Split `SidebarViewController` into tree-model + VC + menu controller

**Current mechanism (FACT).** ~770-line god-VC doing 7 concerns: view
construction, tree building, group ordering, three `withObservationTracking` loops,
drag-and-drop, the whole context menu, per-row state application — all conforming to
`NSOutlineViewDataSource`/`Delegate`/`NSMenuDelegate` on itself
(`…/Sidebar/SidebarViewController.swift:33-770`; data-source ext `:500`, delegate
`:591`, per-row obs `:677`, menu `:743`). No unit test covers tree
building/grouping/DnD.

**Target mechanism (three extractions).**
1. **`SidebarTreeModel`** — pure value transform `(records, groupOrder) →
   [SidebarItemNode]`. No AppKit. Directly unit-testable (grouping + ordering +
   DnD reordering as pure functions over the array).
2. **`SidebarViewController`** (thinned) — owns the `NSOutlineView`, the
   observation wiring (the three `withObservationTracking` loops), and per-row state
   application; delegates tree shape to `SidebarTreeModel`.
3. **`SidebarContextMenuController`** — `NSMenuDelegate` + the menu actions, handed
   the VC's selection/model.

**Why cleaner.** Separates the three data paths (records→tree, model→selection,
session→row) from menu/DnD plumbing; makes tree/grouping/DnD testable for the first
time.

**Invariants to keep (FACT, `analysis-component-tree.md P3`):** `SidebarItemNode`
stays a **reference type** (identity-keyed rows, survey-sidebar 6.1);
echo-suppression on selection survives (6.3); writes go to `model.select(_:)` not
raw `selection` (6.4); per-row obs re-arm + recycle guard + non-allocating
`existingSession` (6.7/6.8). The synchronous single-observer selection spine
(`analysis-component-tree.md §5.2`) must not be perturbed — the sidebar still calls
`model.select(_:)`.

**Parity.** Extraction only; same outline output, same selection writes, same
DnD/menu actions. Add `SidebarTreeModelTests` for the newly-pure transform. Medium
risk: do after P1/P2/P4 land green.

---

## 6. P7 — Unify live + cold grouping/tool-pairing into one engine

**Current mechanism (FACT).** Two engines produce `MessageEntry`/`GroupEntry` from
`Message2`: the live `receive` path grows groups forward off `messages.last`
(`…/Services/Session/Session/SessionRuntime+Receive.swift:274` `appendToTimeline`,
`:310` `attachToolResult`); the cold path reverse-folds via `ReverseEntryBuilder`
(`…/Services/Session/Session/ReverseEntryBuilder.swift:35`). They share only
`isGroupableAssistant` and one parity test.

**Target mechanism.** Factor the grouping + tool-pairing *rules* (what groups with
what; how a tool-use pairs with its result) into one shared, pure
`MessageGroupingRules` that both directions call — live appends one entry at a time
through it, cold reverse-folds through it. The two *drivers* (forward vs reverse)
stay separate; only the rule body is shared.

**Why cleaner.** A grouping-rule change becomes a one-place edit instead of two
guarded only by a single parity test.

**Invariants (FACT, `analysis-component-tree.md P7`):** history never flows through
the bridge (bridge-I1); "no `.update` on load" (bridge-I9); cross-page withhold
buffer + doc-order parse (bridge-I8). The `receive` side-effect ordering
(runtime-I3) must be preserved — the shared rules must be *pure* (no observable
writes) so the live driver keeps firing `onMessagesChange` synchronously at the
same site.

**Parity.** Keep the existing parity test; add cases pinning the shared rules in
isolation. Medium risk — guarded by the existing parity test + bridge tests.

---

## 7. P5/P6 — Extract a shared crossfade helper + a `TranscriptSwapCoordinator` (last, behind green reentry tests)

**Current mechanism (FACT).** Two parallel crossfade state machines of the same
"park + flush-on-next-swap + guarded-completion + 0.18s" shape:
- router cross-kind: `fadingOutChild`/`commitChildTransition`/`finishFadeOut`
  (`…/App/AppKit/DetailRouterViewController.swift:96-104,336-361`).
- chat same-session transcript: `fadingOutTranscript`/`crossfadeTranscriptSwap`/
  `finishTranscriptFadeOut` (`…/App/AppKit/ChatSessionViewController.swift:113-122,476-506`).
Plus `ChatSessionViewController` mixes "what to show" with the ~225-line
transcript-swap state machine (`attachSession` + crossfade,
`…/App/AppKit/ChatSessionViewController.swift:281-506`).

**Target mechanism.**
- **P6:** a shared `Crossfade` helper (park outgoing, flush-on-next, guarded
  completion, shared `0.18s` constant) that **both** machines call.
- **P5:** extract `TranscriptSwapCoordinator` owning the
  build-in-front→settle→bind→`scrollToTail`→drop-outgoing choreography, leaving
  `ChatSessionViewController` as "what to show" + host wiring.

**Why cleaner.** One crossfade definition (a regression fix propagates); the chat
VC stops carrying the transcript-swap state machine.

**Invariants (FACT, the hard ones — `analysis-component-tree.md P5/P6`,
`Content/Chat/CLAUDE.md`, transcript §2.19):** the shared crossfade must preserve
the transcript variant's **load-bearing `removeObserver` flush ordering**
(chat-I5: outgoing-flush-before-bind); the §2.19 **single-width attach contract**
(chat-I2 — build unbound shell, `layoutSubtreeIfNeeded`, bind, `scrollToTail`'s
internal layout fires the only tile at final width); the disabled-CATransaction
scoping (I3); build-in-front ordering (I4); `prepareForRemoval` teardown (I14).

**Parity.** This is the **highest-risk** area. Do it **last**, only with
`TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests` green
before and after (`Content/Chat/CLAUDE.md` data-flow note pins both). If a clean
abstraction seems to require weakening the observer-flush order or the single-width
contract — **STOP and keep the two implementations**; the duplication is cheaper
than the risk. (Per the brief's "design around it" rule.)

---

## 8. P8 — Extract self-contained projections from `SessionRuntime` (only the safe ones)

**Current mechanism (FACT).** ~3000-line god-object across 9 files, 23 `@Observable`
fields + 7 sinks (`…/Services/Session/Session/SessionRuntime.swift:18-545` + 8 exts).
Tasks/todos/context-usage/streaming are self-contained projections with their own
scratch state.

**Target mechanism.** Extract `TodoTracker` / `TaskTracker` / `TurnUsageMeter` /
`ContextUsageCache` as value or sub-objects the runtime *composes* — **only** these
four, which are genuinely self-contained projections.

**Why cleaner.** Each becomes independently testable; the runtime's core
(`messages`/`status`/`isRunning`/config) shrinks.

**Invariants (FACT, `analysis-component-tree.md P8`):** the synchronous
`onMessagesChange` fire contract (runtime-I1) and `receive` side-effect ordering
(runtime-I3) must be preserved **exactly** — the projections update *inside* the
same synchronous `receive` call stack, not via async hops. The `Session` forwarders
keep reading them the same way.

**Parity.** Behavior-preserving composition; the runtime's public surface is
unchanged so all `SessionRuntime*Tests` pass. Don't over-reach: the CLI lifecycle /
streaming / permission queue stay on the runtime (not self-contained enough).

**Rejected.** A full split of streaming/typewriter — too entangled with `receive`
ordering; not worth the risk.

---

## 9. Items deliberately left mostly alone (don't-over-engineer)

- **P9 — `Session` wide forwarding façade (~40 forwarders).** Mechanical
  boilerplate, **not** tangled flow. A "shared phase protocol" would fabricate
  runtime-only fields on the draft (draft/runtime read-surfaces genuinely diverge,
  `analysis-component-tree.md P9`). **Leave the phase dispatch.** At most group the
  read forwarders. Flagged so a refactor doesn't gold-plate it.
- **P11 — ownership-pattern inconsistency.** Judgment call. The two `UserDefaults`
  wrapper singletons (`EffortDefaultStore`, `NewSessionDefaultsStore`) are low-harm
  — leave them. `ModelStore.shared` (mutable observable catalog that spawns a CLI
  subprocess) is the one worth reconsidering, but only if it falls out of another
  change; not a standalone refactor. **Reconcile the root-CLAUDE doc** that claims
  `AppState` is injected via `.environment()` (it never is — `analysis-component-tree.md §3`).
- **P12/P13/P15 — names / dead code / layering nits.** Safe, low-value cleanups:
  rename `composeOrBarHost` → `barHost` (no longer morphs,
  `…/App/AppKit/ChatSessionViewController.swift:94`); delete vestigial
  directory-completion machinery (`…/Content/Chat/Completion/*`,
  `analysis-component-tree.md P13`); fix the `RootView2` doc references. Do these
  opportunistically when touching a file, not as a dedicated pass.

---

## 10. Sequencing (lowest-risk → highest-value, per `analysis-component-tree.md §6`)

1. **§0 permission-card overlay** (priority; self-contained; pinned by wiring +
   snapshot + routing tests).
2. **P1 → P10b → P2** (mechanical DI cleanup; do the rename inside the struct
   migration).
3. **P4** (one-line forwarder + one test).
4. **P13 deletions** (dead code).
5. **P3** (sidebar split; guarded by new tree-model tests).
6. **P7** (grouping dedupe; guarded by parity test).
7. **P8** (runtime projections; guarded by runtime tests).
8. **P5/P6** (transcript-swap + crossfade) — **last**, behind green
   reentry-layout tests; STOP rather than weaken §2.19 / observer-flush.

---

## 11. Global parity guarantee

Every fix above is either (a) a pure move/rename/deletion of unread code, (b) a
behavior-preserving extraction guarded by an existing or newly-added test, or (c)
the priority overlay, which reuses `PermissionCardView` + its 14 bodies + the 4
decision closures **verbatim** and only relocates their host. No fix weakens the
transcript §2 perf contract, the §2.19 single-width attach contract, the
synchronous single-observer selection spine, the synchronous `onMessagesChange`
fire contract, the `[]`-vs-`[.intrinsicContentSize]` host-sizing rule, or any
runloop-tick ordering invariant. Where a clean design appeared to require touching
one of those (dynamic transcript inset for the card; collapsing the two crossfades
at the cost of the observer-flush order), the design **stops and routes around it**,
as flagged in §0.8 and §7.
