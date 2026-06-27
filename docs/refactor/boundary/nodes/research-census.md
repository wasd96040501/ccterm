# Codebase census: every AppKit↔SwiftUI boundary in CCTerm

Scope: every place AppKit hosts SwiftUI (`NSHostingController` / `NSHostingView`) under
`macos/ccterm`, plus the Bindings/`@Bindable`/`.environment(...)` that cross the boundary.
Paths are relative to `macos/ccterm/` unless absolute. `FACT` = read directly in code/docs.
`INFERENCE` = my judgment from the code + the architecture docs.

This is the **node census** for the larger boundary-taxonomy effort. The taxonomy itself,
the canonical patterns, and the merge-gate tests are built from this table.

---

## 0. Regime vocabulary (from CLAUDE.md)

The root `CLAUDE.md` § "Embedding SwiftUI in AppKit: host sizing" defines two host-sizing
regimes, and the decision rule. (FACT — `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/CLAUDE.md`.)

- **Fill-a-pane host → `sizingOptions = []`.** The hosted view *is* its container's content,
  pinned edge-to-edge; the container drives size. Default options publish `view.fittingSize`
  as an intrinsic size, which leaks up through the split's `view.fittingSize` into the
  window's constraint solver and **resizes / collapses the window**. `[]` severs that path.
- **Subordinate component → `sizingOptions = [.intrinsicContentSize]`.** The hosted view is a
  small piece whose container is sized by something else (toolbar slot; bottom-anchored bar
  over a transcript). You *want* the content to size itself; pin only position.

Rule of thumb (FACT, root CLAUDE.md): *does the host fill its container (→ `[]`, container
drives size) or sit inside it as a component (→ `[.intrinsicContentSize]`, content drives
size)?*

I extend this with two more regimes observed in the actual census (INFERENCE — they are not
named in CLAUDE.md but every site falls into one of these four buckets):

- **Window-content host** — the hosted view is an `NSWindow.contentViewController`. Default
  `sizingOptions` is *correct* here (the window snaps to the content's fitting size). Used by
  Settings / About / the transcript sheets.
- **Modal-sheet host** — same as window-content but presented via `window.beginSheet`.

---

## 1. The complete census table

Every `NSHostingController` / `NSHostingView` *construction* site under `macos/ccterm`.
Demo VCs are `#if DEBUG` only (so they ship in Debug, never Release) but are exercised by the
router's `makeDemoChild` and by snapshot tests, so they're in scope.

| # | Host file:line | Host kind | Hosted SwiftUI view | `sizingOptions` | Constraint pattern | Regime | Two-way Binding across boundary? |
|---|---|---|---|---|---|---|---|
| 1 | `Content/Archive/ArchiveViewController.swift:83` | `NSHostingController<AnyView>` | `ArchiveView` | `[]` (`:102`) | pin 4 edges (`:106-111`) | fill-pane | **YES** — `folderBinding: Binding<String?>` ↔ `model.archiveSelectedFolderPath` (`:63-66`) |
| 2 | `Content/Chat/ComposeSessionViewController.swift:108` | `NSHostingController<AnyView>` | `ComposeSessionView` | `[]` (`:115`) | pin 4 edges (`:119-124`) | fill-pane | **YES** (nested, inside the SwiftUI tree) — `ComposeBindings` folder/useWorktree/sourceBranch ↔ `session.draft` (`:210-229`) |
| 3 | `Content/Chat/DraftSessionLandingViewController.swift:131` | `NSHostingController<AnyView>` | `DraftSessionLandingView` | `[]` (`:136`) | pin 4 edges (`:140-145`) | fill-pane | No (id passed as value `:104`, callbacks only) |
| 4 | `App/AppKit/DetailRouterViewController.swift:437` (DEBUG) | `NSHostingController<AnyView>` | `PermissionCardsDemoView` | `[]` (`:443`) | router pins to detail slot | fill-pane | No (environment only) |
| 5 | `App/AppKit/ChatSessionViewController.swift:161` | `NSHostingView<AnyView>` | `ChatComposeStack` (→ `ChatRestingBar`) | `[.intrinsicContentSize]` (`:169`) | centerX + width≤cap(req) + width==cap(@high) + leading≥inset + bottom (`:191-208`) | **component (bottom-anchored, centered)** | **YES** — `@Bindable model: MainSelectionModel` (`:606`) |
| 6 | `App/AppKit/MainWindowController.swift:242` | `NSHostingView<TranscriptProjectChip>` | `TranscriptProjectChip` (toolbar) | `[.intrinsicContentSize]` (`:253`) | toolbar auto-measures via intrinsic; no minSize/maxSize | component (toolbar slot) | **YES** — `@Bindable model` (`:338`), read-mostly |
| 7 | `App/AppKit/MainWindowController.swift:269` | `NSHostingView<ArchiveFilterToolbarButton>` | `ArchiveFilterToolbarButton` (toolbar) | `[.intrinsicContentSize]` (`:280`) | toolbar auto-measures via intrinsic | component (toolbar slot) | **YES** — `@Bindable model` (`:300`), writes `archiveSelectedFolderPath` (`:321`) |
| 8 | `App/AppKit/SettingsWindowController.swift:15` | `NSHostingController<SettingsView>` | `SettingsView` | default (unset) | `NSWindow(contentViewController:)` | window-content | No |
| 9 | `App/AppKit/AboutWindowController.swift:23` | `NSHostingController<AboutView>` | `AboutView` | default (unset) | `NSWindow(contentViewController:)` + `.contentSize` style (no `.resizable`) | window-content | No |
| 10 | `Content/Chat/NativeTranscript2/AppKit/Transcript2SheetPresenter.swift:192` | `NSHostingController<Content>` | `UserBubbleSheetView` / `ImagePreviewSheetView` | default (unset) | `NSWindow(contentViewController:)` → `beginSheet` | modal-sheet | No (value + Done callback) |
| 11 | `Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:133` (DEBUG) | `NSHostingView<AnyView>` | input bar (`ChatComposeStack`-style) | `[]` (`:134`) | leading+trailing+bottom + **height constraint driven by a `PreferenceKey`** (`:137-144`) | component (bottom-anchored, full-width) | via env (`seed.manager`) |
| 12 | `Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:162` (DEBUG) | `NSHostingView<ControlPanelHostView>` | `ControlPanelHostView` | default (unset) | trailing+bottom only (`:165-168`) | component (floating corner) | **YES** — `@Bindable state: ControlPanelState` (`:323`) |
| 13 | `Content/TranscriptDemo/TranscriptDemoViewController.swift:109` (DEBUG) | `NSHostingView<TranscriptDemoControlPanel>` | `TranscriptDemoControlPanel` | default (unset) | centerX + bottom (`:112-115`) | component (floating bottom) | **YES** — `@Bindable controller: Transcript2Controller` (`:164`) |
| 14 | `Content/TranscriptDemo/TranscriptPerfDemoViewController.swift:85` (DEBUG) | `NSHostingView<TranscriptPerfStatusBar>` | `TranscriptPerfStatusBar` | default (unset) | centerX + bottom (`:88-91`) | component (floating bottom) | **YES** — `@Bindable controller` (`:326`) |
| 15 | `Content/TranscriptDemo/TranscriptStressViewController.swift:79` (DEBUG) | `NSHostingView<TranscriptStressStatusBar>` | `TranscriptStressStatusBar` | default (unset) | centerX + bottom (`:82-85`) | component (floating bottom) | **YES** — `@Bindable model` (`:166`) |
| 16 | `Content/TranscriptDemo/TranscriptStressViewController.swift:91` (DEBUG) | `NSHostingView<TranscriptStressPlaceholder>` | `TranscriptStressPlaceholder` | default (unset) | centerX + centerY (`:94-97`), positioned below status bar | component (centered) | **YES** — `@Bindable model` (`:193`) |

Notes on the table:

- "default (unset)" means `sizingOptions` is never assigned. For `NSHostingController` that
  publishes the body's `fittingSize` as intrinsic; for `NSHostingView` likewise. For the
  window-content hosts (#8/#9/#10) that is the *intended* behavior. For the DEBUG floating
  component hosts (#12–#16) it is benign because none of them fill a pane or feed a split's
  `fittingSize` — they're positioned (corner / bottom-center / center) and the VC's own root
  view is sized by the router/window, not by these children. (INFERENCE — confirmed by reading
  each constraint block: none pins all 4 edges, so the host's intrinsic size never governs the
  container.)
- `ChatSessionViewController.composeOrBarHost` is typed `NSHostingView<AnyView>` (`:94`); its
  body switches on the selection between `ChatRestingBar` and `EmptyView` via `ChatComposeStack`.

---

## 2. The headline reproduction — archive window-collapse

### 2.1 The mechanism, verified against real code (FACT)

`ArchiveViewController.viewDidLoad` builds `host = NSHostingController(rootView: root)` at
`Content/Archive/ArchiveViewController.swift:83`, then sets `host.sizingOptions = []` at
`:102`, then pins all four edges at `:106-111`.

The authoritative explanation is in the code comment at
`Content/Archive/ArchiveViewController.swift:84-101` (FACT, verbatim summary):

- `NSHostingController`'s **default** `sizingOptions` binds the SwiftUI body's fitting size
  into the hosting view's layout, so `host.view.fittingSize` tracks the content's ideal size.
- That's right for a standalone window's `contentViewController` (Settings / About / Logs size
  to their content — matches census #8/#9), **but this host is a fill-the-pane detail child**.
- `ArchiveView`'s root is a `ScrollView` whose fitting height is just the header (**~176pt**
  before the async list lands).
- With the default options that small fitting height bubbles up through the detail VC →
  `NSSplitViewController.view.fittingSize`, and the window resizes its content down to it — **the
  whole window collapses to ~176pt the instant Archive is selected** (and stays collapsed when
  you switch back, since chat contributes no fitting height to grow it again).
- Confirmed offscreen (per the comment): with the default, `host.view.fittingSize ≈ 545×276`;
  cleared (`[]`), it's `0×0` and the split fills the window.

So the documented `~545×276` leak is real and the comment names the exact number to assert
against. (FACT — `:97`.)

### 2.2 True mechanism: sizingOptions regime, NOT the two-way Binding (INFERENCE, high confidence)

The user flagged "two-way binding caused the window to be squashed" for the archive page. The
two-way Binding exists and crosses the boundary:

```
Content/Archive/ArchiveViewController.swift:63-66
let folderBinding = Binding<String?>(
    get: { [weak self] in self?.model.archiveSelectedFolderPath },
    set: { [weak self] in self?.model.archiveSelectedFolderPath = $0 }
)
```
passed as `ArchiveView(selectedFolderPath: folderBinding, …)` (`:69`).

But the collapse mechanism is the **sizingOptions regime**, not the Binding per se. Evidence:

1. The fix that the code actually applies is `host.sizingOptions = []` (`:102`), and the comment
   ties the collapse precisely to `host.view.fittingSize` leaking through the split (`:91-98`).
   The Binding is untouched by the fix.
2. The *same* collapse is documented and fixed identically at three other fill-pane sites that
   have **no** boundary-crossing Binding: `ComposeSessionViewController` (`:108-115`, comment
   `:109-114`), `DraftSessionLandingViewController` (`:131-136`, comment `:132-135`), and the
   DEBUG `PermissionCardsDemoView` host (`DetailRouterViewController.swift:437-443`, comment
   `:438-442`). If the Binding were the cause, those three (Binding-free) would not need `[]`.
3. The off-screen number quoted (`545×276`) is a *static* fitting size of the SwiftUI body, not
   a value produced by a Binding write.

**How the Binding makes it WORSE / explains the user's mental model (INFERENCE):** the two-way
Binding is the *re-trigger* that keeps republishing the bad fitting size. With default
`sizingOptions`, every time the folder filter changes — either from the toolbar button
(`ArchiveFilterToolbarButton`, census #7, writes `model.archiveSelectedFolderPath` at
`MainWindowController.swift:321`) or from inside `ArchiveView` — the Binding write mutates
`model.archiveSelectedFolderPath`, `ArchiveView`'s body re-evaluates (filtered list changes),
the `ScrollView`'s fitting height recomputes, and `NSHostingController` republishes
`view.fittingSize` into the split. So the Binding turns a one-shot collapse into a *recurring*
squash every time you touch the filter. The root cause is still the regime; the Binding is the
pump. Clearing `sizingOptions` makes the host stop publishing fitting size entirely, so the
Binding can fire freely without ever touching the window frame. (INFERENCE — this is the
runloop consequence of the documented mechanism + the observed write site; I did not find a
comment that states the Binding-as-pump relationship explicitly, so the taxonomy doc should
verify it with the large-window test below.)

### 2.3 Why the test window MUST be large (FACT + INFERENCE)

A test that mounts the archive host in a *small or flat* window cannot detect this: the
collapsed size (`~545×276`) is approximately the small window's own size, so "collapsed" and
"healthy" are indistinguishable. The probe must mount through the **real**
`DetailRouterViewController` swap path into a window **≥ 1100×760** so that a collapse to
`~545×276` (or `~176pt` tall) is unambiguous — the post-collapse height is < 40% of the test
window height. The window sizing is itself part of the evidence and must be called out in the
test. (INFERENCE for the threshold; FACT that `DetailRouterLayoutDiagnosticsTests` already
exists as "the REAL `DetailRouterViewController` swap path" harness for exactly the PR #224
"Selecting Archive flattens the window (height collapses)" regression —
`cctermTests/DetailRouterLayoutDiagnosticsTests.swift:8-17`.)

The taxonomy's archive merge-gate test should:
- mount via `DetailRouterViewController` (not a hand-rolled `ArchiveViewController` in isolation),
- use a window ≥ 1100×760,
- assert the window/split content height stays ≈ the window height after selecting `.archive`
  (NOT shrunk to `~276`),
- and as an A/B, assert that an `ArchiveViewController` whose host keeps **default**
  `sizingOptions` publishes `host.view.fittingSize.height ≈ 276` (proving the probe can see the
  bad regime) — without weakening production code (build a throwaway host inline in the test).

---

## 3. The second case — centering the in-page hosted input bar (census #5)

### 3.1 What production does (FACT)

`ChatSessionViewController.loadView` (`App/AppKit/ChatSessionViewController.swift:161-208`):

- `composeOrBarHost = NSHostingView(rootView: AnyView(makeComposeOrBarStack()))` (`:161`).
- `composeOrBarHost.sizingOptions = [.intrinsicContentSize]` (`:169`) — height owned by the
  content, so the host is only as tall as the bar (multi-line input / permission card grows
  it). This also keeps hit-testing scoped to just the bar, so the transcript table below
  receives clicks everywhere above it (`:163-168`).
- Width owned by AppKit via four constraints (`:191-208`):
  - `centerXAnchor == view.centerXAnchor` (`:202`) — horizontally centered.
  - `widthAnchor <= maxHostWidth` **required** (`:204`) — caps at the widest content it hosts.
  - `widthAnchor == maxHostWidth` **@.defaultHigh** (`:183-185`, activated `:207`) — fills up to
    the cap on a wide pane.
  - `leadingAnchor >= view.leadingAnchor` (`:205`) — yields on a pane narrower than the cap so
    the bar shrinks to fit instead of overflowing.
  - `bottomAnchor == view.bottomAnchor` (`:203`) — bottom-anchored.
- `maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset` (`:182`); the
  narrower input pill (`composeMaxWidth = 512`, `:60`) self-centers inside via its own frame
  (`:177`). `detailHorizontalInset = 20` (`:62`).

The hosted SwiftUI side (`ChatComposeStack.body`, `:641-674`) fills the width the host hands
it and leaves height to intrinsic (`:670-674`).

### 3.2 Is this best practice? (INFERENCE)

This is the **canonical "centered, width-capped, bottom-anchored component"** pattern, and it
is the right one for an in-page (non-pane-filling) hosted SwiftUI component. The four-constraint
recipe — `centerX` + `width<=cap (required)` + `width==cap (@high)` + `leading>=inset` +
edge-anchor — is the idiomatic Auto Layout way to express "center, cap at a max width, but
shrink to fit a narrow container." Combined with `[.intrinsicContentSize]` for the cross-axis
(height), it exactly matches the root CLAUDE.md "subordinate component" regime and the explicit
warning **not** to hand-roll height with `GeometryReader` + `PreferenceKey` + a manual height
constraint.

Notably, the DEBUG `PermissionSessionDemoViewController` input-bar host (census #11) does NOT
follow this: it uses `sizingOptions = []` plus a `DemoBarHeightKey` `PreferenceKey` →
`onPreferenceChange` → height constraint (`:121-144`) — i.e. exactly the hand-rolled height
workaround CLAUDE.md says `.intrinsicContentSize` replaces "for free." Its comment even claims
it bottom-anchors "exactly as `ChatSessionViewController` does" (`:115-116`), but it does not —
it's full-width (`leading`/`trailing` pinned, `:140-141`), not centered + width-capped, and it
drives height manually. (INFERENCE: this demo VC is the legacy shape; the production
`ChatSessionViewController` is the canonical pattern. The taxonomy should treat #5 as the
exemplar and flag #11 as a divergence to either document-as-demo-only or migrate.)

### 3.3 The Binding crossing on #5

`ChatComposeStack` takes `@Bindable var model: MainSelectionModel` (`:606`). The bar reads
`model.selection` / `model.draftSessionId` to route content (`:642`, `:628-639`) and the AppKit
VC drives selection flips imperatively from outside SwiftUI. This is a read-mostly `@Bindable`
crossing, not a hot two-way write loop like archive's folder filter — so it does not interact
with host sizing the way archive's does (and the height is intrinsic, not pane-filling, so even
if it did, there's no split-`fittingSize` leak). (INFERENCE.)

---

## 4. Two-way Bindings / `@Bindable` crossing the boundary (full list)

`@Bindable model: MainSelectionModel` appears at 3 production sites — all reading shared
selection state, all on `MainSelectionModel`:
- `App/AppKit/MainWindowController.swift:300` (`ArchiveFilterToolbarButton`, **writes**
  `archiveSelectedFolderPath` `:321`)
- `App/AppKit/MainWindowController.swift:338` (`TranscriptProjectChip`, read-only)
- `App/AppKit/ChatSessionViewController.swift:606` (`ChatComposeStack`, read-mostly)

Explicit `Binding(get:set:)` constructed in an AppKit host and handed into SwiftUI:
- `Content/Archive/ArchiveViewController.swift:63` — `Binding<String?>` ↔
  `model.archiveSelectedFolderPath` (census #1; the headline two-way Binding).
- `Content/Chat/ComposeSessionViewController.swift:212/220/224` — three Bindings ↔
  `session.draft.config` (`folder`/`useWorktree`/`sourceBranch`). Note the comment: "There is
  no parallel storage on the selection model — the draft itself is the single source of truth"
  (`:205-209`), so these write straight to the model, no sync hop. (FACT.)

Bindings that stay *inside* the SwiftUI tree (do NOT cross an AppKit host boundary — for
completeness, not boundary nodes): `NewSessionConfigurator.swift:102-104,332-333`,
`InputBarControls/ModelEffortPicker.swift:315`, `InputBarControls/BackgroundTaskButton.swift:68`,
`ArchiveView.swift:80`. (FACT — these are SwiftUI-to-SwiftUI.)

DEBUG `@Bindable` crossings (controller/state into a demo control panel): census #12–#16
(`ControlPanelState`, `Transcript2Controller`, `TranscriptStressStatusModel`). These are
benign — the hosts are floating components, not pane-fillers.

`.environment(...)` injection crossing the boundary happens at every production host (#1, #2,
#3, #4-DEBUG, #5) with the same six-item set: `sessionManager`, `recentProjects`,
`inputDraftStore`, `\.syntaxEngine`, `searchBus`, `notifications`
(e.g. `ChatSessionViewController.swift:576-581`, `ArchiveViewController.swift:75-80`). (FACT.)

---

## 5. The four hosts that share the fill-pane `[]` regime + collapse fix

These four are the canonical "fill-pane → `[]` + pin 4 edges" exemplars. All four carry the
same documented rationale referencing `ArchiveViewController`:

| Site | `[]` set at | 4-edge pin | Comment cross-refs |
|---|---|---|---|
| `ArchiveViewController.swift` | `:102` | `:106-111` | the canonical write-up (`:84-101`) |
| `ComposeSessionViewController.swift` | `:115` | `:119-124` | "See `ArchiveViewController`…" (`:109-114`) |
| `DraftSessionLandingViewController.swift` | `:136` | `:140-145` | "see `ComposeSessionViewController` / `ArchiveViewController`" (`:132-135`) |
| `DetailRouterViewController.swift` (DEBUG `PermissionCardsDemoView`) | `:443` | router pins | "see `ArchiveViewController` for the full rationale" (`:438-442`) |

These are mounted as the detail-pane child by `DetailRouterViewController.makeChild` (`:375` compose,
`:386` draftLanding, `:395` archive, `:413-446` demo). (FACT.)

---

## 6. Window-content & modal-sheet hosts (default sizingOptions is correct)

- `SettingsWindowController.swift:15` — `NSHostingController(rootView: SettingsView())` as
  `NSWindow.contentViewController`; needs an `NSToolbar` carrying `.sidebarTrackingSeparator`
  for the `NavigationSplitView` sidebar to render source-list style (`:17-28`, `:48-55`). AppKit
  owns the window lifecycle to dodge SwiftUI `Settings{}`-scene cold-start resurrection
  (`:4-11`). (FACT.)
- `AboutWindowController.swift:23` — `NSHostingController(rootView: AboutView())` as content VC;
  `.contentSize`-style window (no `.resizable`) so it snaps to `AboutView`'s intrinsic size
  (`:25-33`). The default `sizingOptions` (publish fitting size) is exactly what makes the
  window snap to content — the *opposite* requirement from the fill-pane hosts. (FACT.)
- `Transcript2SheetPresenter.swift:192` — `NSHostingController(rootView:)` →
  `NSWindow(contentViewController:)` → `parent.window?.beginSheet(...)` for
  `UserBubbleSheetView` / `ImagePreviewSheetView`. The `@Observable`
  `Transcript2Controller.pendingUserBubbleSheet` / `pendingImagePreview` writes are observed via
  `withObservationTracking` and turned into AppKit-native sheets, replacing the deleted SwiftUI
  `.sheet(item:)` bindings (FACT — `Content/Chat/CLAUDE.md:14`, NativeTranscript2 CLAUDE.md
  §5 userBubble). The sheet body is SwiftUI; presentation is pure AppKit so the transcript host
  VC stays AppKit-rooted.

---

## 7. Existing tests that already touch these boundaries (reuse, don't re-derive)

Measurement probes / routing tests already in `cctermTests/` (FACT — directory listing):
- `DetailRouterLayoutDiagnosticsTests.swift` — REAL router swap path; explicitly the PR #224
  "Selecting Archive flattens the window" + "blank transcript" reproduction harness (`:8-17`).
  **This is the harness the archive large-window collapse gate should extend.**
- `DetailRouterContainmentTests.swift`, `DetailRouterDraftRoutingTests.swift`,
  `NotificationActivationRoutingTests.swift` — router child-VC lifecycle / routing.
- `ChatComposeStackRoutingTests.swift` — the pure `ChatComposeStack.content(for:draftSessionId:)`
  routing function (census #5's content selector, `:628`).
- `TranscriptReentryLayoutCacheTests.swift` / `TranscriptHostReentryLayoutCacheTests.swift` —
  attach-tick single-width contract (transcript host, not the boundary per se but same offscreen
  scaffold).
- `MainWindowAppKitSnapshotTests.swift`, `ArchiveViewSnapshotTests.swift` — `*SnapshotTests` =
  CI-skipped, opt-in PNG review only. The collapse gate must NOT be a `*SnapshotTests` file.

Helpers to reuse (FACT — `cctermTests/Helpers/`): `ViewSnapshot.swift` (render/writePNG),
`MountedTranscript.swift` (mount + geometry sampling), `TranscriptOnlyHostViewController.swift`,
`Message2Fixtures.swift`, `MessagesChangeRecorder.swift`, `FakeReversePageSource.swift`,
`TempJSONLFile.swift`.

---

## 8. Production-code seams available to the taxonomy tests (FACT — CLAUDE.md rules)

Allowed: add a secondary init (e.g. `init(controller:)`), widen `fileprivate`→`internal` on a
constant (access modifier only, no behavior change). The `~545×276` / `~176pt` magic numbers
live in a comment, not a `let`, so the test should hardcode its own threshold rather than reach
for a production constant. `BlockStyle.maxLayoutWidth`, `Self.detailHorizontalInset` (`:62`,
`internal`), `Self.composeMaxWidth` (`:60`) are reusable for the centering gate.

Forbidden: `#if DEBUG` UI variants, env-gated layout, `forceXxxForTest()`, exposing mutable
internals. To exhibit the *bad* (default-sizingOptions) regime for the A/B assertion, build a
throwaway `NSHostingController` inline in the test with default options — never mutate
production `ArchiveViewController` to expose the bad path.

---

## 9. Summary counts (FACT)

- **16** hosting construction sites total: **9 production** (#1, #2, #3, #5, #6, #7, #8, #9,
  #10) and **7 DEBUG-only** (#4, #11, #12, #13, #14, #15, #16).
- Regime breakdown: **fill-pane `[]`** = 4 (#1,#2,#3,#4); **component `[.intrinsicContentSize]`**
  = 3 (#5,#6,#7); **window-content / modal-sheet, default options** = 3 (#8,#9,#10); **DEBUG
  floating components, default options** = 5 (#12–#16); **DEBUG hand-rolled-height component** =
  1 (#11).
- Two-way / writable Bindings crossing the boundary in production: archive folder filter (#1,
  and its toolbar twin #7), compose draft config (#2). Read-mostly `@Bindable`: #5, #6.
- The archive collapse root cause is the **fill-pane sizingOptions regime** (`[]` is the fix);
  the two-way Binding is the *re-trigger* that republishes the bad fitting size on every filter
  change, which is why the user perceived it as "the two-way binding squashed the window."
