# Survey: Permission cards + their composition over the input bar

Scope: the permission-card view family, its per-kind body renderers, and
— the key pain point — how `ChatRestingBar` layers the card over the input
bar and how `ChatSessionViewController` hosts that bar. Read-only
investigation; every claim is cited file:line. FACT = in the code,
INFERENCE = my read.

All paths are relative to the worktree root
`/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f`.
Source root abbreviated as `…` = `macos/ccterm`.

---

## 0. Executive summary — claim vs. reality (the "喧宾夺主" effect)

The user reports the permission card feels like a **Y-axis replacement**
(the input bar drops / the card shoves it) rather than a **Z-axis overlay
that fades in IN PLACE**. The code comment in `InputBarChrome.swift:84-101`
insists it is a z-axis `ZStack` overlay. **Both are true at once — that is
the source of the confusion.** Reconciled:

- **The card IS drawn on the z-axis over the bar.** `ChatRestingBar`'s
  `ZStack(alignment: .bottom)` (`…/Content/Chat/InputBarChrome.swift:126`)
  puts `InputBarChrome` first (bottom layer) and the card second (top
  layer). The card's bottom edge is flush with the chrome row, it covers
  the bar, and the bar itself does **not** move down within the stack —
  the bottom alignment pins it. So far the comment is accurate. (FACT)

- **BUT the host that contains the stack grows UPWARD when the card
  appears, and that growth is animated.** The bar host
  (`composeOrBarHost`, `…/App/AppKit/ChatSessionViewController.swift:94`)
  is **bottom-anchored** (`composeOrBarHost.bottomAnchor == view.bottomAnchor`,
  `…/ChatSessionViewController.swift:203`) with **no height constraint** and
  `sizingOptions = [.intrinsicContentSize]` (`…/ChatSessionViewController.swift:169`).
  Its height is published by the SwiftUI body's `fittingSize.height`. A
  `ZStack` reports the **union** of its children's sizes, so when
  `pendingPermissions` goes empty→non-empty the stack's intrinsic height
  jumps from "bar height" to "card-height + bar overlap," AppKit re-reads
  the host's intrinsic height, and because the host is pinned at the
  bottom its **top edge rises**. (FACT — mechanism confirmed by the demo
  VC's explicit equivalent at `…/Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:105-146`,
  and by the PR #235 / #248 commit messages.)

- **What moves, precisely:** the host's top edge. What does **not** move:
  the transcript scroll view's frame or its content inset. The transcript
  is full-bleed (pinned to all four edges of `view`,
  `…/ChatSessionViewController.swift:354-359`) with a **fixed**
  `contentInsets = NSEdgeInsets(top: 56, …, bottom: 112, …)`
  (`…/Content/Chat/NativeTranscript2/AppKit/TranscriptScrollViewFactory.swift:40,66`).
  So the user's stated sub-hypothesis "the transcript bottom inset jumps"
  is **FALSE** — the transcript's geometry is static; only the bar host
  resizes over the (static) transcript. (FACT)

- **The animation is the overbearing part.**
  `ChatRestingBar.body` ends with
  `.animation(.smooth(duration: 0.25), value: session.pendingPermissions.first?.id)`
  (`…/InputBarChrome.swift:166`). This animation is attached to the
  **whole body**, so it animates **both** the card's own `.transition`
  (`.scale(0.96, anchor: .bottom).combined(with: .opacity)`,
  `…/InputBarChrome.swift:159-161`) **and** the host's intrinsic-height
  change that the union-growth produces. The bar pill itself is bottom
  pinned so it does not translate, but the *visible band that the host
  occupies* expands upward over 0.25s, and the chrome row + pill get
  briefly covered by the rising card. (FACT for what is animated;
  INFERENCE that the simultaneous "host grows up under a smooth
  animation" is what reads as "shove / replacement" rather than "fade in
  place.")

**Root cause (INFERENCE, well-supported):** the card's footprint is
load-bearing for the host's size by design (PR #235 chose `ZStack` over
`.overlay` *specifically so* the host would grow to clip + hit-test the
card — see `…/InputBarChrome.swift:94-101`). That is correct for
hit-testing, but it couples "card visible" to "host geometry change," and
the single body-level `.animation(.smooth)` then animates that geometry
change. A true "fades in floating, nothing else moves" composition needs
the card to be presented in a surface whose size is **decoupled** from the
card's visibility — i.e. the host must already be tall enough to contain
the card *before* the card fades in, OR the card must be hosted in a
separate always-tall layer that doesn't grow the bar host. (See §6 for
what a clean composition requires.)

---

## 1. Component / type inventory

### 1a. The composition layer (the pain point)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `ChatRestingBar` | SwiftUI `View` | Chat-mode resting input region. `ZStack(alignment: .bottom)` layering `InputBarChrome` (bottom) + `PermissionCardView` (top). Resolves `Session`, wires the card's 4 decision callbacks to `session.respond`, owns the `.animation(.smooth)` on `pendingPermissions.first?.id`. | `…/Content/Chat/InputBarChrome.swift:111-168` |
| `InputBarChrome` | SwiftUI `View` | Per-session wrapper: `VStack` of `InputBarView2` (pill) + `InputBarSessionChrome` (mode/model/effort/context row). Resolves `Session` via `manager.prepareDraftSession`. Owns the completion-prewarm `.task(id:)`. | `…/Content/Chat/InputBarChrome.swift:12-82` |
| `ChatComposeStack` | SwiftUI `View` | The thing the AppKit host actually renders. `@Bindable var model: MainSelectionModel`; routes `selection` → `.none` (EmptyView) or `.chat(sid)` (`ChatRestingBar` with `.id(sid)`). Pure static routing fn `content(for:draftSessionId:)`. | `…/App/AppKit/ChatSessionViewController.swift:605-679` |
| `ChatSessionViewController` | `NSViewController` (AppKit) | Mounts the transcript scroll view + three full-bleed overlays incl. `composeOrBarHost`. Bottom-anchors the bar host at `.intrinsicContentSize`. Drives session attach imperatively. | `…/App/AppKit/ChatSessionViewController.swift:46-592` |
| `composeOrBarHost` | `NSHostingView<AnyView>` (AppKit↔SwiftUI boundary) | Hosts `ChatComposeStack`. `sizingOptions = [.intrinsicContentSize]`; bottom-anchored, centerX, width-capped. **No height constraint** — its height IS the SwiftUI body's intrinsic height. | `…/ChatSessionViewController.swift:94,161-170,202-207` |

### 1b. The card view family (`…/Content/Chat/InputBarControls/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `PermissionCardView` | SwiftUI `View` | The card chrome (header / per-kind body / decision-reason label / button row), `PermissionCardSurface`, `.frame(maxWidth: maxLayoutWidth)`. Pure UI: takes a `PermissionRequest` + 4 callbacks. Dispatches body by `PermissionCardKind`. | `PermissionCardView.swift:33-147` |
| `PermissionCardKind` | `enum` (model) | Categorises a `PermissionRequest` by `toolName` (Bash/sedEdit/fileEdit/fileWrite/notebookEdit/filesystemRead/webFetch/plan-mode/taskAgent/skill/askUserQuestion/mcp/unknown). | `PermissionCardKind.swift:12-73` |
| `PermissionCardCopy` | `enum` (static helpers) | Localized title (`"Claude wants to <verb>"`) + `parameter(for:)` extraction. | `PermissionCardView.swift:154-200` |
| `PermissionCardSurface` | `ViewModifier` (private) | Opaque rounded-rect + stroke + shadow (solid `controlBackgroundColor`, no translucency so the bar's material doesn't bleed through). | `PermissionCardView.swift:231-250` |
| `PermissionDecisionButton` | SwiftUI `View` | Compact 24pt button, 3 roles (primary/secondary/destructive). Shared across body renderers. | `PermissionCardView.swift:260-320` |
| `PermissionFallbackCardBody` | SwiftUI `View` (private) | Generic one-liner body for kinds w/o a dedicated renderer. | `PermissionCardView.swift:206-220` |
| `PermissionShellCardBody` | SwiftUI `View` | `.bash`/`.powerShell` body: command in a `DiffView` (new-file mode) inside `BoundedHeightScrollView(maxHeight: 240)` + description + compound hint. | `PermissionShellCardBody.swift:21-139` |
| `PermissionSedEditCardBody` | SwiftUI `View` | sed-in-place edit body. | `PermissionSedEditCardBody.swift` |
| `PermissionFileWriteCardBody` | SwiftUI `View` | `.fileEdit`/`.fileWrite` diff-preview body. | `PermissionFileWriteCardBody.swift` |
| `PermissionNotebookEditCardBody` | SwiftUI `View` | notebook-edit body. | `PermissionNotebookEditCardBody.swift` |
| `PermissionWebFetchCardBody` | SwiftUI `View` | web-fetch (url + prompt) body. | `PermissionWebFetchCardBody.swift` |
| `PermissionFilesystemReadCardBody` | SwiftUI `View` | read/glob/grep body. | `PermissionFilesystemReadCardBody.swift` |
| `PermissionTaskAgentCardBody` | SwiftUI `View` | sub-agent body. | `PermissionTaskAgentCardBody.swift` |
| `PermissionSkillCardBody` | SwiftUI `View` | skill body. | `PermissionSkillCardBody.swift` |
| `PermissionMcpCardBody` | SwiftUI `View` | mcp tool body. | `PermissionMcpCardBody.swift` |
| `PermissionEnterPlanModeCardBody` | SwiftUI `View` | enter-plan-mode body. | `PermissionEnterPlanModeCardBody.swift` |
| `PermissionExitPlanModeCardBody` | SwiftUI `View` | exit-plan-mode (plan text) body. | `PermissionExitPlanModeCardBody.swift` |
| `PermissionAskUserQuestionCardBody` | SwiftUI `View` | **Owns its full chrome** (header/questions/options/submit/cancel) — `bodyOwnsChrome` short-circuits the generic header/reason/buttons (`PermissionCardView.swift:54,58,60,73`). Largest body file (~25 KB). | `PermissionAskUserQuestionCardBody.swift` |

### 1c. The chrome-row siblings (under the bar, NOT card-related but in the same `InputBarSessionChrome` row)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `InputBarSessionChrome` | SwiftUI `View` | `HStack`: `PermissionModePicker` · `BackgroundTaskButton` · `TodoButton` · Spacer · `ModelEffortPicker` · `ContextRingButton`. Reads from `session`. | `InputBarSessionChrome.swift:13-55` |
| `PermissionModePicker` | SwiftUI `View` | Permission-mode trigger + popover. Reads `session.permissionMode`, writes `session.setPermissionMode`. `auto` row gated by `activeModel.supportsAutoMode`. Has a `seedFromDefaultsIfNeeded` `.task(id:)`. | `PermissionModePicker.swift:12-81` |
| `ModelEffortPicker` | SwiftUI `View` | Stacked Models+Effort+Fast popover. Reads `session.model/effort/fastModeEnabled`, writes `setModel/setEffort/setFastMode`. `@State store = ModelStore.shared`. Hides until catalog arrives. | `ModelEffortPicker.swift:27-…` |

> **Naming note (FACT):** `PermissionModePicker` (chrome row, sets the
> session's *permission mode*) and `PermissionCardView` (the floating
> *permission request* card) are unrelated surfaces that share the word
> "Permission." Easy to conflate in a refactor. (See §5.)

### 1d. The data source

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Session` | `@Observable @MainActor` façade | Forwards `pendingPermissions` (read-only) + `respond(to:decision:)`. | `…/Services/Session/Session/Session.swift:333-335,687-688` |
| `SessionRuntime` | `@Observable @MainActor` | Owns `internal(set) var pendingPermissions: [PendingPermission]` (`SessionRuntime.swift:243`), `enqueuePermission` (append), `respond` (calls `pending.respond`), `onPermissionPrompt` notice hook. | `…/Services/Session/Session/SessionRuntime.swift:243`; `SessionRuntime+Start.swift:777-791`; `SessionRuntime+Configuration.swift:118-124` |
| `PendingPermission` | `struct` (model) | `{ id, request: PermissionRequest, respond: (PermissionDecision)->Void }`. | `…/Services/Session/Session/SessionTypes.swift` |
| `PermissionRequest` / `PermissionDecision` | SDK types (`AgentSDK`) | The request payload + the decision the card produces (`allowOnce`/`allowAlways`/`deny`/`allowOnce(updatedInput:)`). | `AgentSDK` |

### 1e. Demo / test harness

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `PermissionSessionDemoViewController` | `NSViewController` (DEBUG) | End-to-end card-over-bar demo. **Reveals the production mechanism**: explicitly measures the bar's natural height via `GeometryReader`+`PreferenceKey` and feeds it to a height constraint (`sizingOptions = []`), which is the hand-rolled equivalent of production's `.intrinsicContentSize`. | `…/Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:11-146` |
| `DemoBarHeightKey` | `PreferenceKey` (DEBUG) | Carries the bar's measured height out to the host constraint. | same file:11-16 |
| `PermissionCardWiringTests` | XCTest | Asserts the 4 callbacks route to the right `PermissionDecision` at `Session.respond` and that the runtime pops the entry. Drives `respond` directly (no SwiftUI taps). | `macos/cctermTests/PermissionCardWiringTests.swift` |
| `PermissionCardSnapshotTests` | XCTest (snapshot, opt-in) | Renders the card alone + over-bar composition. Mirrors the ZStack manually. | `macos/cctermTests/PermissionCardSnapshotTests.swift` |
| `ChatComposeStackRoutingTests` | XCTest | Pins the `ChatComposeStack.content(for:)` routing. | `macos/cctermTests/ChatComposeStackRoutingTests.swift` |
| `PermissionCardKindTests` / `PermissionShellCardBodyTests` / `PermissionPromptNoticeTests` | XCTest | Kind mapping / shell-body derivations / prompt-notice. | `macos/cctermTests/` |

---

## 2. Component tree (this area)

Nesting + hosting. `[AppKit]` / `[SwiftUI]` marked per node; `NSHostingView`
boundaries note `sizingOptions`.

```
ChatSessionViewController.view : NSView                                 [AppKit]   (full pane; router drives its size)
│
├── transcriptScroll : Transcript2ScrollView                           [AppKit]   pinned all 4 edges of view
│     └── (NSClipView → NSTableView → BlockCellView …)                  [AppKit]   FIXED contentInsets.bottom = 112  ← does NOT track the bar
│
├── topScrim : TranscriptTopScrimView                                  [AppKit]   pinned top, height 52, hitTest passthrough
├── bottomScrim : TranscriptBottomScrimView                            [AppKit]   pinned bottom, height 100, hitTest passthrough + cutouts
│
└── composeOrBarHost : NSHostingView<AnyView>                          [AppKit↔SwiftUI boundary]
      │   sizingOptions = [.intrinsicContentSize]   ← HEIGHT flows UP from SwiftUI body
      │   constraints: centerX, bottom == view.bottom, width <= maxHostWidth (req),
      │                width == maxHostWidth @high, leading >= view.leading
      │   ⚠ NO height constraint — host height == SwiftUI fittingSize.height
      │
      └── ChatComposeStack                                             [SwiftUI]   reads model.selection
            └── (selection == .chat(sid)) ChatRestingBar .id(sid)      [SwiftUI]
                  │   .padding(.bottom, chatBottomInset=36)
                  │   .frame(maxWidth: .infinity)
                  │   .animation(.smooth(0.25), value: pendingPermissions.first?.id)   ← animates the union-height change
                  │
                  └── ZStack(alignment: .bottom)                       [SwiftUI]   ⚠ reports UNION height of children
                        │
                        ├── InputBarChrome  (bottom layer, z=0)        [SwiftUI]
                        │     │  .frame(minW: 460, maxW: composeMaxWidth=512)
                        │     │  .padding(.horizontal, detailHorizontalInset=20)
                        │     └── VStack(spacing: 10)
                        │           ├── InputBarView2 (pill, cornerRadius 16)   [SwiftUI]
                        │           └── InputBarSessionChrome (mode/model/…)    [SwiftUI]
                        │
                        └── (if pendingPermissions.first != nil)
                            PermissionCardView (top layer, z=1)        [SwiftUI]   ← only present when a card is pending
                                  .frame(maxWidth: maxLayoutWidth=780)
                                  .padding(.horizontal, 20)
                                  .transition(.scale(0.96,.bottom)+.opacity)
                                  └── VStack: header / body(for:kind) / reason / buttonRow
                                        └── PermissionShellCardBody / …CardBody  [SwiftUI]  (per-kind)
                                              └── (e.g.) BoundedHeightScrollView → DiffView
```

Key geometric consequence (FACT): the `ZStack`'s bottom is the chrome
row's bottom (both children bottom-aligned + same `chatBottomInset`
padding). When the card child appears, the stack's intrinsic height =
`max(barHeight, cardHeight + overlap)` instead of `barHeight`. The host
re-reads that and, pinned at the bottom, grows its **top** up by the
delta.

---

## 3. Data flow

### 3a. State INTO this area (read path) — unidirectional, clean

```
CLI permission request
  → AgentSDK session.onPermissionRequest closure
  → SessionRuntime.enqueuePermission(request, completion)        [SessionRuntime+Start.swift:743-791]
       appends PendingPermission{id, request, respond:closure} to
       SessionRuntime.pendingPermissions  (@Observable internal(set))   [SessionRuntime.swift:243]
  → Session.pendingPermissions { runtime?.pendingPermissions ?? [] }   [Session.swift:333-335]   (read-only forward)
  → ChatRestingBar reads session.pendingPermissions.first             [InputBarChrome.swift:143]
       (SwiftUI Observation tracks the @Observable read; body re-evals
        next beforeWaiting — NOT same tick as the runtime write)
  → if non-nil → PermissionCardView(request: pending.request, …)
```

This read path is **clean and unidirectional**: the view never caches
`pendingPermissions`, never writes it, reads it through the `@Observable`
forward exactly as the §"Adding new runtime state" rule prescribes. (FACT)

### 3b. Events OUT of this area (decision path) — clean, one back-channel hop

```
PermissionCardView button tap (onAllowOnce / onAllowAlways / onDeny / onAllowWithInput)
  → ChatRestingBar closure: session.respond(to: pending.id, decision: pending.request.allowOnce()/…)   [InputBarChrome.swift:146-155]
  → Session.respond(to:decision:) → runtime?.respond(...)            [Session.swift:687-688]
  → SessionRuntime.respond: pendingPermissions.first(where id) → pending.respond(decision)   [SessionRuntime+Configuration.swift:118-124]
  → PendingPermission.respond closure (built in enqueuePermission):
       completion(decision)                       ← answers the SDK
       Task { @MainActor in pendingPermissions.removeAll { id } }    [SessionRuntime+Start.swift:784-789]
  → @Observable write to pendingPermissions (one async Task hop later)
  → ChatRestingBar body re-evals → card child disappears → ZStack collapses
  → host intrinsic height shrinks → top edge drops back → .animation animates the shrink
```

The decision-out path is also unidirectional. The only async hop is the
`Task { @MainActor }` deferral of the `removeAll` (`SessionRuntime+Start.swift:786`),
so the card stays visible for one extra main-actor turn after the tap
(harmless; `PermissionCardWiringTests` documents this at lines 79-88). (FACT)

### 3c. Geometry back-channel (the COUPLING that drives the pain)

This is the **hidden bidirectional coupling** between "card content" and
"host geometry":

```
card present?  ──(SwiftUI body)──►  ZStack intrinsic height (union)
                                        │
                                        ▼  (NSHostingView .intrinsicContentSize)
                                   composeOrBarHost intrinsic height
                                        │
                                        ▼  (Auto Layout, bottom-anchored)
                                   host top edge moves UP/DOWN
                                        │
                                        ▼  (.animation(.smooth) on the body)
                                   ANIMATED expand/collapse of the band the host occupies
```

This is not a literal write-loop, but it IS a coupling: the card's
*existence and size* feed the host's *geometry*, by design (PR #235 chose
`ZStack` precisely so the host would grow — `InputBarChrome.swift:94-101`).
That coupling is what makes the card "move the furniture" instead of
"float in place." (FACT for the chain; INFERENCE that this is the user's
"喧宾夺主" complaint.)

Separately, the chrome reports its own geometry OUT via two callbacks
(`onAttachRect` / `onPillRect` → `ChatSessionViewController.applyScrimCutouts`,
`ChatSessionViewController.swift:231-234,557-566`) so the bottom scrim can
cut holes for the attach button + pill. That is unrelated to the card but
shares the host. (FACT)

---

## 4. Ownership & lifetime

- **`composeOrBarHost`** — constructed in `ChatSessionViewController.loadView()`
  (`…/ChatSessionViewController.swift:161`), retained as a stored `var`
  (`:94`), added to `view` once, lives for the **entire VC lifetime**
  (never re-created on session switch — only its SwiftUI body re-evals).
  Torn down with the VC. (FACT)

- **`ChatComposeStack` / `ChatRestingBar` / `PermissionCardView`** — SwiftUI
  value types, not "owned." `ChatComposeStack` is built once in
  `makeComposeOrBarStack()` (`:545-582`) and wrapped in `AnyView`;
  `ChatRestingBar` is re-instantiated on each `selection` change inside
  the stack's `body` (keyed `.id(sid)`, `:659-667`), which resets
  `InputBarView2`'s `@State`. `PermissionCardView` is created/destroyed
  in `ChatRestingBar.body` purely as a function of
  `session.pendingPermissions.first`. No reference identity, no manual
  teardown. (FACT)

- **`Session` / `SessionRuntime` / `pendingPermissions`** — owned by
  `SessionManager` → `Session` → `SessionRuntime` (root CLAUDE.md ownership
  graph). `pendingPermissions` has the same lifetime as the runtime; the
  card view holds no copy. The bar resolves the `Session` per-render via
  `manager.prepareDraftSession(sessionId)` (idempotent get-or-create,
  `InputBarChrome.swift:33-35,125`). (FACT)

- **The decision callbacks** — closures captured in `ChatRestingBar.body`
  per-render (`InputBarChrome.swift:146-155`), capturing `session` +
  `pending`. Re-created each body eval; no retain concern (values). (FACT)

- **`PendingPermission.respond` closure** — owned by the array entry,
  captures `[weak self]` runtime + `completion` + `request.requestId`
  (`SessionRuntime+Start.swift:784-789`). Lives until the entry is removed.
  (FACT)

---

## 5. Smells / debt

| # | Title | Severity | Evidence (file:line) | Why |
|---|---|---|---|---|
| 1 | **Card visibility coupled to bar-host geometry via ZStack union height** | high | `ChatRestingBar` ZStack `…/Content/Chat/InputBarChrome.swift:126,143-162`; host `…/App/AppKit/ChatSessionViewController.swift:169,202-207` (no height constraint) | The card's size is load-bearing for the host's intrinsic height, so "card appears" == "host grows upward." This is the structural cause of the "shove / replace" feel. A floating overlay should not resize its host. (FACT for chain; INFERENCE for cause.) |
| 2 | **One body-level `.animation(.smooth)` animates BOTH the card transition AND the host height change** | high | `…/Content/Chat/InputBarChrome.swift:166` | `.animation(_:value:)` on the whole body means the geometry expansion (host top edge rising) and the card's own `.transition` are driven by the same 0.25s curve. The intended effect is "card fades in"; the actual effect bundles in "the bar band grows up." Splitting these (animate only the card's opacity/scale; make the host height change non-animated or pre-reserved) is the crux of the fix. (FACT) |
| 3 | **The doc comment claims "z-axis, nothing else moves" but the host demonstrably grows** | medium | comment `…/InputBarChrome.swift:84-101` ("does NOT stack above the bar on the y-axis"; "collapses back to the bar's height, so the host shrinks") vs. mechanism in §0 | The comment is technically correct about the *bar* not moving within the ZStack, but it omits that the *host* grows/shrinks (and animates). Reading the comment, a maintainer would not expect the furniture to move — yet the same file's `…shrinks` wording at :100 admits it does. The comment under-describes the visible effect. (FACT) |
| 4 | **`maxWidth` mismatch between the card (780) and the bar (512) inside one ZStack** | low | card `.frame(maxWidth: BlockStyle.maxLayoutWidth=780)` `…/InputBarChrome.swift:157`; bar `.frame(maxWidth: composeMaxWidth=512)` `…/InputBarChrome.swift:139` | The two stacked children have different width budgets, so the card is visibly wider than the pill. Intentional (comment `PermissionCardView.swift:10-16`) but it reinforces the "different surface tier" look that fights the "belongs to the bar" goal. Worth a conscious decision in a refactor. (FACT + INFERENCE.) |
| 5 | **Name collision: `PermissionModePicker` vs `PermissionCardView`** | low | `PermissionModePicker.swift:12`; `PermissionCardView.swift:33` | Two unrelated surfaces share "Permission" in the name. The mode picker sets a config field; the card answers a request. Easy to grep-confuse in a refactor. (FACT) |
| 6 | **Production sizing path (`.intrinsicContentSize`) and the demo's sizing path (`GeometryReader`+`PreferenceKey`+constraint) are two implementations of the same intent** | low | demo `…/Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift:105-146`; production `…/ChatSessionViewController.swift:169` | The demo's comment (`:115-120`) even says "exactly as `ChatSessionViewController` does" but then does it differently (hand-rolled). They can drift. A refactor that changes the host-sizing strategy must update both, and the demo is the only place that visibly exercises the card-over-bar composition offscreen. (FACT) |
| 7 | **`bottomFadeScrimHeight = 100` and `contentInsets.bottom = 112` are hand-derived from the bar's *resting* height** | medium | `…/ChatSessionViewController.swift:54-59` (derivation comment); `…/TranscriptScrollViewFactory.swift:35-40` | These constants assume the bar host occupies ~100-112pt. When the card grows the host to, say, 300pt, the transcript content inset is unchanged, so the card overlaps transcript rows that are NOT inset away. (INFERENCE: this is acceptable today because the card is opaque and floats, but any refactor that wants "card floats, transcript shifts to clear it" would have to make the inset dynamic — which is currently a fixed constant. Flagging so a refactor doesn't assume the inset already tracks the bar.) |
| 8 | **`PermissionCardView` body dispatch is a 14-arm switch with a `default` fallthrough** | low | `PermissionCardView.swift:95-127` | Adding a kind requires touching the enum (`PermissionCardKind.swift`), the switch (`PermissionCardView.swift:95`), and `toolVerb` (`:177`). Not exhaustiveness-checked (has `default`), so a new kind silently falls back. Minor; the per-kind body split is otherwise clean. (FACT) |

---

## 6. Load-bearing invariants a refactor MUST preserve

These are the constraints that an "make it fade in place, nothing moves"
refactor must NOT break. Each is sourced from code + the PR history that
established the current shape.

1. **The card must remain hit-testable and visually unclipped.** PR #235
   (`7bf9918`) chose `ZStack` over `.overlay` *specifically* because an
   overlay is sized to its host and the card's upper half would fall
   outside the bottom-anchored host's hit-test bounds — killing its
   buttons (`…/InputBarChrome.swift:94-101`). Any new composition that
   stops growing the host MUST provide an alternative tall-enough
   hit-test surface for the card (e.g. host the card in a separate
   always-full-height overlay, or give the host a height that already
   reserves card space). Do not regress to a plain `.overlay` on the
   bottom-anchored host. (FACT — this is the exact regression #235 fixed.)

2. **The host must NOT publish a *required* intrinsic height that leaks
   into the window's constraint solver.** The demo comment
   (`…/PermissionSessionDemoViewController.swift:115-120`) and root CLAUDE.md
   ("Embedding SwiftUI in AppKit: host sizing") warn that a fill-a-pane
   host with a leaking intrinsic height collapses the window. The current
   solution is `sizingOptions = [.intrinsicContentSize]` + bottom-anchor +
   `width <= maxHostWidth` (component case, not fill case). A refactor
   that pins the host taller must keep the host in the "subordinate
   component" sizing regime (`[.intrinsicContentSize]`, position-pinned),
   never `[]`-with-full-bleed over the transcript. (FACT.)

3. **The transcript must keep receiving clicks in the band ABOVE the bar.**
   The whole reason the host is bar-height-only (not full-bleed) is that a
   plain `NSHostingView` claims every point in its bounds for hit-testing,
   shadowing the transcript (`…/ChatSessionViewController.swift:163-170`).
   If a refactor makes the host taller (to reserve card space), the extra
   height MUST be hit-test-transparent where the card isn't drawn, or the
   transcript loses clicks in that band. (FACT — this is the #224/#234
   "fast switch swallows transcript clicks" class of bug.)

4. **`pendingPermissions` stays a read-only `@Observable` forward; the card
   never caches or writes it.** Per Services/Session/CLAUDE.md rules
   ("Views never cache session properties as their own state"). The
   read/write split (read `session.pendingPermissions`, write
   `session.respond`) must survive. (FACT.)

5. **The decision path must keep routing through `Session.respond(to:decision:)`
   → `runtime.respond` → `pending.respond`.** Pinned by
   `PermissionCardWiringTests`. The async `Task { removeAll }` hop
   (`SessionRuntime+Start.swift:786`) is intentional and the test accounts
   for it. (FACT.)

6. **`ChatComposeStack` routing: only `.session(_)` renders a bar.**
   Pinned by `ChatComposeStackRoutingTests`. The `.id(sid)` reset on
   session switch (`…/ChatSessionViewController.swift:659-667`) is
   load-bearing — without it `InputBarView2`'s `@State` (text /
   attachments / focus) leaks across sessions. A refactor of the stack
   must preserve both. (FACT.)

7. **The transcript performance contract is untouched by this area.** The
   card composition lives entirely in the SwiftUI bar host; it never
   touches `Transcript2Coordinator` / `layoutCache` / the §2 contract.
   A refactor here should keep it that way — do NOT try to "shift the
   transcript to clear the card" by mutating the transcript's
   `contentInsets` on every card show/hide if that would force re-tiles
   (the inset write itself is cheap, but animating it interacts with the
   scroll anchor — out of scope for the card and risks the §2.7 anchor
   path). If dynamic inset is wanted, prove it against
   `TranscriptScrollFirstFrameSnapshotTests` / the anchor probes first.
   (INFERENCE — protective.)

8. **Window-toolbar / scrim height constants assume the *resting* bar
   height.** `topFadeScrimHeight=52`, `bottomFadeScrimHeight=100`,
   `contentInsets.bottom=112` (`…/ChatSessionViewController.swift:53-63`,
   `…/TranscriptScrollViewFactory.swift:40`). A refactor that reserves a
   fixed taller host height must NOT silently change these — the bottom
   scrim cutouts + the last-cell breathing room are derived from them.
   (FACT.)

---

## 7. What a clean "card fades in floating, nothing else moves" needs (analysis, not prescription)

INFERENCE, grounded in the facts above — offered to orient the refactor,
not to mandate an implementation:

The single root coupling is **smell #1 + #2**: card-size → host-height →
animated band growth. To make the card fade in *without moving the bar
band*, the host's footprint must stop being a function of the card's
presence. Two shapes both satisfy invariants 1-3:

- **(A) Reserve nothing; present the card in a separate full-height,
  hit-test-passthrough overlay layer** (sibling to the bar host, pinned
  full-bleed, transparent except where the card draws — like the scrims
  already do via `hitTest` passthrough, `…/ChatSessionViewController.swift:88-91`).
  The card fades in (opacity/scale only) anchored to the bar's top; the
  bar host never changes size, so nothing else moves. This keeps the bar
  host as the pure resting bar and moves the card to its own surface
  whose size is constant. Cost: a second overlay + routing the card's
  decision callbacks + `pendingPermissions` read into it.

- **(B) Keep the ZStack but decouple the animation:** drive only the
  card's `.transition` (opacity/scale) and make the host-height change
  *instantaneous* (no `.animation` on the geometry) — i.e. the band snaps
  to the card height while the card itself fades in over it. This is a
  smaller change but the band still snaps taller (just not animated), so
  it is a partial fix; the user may still perceive the snap.

(A) is the cleaner unidirectional shape (card surface size is constant;
no card→host geometry feedback). (B) is the minimal change. Either way,
the load-bearing constraint is invariant #1 (hit-test surface) — (A)
satisfies it with a dedicated overlay; (B) satisfies it by keeping the
ZStack growth (so it doesn't actually remove the coupling, only the
animation).

---

## 8. Cross-references

- Root CLAUDE.md — "Embedding SwiftUI in AppKit: host sizing" (the
  `[]` vs `[.intrinsicContentSize]` rule that governs `composeOrBarHost`)
  and "macOS runloop tick model" (why `@Observable` writes reach the
  SwiftUI body next beforeWaiting, relevant to the card show/hide timing).
- `…/Content/Chat/CLAUDE.md` — `ChatSessionViewController` row
  (bottom-anchored bar host "**always**, never full-bleed") + the "Rules"
  ("Cross-view coordination uses closures injected from
  `ChatSessionViewController`… Don't introduce a new ViewModel layer").
- `…/Services/Session/CLAUDE.md` — the `@Observable` forward rules for
  `pendingPermissions` and the AppKit-vs-SwiftUI channel split.
- PR #235 (`7bf9918`) — established the ZStack-over-bar composition (the
  exact design the user is now questioning).
- PR #248 (`0411c02`) — replaced the GeometryReader/PreferenceKey/height-
  constraint loop with `.intrinsicContentSize` (the current host-sizing).
- PR #234 (reverted/relanded) — the bottom-anchored bar host containment
  that #235 had to repair the card placement for.
