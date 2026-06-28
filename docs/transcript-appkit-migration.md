# Migrating the Chat / Transcript Detail Page to Pure AppKit

> **Status:** Proposal / plan only — no code has been written. Produced via a fan-out
> design workflow (8 per-subsystem designs) with two adversarial reviewers each
> (timing/correctness + completeness/scope), synthesized into this document. Blocker
> and major review findings are folded into the per-subsystem plans below; genuinely
> open calls are collected in §10 "Decisions for the human".
>
> **Branch:** `refactor/transcript-appkit-only`

## 1. Goal

Make the chat / transcript detail page **pure AppKit** — zero SwiftUI on the page the user sees while talking to Claude — and **simplify the component tree** by collapsing the passthrough/wrapper layers that exist only to thread parameters and environment across the AppKit↔SwiftUI seam. The transcript renderer (`NativeTranscript2`) and its scrims are already AppKit and stay untouched; everything *around* them that is still SwiftUI-hosted — the 5-layer compose chain (`ChatComposeHostRoot → ChatComposeStack → ChatRestingBar → InputBarChrome → InputBarView2`), `PassthroughHostingView`, the permission-card stack, the chrome pickers, the completion popup, the compose/draft/new-session surfaces, and the two transcript sheet bodies — is ported to AppKit and the dead plumbing is deleted. After this work, SwiftUI survives in the app **only** in the Archive feature (plus the separate Settings/About window scenes — see §10). The data layer, state machines, and self-drawing AppKit leaves (`CompletionState`, `decisionHandlers`, `GitProbe`, `BackgroundTaskOutputStream`, `DiffNSView`, `InputNSTextView`, the per-kind permission data getters) are reused verbatim; this is overwhelmingly view-shell work, not new algorithms.

---

## 2. Scope & non-goals

**In scope (rewritten to AppKit):**
- Input bar: `InputBarView2`, the unwrapped text core, attachments, completion popup, send/stop, attach button.
- Chrome row + 5 pickers (`InputBarSessionChrome`, `PermissionModePicker`, `ModelEffortPicker`, `ContextRingButton`, `BackgroundTaskButton`, `TodoButton`) and their popover bodies + custom drawing.
- Permission card stack (`PassthroughHostingView`, `PermissionCardOverlay`, `PermissionCardView`, 12 per-kind bodies incl. fallback, the AskUserQuestion wizard).
- Compose / draft-landing / new-session (`ComposeSessionView`, `DraftSessionLandingView`, `NewSessionConfigurator`, `BranchPickerView`).
- The two transcript sheet **bodies** (`UserBubbleSheetView`, `ImagePreviewSheetView`) + `InputBarView2`'s duplicate image preview.
- Shared surfaces (`BarSurfaceModifier`, custom-drawn leaves `ProgressRingView` / `TodoStatusGlyph`).

**Explicitly NOT touched:**
- **Transcript renderer** (`NativeTranscript2`, `NSTableView` + Core Text) and **scrims** (`TranscriptTopScrimView` / `TranscriptBottomScrimView`) — already AppKit. We only **preserve the scrim cutout data path** (the `onAttachRect`/`onPillRect` feed), now sourced from AppKit `convert(_:to:)` instead of SwiftUI `.onGeometryChange`.
- **`TranscriptSwapCoordinator` swap ordering** — the single owner of `currentSession` and per-attach scroll view + `Transcript2SheetPresenter` + `isRunning` sink. Build-in-front / drop-outgoing-last under one disabled `CATransaction`, A→B→A flush-before-bind, the single-width typeset contract: **do not disturb**. The new bar/card are siblings of the transcript scroll exactly as `restingBarHost`/`permissionCardHost` are today; `insertScroll(.below topScrim)` z-order is unchanged.
- **`Transcript2SheetPresenter` mechanism** — already the AppKit `.sheet` replacement (`withObservationTracking` → `beginSheet`, `OpenSheetTag` identity, explicit `onDismiss`). Only its hosted content type flips from `NSHostingController` to plain `NSViewController`.
- **Archive** stays SwiftUI (`ArchiveViewController` keeps its `NSHostingController(ArchiveView)`). Consequently `MountFillPaneHost`, `DetailContext`, `injectDetailEnvironment`, `FolderFilterPickerView`, `SearchField`, `HoverCapsuleStyle`, and `DiffCore` all **survive** — only their *chat-page call sites* go away.

**Decision for the human (called out, not assumed):** Settings/About are separate SwiftUI `Window` scenes, not the transcript page. Recommendation: **keep them SwiftUI** — they are out of the literal "transcript page" scope, are window-content regime (the window snaps to content, no collapse hazard), and porting them buys nothing toward the stated goal. But the user said "SwiftUI only in Archive," so if that is meant literally, Settings/About are a separate, lower-value follow-up. See §10, Decision D1.

---

## 3. The new component / ownership tree

### Before

```
DetailRouterViewController  (sole structural observer of MainSelectionModel)
└─ ChatSessionViewController  (DetailRouterChild; "what the pane shows")
   ├─ transcript scroll (.below topScrim)   ── AppKit, untouched
   ├─ topScrim / bottomScrim                 ── AppKit, untouched
   ├─ restingBarHost: NSHostingView<ChatComposeHostRoot>   ◀── SwiftUI
   │     └─ ChatComposeHostRoot → ChatComposeStack → ChatRestingBar
   │          → InputBarChrome → { InputBarView2 + InputBarSessionChrome }
   │               InputBarView2:  text(InputTextView→InputNSTextView), attachments,
   │                               send/stop, AttachButton, CompletionListView, .sheet
   │               InputBarSessionChrome:  [pickers…] (each .popover)
   └─ permissionCardHost: PassthroughHostingView<AnyView>   ◀── SwiftUI
         └─ PermissionCardOverlay → PermissionCardView → 12 per-kind bodies
ComposeSessionViewController → NSHostingController(ComposeSessionView → NewSessionConfigurator + InputBarChrome)   ◀── SwiftUI
DraftSessionLandingViewController → mountFillPaneHost(DraftSessionLandingView → InputBarChrome)   ◀── SwiftUI
```

### After

```
DetailRouterViewController  (unchanged; sole structural observer)
└─ ChatSessionViewController  (regime-B sizing authority; owns the overlays)
   ├─ transcript scroll (.below topScrim)        ── AppKit, untouched
   ├─ topScrim / bottomScrim                       ── AppKit, untouched
   ├─ inputBarController: InputBarController        ── child NSViewController (regime B)
   │     └─ InputBarView (NSView): pill + AttachButtonView + SendStopButton
   │          + AttachmentStripView + CompletionPopupView   (all in-pane subviews)
   │        ChromeRowView (NSStackView): 5 AppKit picker controllers (NSButton + NSPopover)
   │        owns: InputNSTextView/InputTextScrollView (raw), CompletionState (verbatim),
   │              draft load/clear, completion prewarm, Session resolution, isRunning sink
   └─ permissionCardController: PermissionCardController   ── sibling coordinator
         └─ PermissionCardLayerView (full-pane, click-through, no cursor rect)
              └─ PermissionCardView (NSView chrome) → per-kind body NSViews
                 └─ AskUserQuestionCardViewController  (NSViewController, owns Esc/Enter/focus)
ComposeSessionViewController → ComposeContentView (DotGridView + centered NewSessionConfiguratorViewController) + embedded InputBarController
DraftSessionLandingViewController → DraftLandingContentView (DotGridView + hero) + embedded InputBarController
Transcript2SheetPresenter → hosts TextScrollSheetViewController / ImagePreviewSheetViewController (mechanism unchanged)
```

### Collapsed / deleted passthrough+wrapper layers

| Layer | Disposition | Where it goes |
|---|---|---|
| `ChatComposeHostRoot` (layer 1) | **DELETE** | named the env-injection chain; closures now wired directly into `InputBarController.init`. |
| `ChatComposeStack` (layer 2) | **DELETE** | `.chat(sid)`/`.none` routing already in the router + `present(sessionId:)`; `.id(sid)` reset → see §4 (rebind in place, not re-create); `coordinateSpace` → AppKit `convert(_:to:)`. |
| `ChatRestingBar` (layer 3) | **DELETE** | pure padding/width-cap → the chat VC's regime-B constraints on `inputBarController.view` (same constants: `composeMaxWidth`, `detailHorizontalInset`, `chatBottomInset`). |
| `InputBarChrome` (layer 4) | **FOLD** into `InputBarController` | Session resolution via passed `sessionManager`; the `.task(id: prewarmKey)` prewarm becomes a key-comparison fire on `(cwd, addDirs, pluginDirs)` change. |
| `PassthroughHostingView` | **DELETE** | `hitTest→nil` reimplemented on `PermissionCardLayerView`; the no-op `resetCursorRects` is **unnecessary** on a plain NSView (it registers no cursor rect) — but see §4 (descendants and any glass surface DO register rects). |
| `injectDetailEnvironment` at chat/compose/draft sites | **DELETE (call sites only)** | the 4 services reach AppKit children by direct property passing from the `DetailContext` each VC already holds. `DetailContext` + `injectDetailEnvironment` + `MountFillPaneHost` **survive for Archive**. |
| `ReportFrame` ViewModifier + `detailCoordSpace` string | **DELETE** | geometry reporting → AppKit frame conversion (§4, Input bar). |
| `desiredCursorPosition` two-way `@Binding` + its `DispatchQueue.main.async … = nil` consume-once | **DELETE** | replaced by a direct `setSelectedRange` after a guarded splice. |
| `TextInputView` / `DiffView` `NSViewRepresentable` wrappers + Coordinators | **UNWRAP** | embed `InputNSTextView`/`DiffNSView` directly; the Coordinator's guards (`isUpdatingText`, `hasMarkedText`) migrate onto the AppKit owner. |
| `VisualEffectView` (SwiftUI representable) | **DELETE** | zero construction sites; real vibrancy already uses raw `NSVisualEffectView`. |
| `BoundedHeightScrollView` (SwiftUI) | **DELETE** | replaced by a height-capped `NSScrollView` constraint. |
| `SelectableText` | **DELETE** | dead (zero construction sites; verify per §6). |

This is the genuine simplification. **Be honest about what it is:** the 5 plumbing layers + `PassthroughHostingView` + `ReportFrame` + `injectDetailEnvironment` (chat sites) + the representable wrappers + `VisualEffectView`/`BoundedHeightScrollView`/`SelectableText` are real dead weight that disappears. The per-kind card bodies, the pickers, and the custom-drawing leaves are **1:1 relocations**, not collapses — AppKit's controller/content-VC split for popovers often nets *more* types than the co-located SwiftUI view. Net node count is roughly flat; the win is **fewer cross-boundary hops and one source of truth per surface**, not fewer files.

---

## 4. Per-subsystem plan

### 4.0 Architecture / ownership spine

**Built:** `InputBarController` (child `NSViewController` of `ChatSessionViewController`, *not* a `DetailRouterChild`) and `PermissionCardController` (sibling coordinator mirroring `Transcript2SheetPresenter`). `ChatSessionViewController` stays the regime-B sizing authority and the owner of "what the pane shows."

**Key decision — rebind in place, do NOT re-create the bar VC per session (BLOCKER fix).** The original design proposed tearing down and re-`addChild`-ing `InputBarController` inside `present(sessionId:)` as the `.id(sid)` analogue. The timing reviewer correctly flagged this as a collision with `attachSession`'s single-width typeset contract: the router calls `view.layoutSubtreeIfNeeded()` before `present`, and `attachSession` calls `container.layoutSubtreeIfNeeded()` mid-swap to settle the table at its **final** width with no rows bound. A freshly-added child whose `intrinsicContentSize` is still resolving would join that pass and risk a "typeset at the wrong width" regression (`TranscriptHostReentryLayoutCacheTests`). The current `restingBarHost` is created **once** in `loadView` and only its *content* swaps; the bar's frame/constraints never change on session switch, so it contributes nothing to `attachSession`'s layout pass.

→ **`InputBarController` is created once in `loadView` and lives for the chat VC's lifetime.** `present(sessionId:)` calls `inputBarController.rebind(sessionId:)`, which resets text/attachments/focus/`CompletionState` **in place** (the AppKit analogue of `.id(sid)` is "reset the model fields," not "rebuild the view"). Its constraints are invariant across rebind, so `attachSession`'s layout pass stays bar-invariant. Same posture for `PermissionCardController` (created once, `start(for:)`/`rebind` arms observation).

**Key decision — drive both overlays from the same synchronous `present(sessionId:)` (stale-card fix).** `present(sessionId:)` resolves the `Session` once (via `sessionManager.prepareDraftSession(sessionId)`, idempotent) and hands that exact instance to **both** `transcriptSwapCoordinator.attachSession` and `permissionCardController.rebind(for:session)` in the same source phase. On a fast A→B switch, `rebind` cancels A's observation task and synchronously dismisses A's mounted card (no animation — the transcript crossfade owns the session-switch animation) before arming B. This closes the cross-session stale-card hazard the overlay's `.id(sid)` symmetry used to handle. The card controller is a **second reader** of session identity, never an owner — it re-derives from the `sessionId` the router handed it and guards `boundSession === session` on every observation wake (mirroring `startRunningObservation`'s identity guard). `TranscriptSwapCoordinator` remains the single owner of `currentSession`.

**Teardown:** `InputBarController` and `PermissionCardController` each carry `nonisolated deinit {}`. `ChatSessionViewController.prepareForRemoval()` — which already tears down the transcript — additionally calls `inputBarController.prepareForRemoval()` (cancel draft-load Task + `completion.dismiss()`) and `permissionCardController.stop()` (cancel observation + synchronously dismiss the card). Do **not** rely on `deinit` timing or `viewDidMoveToWindow` alone.

---

### 4.1 Input bar (`InputBarController` + `InputBarView`)

**Built:** `InputBarView` (NSView, hand-laid-out pill, mirrors the existing pixel-numeric frame math) hosting `AttachButtonView`, `SendStopButton`, `AttachmentStripView`, `CompletionPopupView`; `InputBarController` owns the model/wiring. Drop `TextInputView`/Coordinator; embed `InputNSTextView`/`InputTextScrollView` directly.

**Reused verbatim:** `InputNSTextView`/`InputTextScrollView` (text editing core, keyDown IME guards, send-key switch, `keyInterceptor` ordering), `CompletionState`/`CompletionTriggerRule`/`CompletionItem`, the two-stage `loadAsURL`/`loadAsImageData` drop loaders, `InputDraftStore`, `submitSessionInput`, `CompletionPrewarmer`.

**Deleted:** `InputBarView2` struct, `ReportFrame`, the `desiredCursorPosition` binding + consume-once hop, `AttachButton`/`BarSurfaceModifier` SwiftUI at chat sites.

**Adversarial fixes folded in:**

1. **Nested `intrinsicContentSize` (MAJOR).** `InputTextScrollView` already owns its own `intrinsicContentSize` (`updateIntrinsicHeight`); the bar's height must re-sum when the text grows. Do **not** let `InputBarView` publish a height computed independently of the text view. → Add an `onIntrinsicHeightChanged` closure to `InputTextScrollView`, fired from its `updateIntrinsicHeight` (and `viewDidEndLiveResize`), routed into a single `InputBarView.relayout()` that recomputes `pillMinHeight(32) + strip + completionPopup + dividers` and calls `invalidateIntrinsicContentSize()`. Every mutator funnels through `relayout()`. Logic test: type a multi-line string, assert `restingBarHost.fittingSize.height` tracks it (mirror `HostedComponentCenteringTests`).

2. **Scrim-cutout coordinate base + phase (MAJOR ×2).** The current code converts `bottomScrim.convert(lastAttachRect, from: restingBarHost)` — the **from-base is the bar host**, not the VC view. With the bar now two levels down inside the controller's view, the contract must be pinned: `InputBarView` reports attach/pill frames converted **to `inputBarController.view`** (the new `restingBarHost`-equivalent and the `convert(from:)` anchor), and the chat VC does `bottomScrim.convert(rect, from: inputBarController.view)`. Recompute these in `InputBarView.layout()` *after* `super.layout()` (frames settled), **never synchronously off a keystroke**. Critically: **the attach button and pill do not move when the completion popup opens** (the popup grows the bar upward, above the text row), so report attach/pill rects from the bottom-anchored subviews independent of popup state. Logic test: pin reported attach/pill rects to known values for a fixed pane width (origin-base regression guard) and assert they are **stable across popup open/close**.

3. **Completion popup grows the bar (MEDIUM).** The popup is an in-bar `NSScrollView`+`NSStackView`-of-rows subview (see §4.3), **not** an `NSPanel`. Its fixed height adds to `relayout()`'s sum when active, so the bottom-anchored bar grows up to contain it. The `bottomFadeScrimHeight = 100` band stays fixed; the popup is opaque and may extend above the band (same as today's SwiftUI pill). After mount/unmount/height-change, call `invalidateIntrinsicContentSize()` then `superview?.layoutSubtreeIfNeeded()` to settle the regime-B host in the same beforeWaiting flush (explicit-settle discipline, not implicit trust).

4. **Draft-clear-before-`onSubmit` (preserve byte-for-byte).** `handleSend` snapshots the `Submission`, clears `textView.string`/attachments/`completion.dismiss()`, `inputDraftStore.clear(draftKey)`, **then** `onSubmit` — because `onSubmit` flips selection and tears the VC down synchronously in the same source phase. In straight-line AppKit this is *more* robust (no reactive `.onChange` to be swallowed). Logic test: `rebind → handleSend → promote`, assert `clear` ran before `onSubmit`.

5. **Autofocus is window-gated and async-deferred (MAJOR).** `makeFirstResponder` before the view is windowed is a silent no-op, and `InputTextView.updateNSView` deliberately deferred via `DispatchQueue.main.async`. → Drive autofocus from `viewDidAppear` (or an explicit async hop after the bar is in the window), **gated on `view.window != nil`**, never from `init`/`viewDidLoad`. The draft-landing `autofocus=true` path must re-fire on every `rebind` (the draft-landing VC re-mounts per bind), not just first appearance. On `rebind`: resign first, reset state, **then** focus after the new draft loads.

6. **IME marked-text + reentrancy guards migrate onto the owner (MAJOR).** The Coordinator's `isUpdatingText` and `hasMarkedText` guards live in the deleted representable. The `InputBarController` (now `NSTextViewDelegate`) must: (a) wrap every owner-initiated programmatic write (`draft restore`, completion splice) in an `isApplyingProgrammaticText` flag so `textDidChange`/`textViewDidChangeSelection` early-return; (b) keep the `!hasMarkedText()` short-circuit in both delegate methods; (c) pass `textView.hasMarkedText()` **live** into `completion.checkTrigger` (today it's hardcoded `false` — see Decision D4); (d) guard the completion splice and the tap-to-confirm path on `!hasMarkedText()` before mutating string/selection. Preserve `textContainerInset` (the 7.5pt vertical inset so clicks on the padded strip focus the field). Keep the `documentCursor = .iBeam` fix in `InputTextScrollView` when used raw.

7. **`textViewDidChangeSelection` feeds completion (MAJOR).** Both `textDidChange` (typing) and `textViewDidChangeSelection` (pure caret move) call `onTextChanged → completion.checkTrigger` today. Wire **both** delegate methods, or the popup won't dismiss/re-evaluate when the user arrows the caret into/out of a trigger token.

8. **Reactive `submitEnabled` (BLOCKER for compose).** Compose passes `submitEnabled: session.cwd != nil`, re-evaluated by SwiftUI on every folder pick. In AppKit `InputBarController` must **observe `session.cwd`** via `withObservationTracking` (re-armed, same mechanism as `isRunning`) and call `sendStopButton.updateEnabled()`. Logic test: flip `session.cwd`, assert `canSend`.

9. **Send/stop is imperative.** `InputBarController` observes `session.isRunning` via `withObservationTracking` and calls `sendStopButton.setRunning(_:)` (matching `setLoading`). State-transition animations (attachment add/remove `.smooth(0.35)`) run inside `NSAnimationContext.runAnimationGroup`; the completion popup show/hide stays **instant** (today's `.animation(nil)`), wrapped in `CATransaction.setDisableActions(true)` to guard against an enclosing animation context. The `isDropTargeted` dashed stroke on the pill *and* the attach button must toggle in **one** `NSAnimationContext` group so they animate in sync.

10. **AttachButton press feedback + window-level image preview.** The single-item `Menu` collapses to a direct `NSButton` click (opens `NSOpenPanel`); reimplement the `.buttonStyle(.plain)` press-dim (lower `+` template alpha to ~0.5 on mouseDown, glass circle stays solid). The image preview is presented through an **owned presenter** (see §4.8), not a free-hand `view.window?.beginSheet` from a tap closure.

11. **Localization.** Re-home every `String(localized:)` / inferred `LocalizedStringKey`: `"Send a message"`, `"Choose a file to attach"`, `"Remove attachment"`, `"Attach Image or File"`, `"Done"`, plus the completion empty-state strings (which are currently bare `Text` literals — wrap as `String(localized:)`, keys already exist). No new catalog entries; add code + (existing) translation together.

---

### 4.2 Chrome row + 5 pickers (`ChromeRowView`)

**Built:** `ChromeRowView` (`NSStackView`, `[Permission][BgTask][Todo] —spacer— [ModelEffort][ContextRing]`, leading-inset = `AttachButton.size(32) + 8`); `ChromeButton` (shared 22pt pill, `NSTrackingArea` hover); one `BarSurfaceView` backing (§4.8); 5 picker controllers (each `NSButton` trigger + one `NSPopover`, `.transient`); native popover-content VCs (`PopoverMenuViewController` for permission/model-effort, `BackgroundTaskListViewController`, `TodoListViewController`, `ContextBreakdownViewController`); custom drawing → `ProgressRingLayer`, `TodoStatusGlyphLayer`, `ContextBarView`.

**Reused verbatim:** `BackgroundTaskOutputStream`, `BackgroundTaskFormat`, `ModelStore.shared`, `EffortDefaultStore`/`NewSessionDefaultsStore`, `PermissionMode.title/shortTitle/triggerTint`, `ContextUsage` ordering/color math, all `Session` `@Observable` accessors + setters.

**Key decision — native popover content, not `NSHostingController`-in-popover.** A SwiftUI-in-popover interim removes one window layer but keeps SwiftUI on the page and re-introduces the tick seam. Default to `NSStackView`/`NSTableView` content; flag the hosting fallback only if a single picker proves disproportionate.

**Adversarial fixes folded in:**

1. **NSPopover steals key-window / first-responder vs IME (MAJOR).** Opening a `.transient` popover makes the popover window key; closing it does not deterministically restore first responder to the input text view, and a mid-IME-composition click would strand marked text. → Each picker controller captures `view.window?.firstResponder` before `show(relativeTo:)`; if the input text view `hasMarkedText()`, call `inputContext?.discardMarkedText()` (or commit) so composition is deterministic; on `popoverDidClose` restore the saved responder. Logic test: drive show/close with a stubbed first responder and assert restoration.

2. **Write-back side effects are NOT display updates (MAJOR).** `backfillModelIfNeeded` (`session.setModel`/`setEffort`) and `seedFromDefaultsIfNeeded` (`session.setPermissionMode`) run from `.task(id:)` with specific keys today. Separate them from the display re-arm loops: run them as **one-shot guards** on `rebind(sessionId:)` and on the specific transitions the keys encode (catalog-first-arrival for backfill; `supportsAuto false→true` for seed), with the idempotent guard re-checked after any write. CI logic test: flip `availableModels` empty→populated, assert `session.model` backfills exactly once.

3. **Dark/light + accent re-resolution (MAJOR).** `CALayer.cgColor` does **not** auto-update on appearance flip; SwiftUI did this free. → Every layer-backed leaf (`ProgressRingLayer`, `TodoStatusGlyphLayer`, `ContextBarView`, `ChromeButton` hover overlay, `BarSurfaceView`) overrides `viewDidChangeEffectiveAppearance` and re-resolves cgColors via `NSColor.resolvedColor(with:)`, wrapped in `CATransaction.setDisableActions(true)` so the color change doesn't crossfade. Prefer semantic `NSColor` in `draw(_:)` (re-resolves per draw) over cgColor-on-layer where there's no animation. Reuse `PermissionMode.triggerTint` resolved against the current appearance. Also set `layer.contentsScale` from the window backing scale and update in `viewDidChangeBackingProperties` (Retina).

4. **Open-popover live reload + click race (MINOR).** Each controller arms two scopes: always-on for the trigger (label/visibility), and one armed on popover-open for the content VC (rows/selection/spinner), torn down on close. Use **`NSStackView`-of-rows** (no cell reuse) for any list hosting a spinning glyph or a tappable row; each row's action captures stable identity (model value, `Effort` rawValue, `PermissionMode`) and re-validates against the live catalog inside `onSelect`. Defer any reload while a row tracking/mouseDown is active.

5. **Background task detail sheet stays window-level (MINOR).** It must `view.window?.beginSheet` (centered on the app window), not present inside the popover. **Capture the main window reference before `performClose`**, close the popover, then `DispatchQueue.main.async { beginSheet }` so the transient close and key-window resignation settle (reproducing SwiftUI's cross-tick serialization and avoiding the documented popover-behind-sheet hang). The detail re-reads the live `BackgroundTask` each sample. `BackgroundTaskOutputStream.stop()` is called from the sheet VC's `prepareForRemoval`/`viewWillDisappear` (deterministic file-tail teardown).

6. **1s elapsed timer + rotation animation lifecycle (MINOR).** The elapsed-counter timer must be added in `.common` run-loop mode (today's `Timer.publish` uses `.common`) or it freezes during scroll/tracking; it only relabels/`setNeedsDisplay`, never writes `@Observable`. Start/stop both the timer and the `RotatingDottedRing` `CABasicAnimation` from `NSPopoverDelegate` `popoverWillShow`/`popoverDidClose` (covers the `.transient` auto-close path), invalidate in `nonisolated deinit`. Key the rotation strictly on `state == .inProgress && !muted` (a `setState(_:muted:)` method removes/re-adds it), not on `viewDidMoveToWindow` alone (recycle-in-place). The completed-todo glyph stays **one even-odd `CAShapeLayer` path** with `fillRule = .evenOdd` set explicitly (the default `.nonZero` silently regresses to a solid disc).

7. **`.ultracode` synthetic effort tier (MINOR).** Extract `activeEffortLevels` (appends `.ultracode` for xhigh-capable models) and the `onSelectEffort` persistence rule (the `effort != .ultracode` skip-persist guard) into named helpers the AppKit controller calls; list them in the reused set. CI logic test: select `.ultracode`, assert `EffortDefaultStore` unchanged.

8. **ContextRing once-per-open request (MINOR).** Fire `session.requestContextUsage()` from the popover content VC's `viewWillAppear` (matching `.onAppear` once-per-open), not from controller bind. Arm one scope over `{contextUsage, isFetchingContextUsage}` for the open popover; reconcile breakdown-vs-placeholder in one callback.

9. **`ChromeRowView` rebind discipline.** `ChromeRowView` and each picker controller cancel their observation Task + invalidate timers at the **top** of `rebind(sessionId:)` before reading the new session (copy `runningObservationTask?.cancel()`). The chrome row is **not** a `MainSelectionModel` structural observer — it is driven only by the chat VC's `present(sessionId:)`.

10. **Show/hide-on-populate is height-invariant.** BgTask/Todo/ModelEffort visibility toggles via `NSStackView` arranged-subview `isHidden`. The chrome row is the chat VC's own AppKit arranged subview at a **fixed 22pt height**, so `isHidden` toggles never change the bar band's reported height. The async re-arm latency (one tick late) is acceptable for these display updates; the show is opacity/implicit-CA only, never a height/width constraint the bar host observes. Layout test: bar band height invariant across `tasks.isEmpty` true→false.

11. **Localization.** Keep `String(localized:)` for `"N running"`/`"M of N"`/`"Loading models…"` and keep the deliberately-un-localized section headers (`"Mode"`/`"Models"`/`"Effort"`) as plain literals (CLI vocabulary; `InputBarLabelsTests` guards this — port an AppKit-side analog).

---

### 4.3 Completion popup (`CompletionPopupView`)

**Built:** `CompletionPopupView` (in-bar `NSScrollView` + **`NSStackView` of ≤11 lean row views** — not `NSTableView`, not `NSPanel`); `CompletionRowView`; `CompletionListLayout` (pure-math struct of the layout constants + `listHeight(...)`).

**Reused verbatim:** `CompletionState`, `CompletionTriggerRule`, `CompletionItem`, the stores. `displayIcon` is already `NSImage` (no bridge).

**Deleted:** `CompletionListView.swift` only.

**Key decisions / adversarial fixes:**

1. **In-pane subview, not `NSPanel`.** Preserves first-responder (text view keeps focus; the popup never steals it), composites with the pill, rides the bottom-anchored bar. Key routing flows through `InputNSTextView`'s existing `keyInterceptor` (keyCodes 126/125/48/36 = Up/Down/Tab/Return; **no** left/right handling — confirmed). The popup is contingent on the text view being first responder (autofocus dependency, §4.1-5).

2. **`NSStackView`-of-rows over `NSTableView` (resolves the open question).** ≤10 visible rows never virtualize. This removes `NSTableView`'s competing selection model, the header/empty pseudo-row mapping headache, and the `scrollRowToVisible` centering mismatch. Selection is driven **solely** by `CompletionState.selectedIndex` (row draws its own highlight from `reconcile`). Header and empty/loading/no-directory states render as fixed views, **not** rows: `numberOfRows == items.count` so `selectedIndex` maps 1:1. Reproduce the exact 4-branch table: `(header, items empty)` → header-only no placeholder; `(no header, empty, loading)` → Loading; `(no header, empty, !loading)` → emptyReason; `(items)` → rows + optional header.

3. **Imperative-now for nav, observed-async only for provider results (MAJOR fix).** `confirmSelection`/`dismiss` already mutate `@Observable` synchronously and the bar's height must shrink in the **same** tick the popup dismisses (`withObservationTracking` re-arm is async → one tick late → gap for a frame). → The `keyInterceptor` path (move/dismiss/confirm) calls `popup.refresh()` + `InputBarView.relayout()` **inline** (the allowed imperative carve-out). `withObservationTracking` is scoped to **`items` arrival only** (the genuinely-async provider callback). Do **not** observe `selectedIndex` (only the imperative nav/tap paths write it) — exactly one writer per field per phase. The reconcile closure reads every rendered field (`items, selectedIndex, isLoading, emptyReason, headerText, isActive`) so the observation is fully armed, re-armed via `DispatchQueue.main.async { observeCompletion() }`.

4. **Confirm splice reentrancy (MAJOR fix).** `confirmSelection()` dismisses then the direct `insertText(replacement, replacementRange:)` + `setSelectedRange` drives `textDidChange` **and** `textViewDidChangeSelection` — a double trigger eval in the same source phase the SwiftUI binding buffered. Wrap the splice in the `isApplyingProgrammaticText` guard (§4.1-6) so both delegate callbacks early-return. Logic test: confirm an @file item, assert `CompletionState` inactive and items empty afterward.

5. **Fixed height constraint.** `CompletionPopupView` gets a `@required` height constraint set per `reconcile` from `CompletionListLayout.listHeight(...)`; the inner content size **never** drives `intrinsicContentSize`. Lifecycle: the popup view is created with the bar and hidden/shown (never deallocated mid-life), so `reconcile` never targets a dead view; `completion.dismiss()` on `prepareForRemoval` cancels debounce/provider Tasks.

6. **Tests + localization.** CI logic tests (not snapshots): `CompletionListLayout.listHeight(...)` pixel-exact across the 4 branches; a `reconcile` mapping test (`numberOfRows == items.count`, branch selection). Empty-state strings (`"Loading…"`, `"No matches"`, `"Please select a working directory first"`) become `String(localized:)`.

---

### 4.4 Permission card (non-AskUserQuestion)

**Built:** `PermissionCardController` (§4.0), `PermissionCardLayerView` (full-pane, click-through), `PermissionCardView` (NSView chrome: `NSStackView` header → body → reason → button row), an **opaque** card-surface view (see fix 1), `PermissionDecisionButton` (custom-drawn `NSControl`, ported once, shared with AskUserQuestion), `PermissionBodyChip`/`PermissionMonospaceScrollBlock`/`PermissionBoundedDiffView` helpers, 12 per-kind body builders (incl. `PermissionFallbackCardBody` for `.unknown` — see fix 5).

**Reused verbatim:** `decisionHandlers(for:session:)` (kept as a free function / static so `PermissionCardWiringTests` compiles with at most a rename), `PermissionRequest`/`PermissionCardKind`/`PermissionCardCopy`/`SedEditParser`, every per-kind data getter (kept as the **same per-kind value types with the same initializers** the body tests construct — see §9), `DiffNSView`, `DiffBlock`, `DiffCore`, `SyntaxHighlightEngine`.

**Adversarial fixes folded in:**

1. **The card surface is OPAQUE, not glass (BLOCKER fix).** `PermissionCardSurface` deliberately fills `controlBackgroundColor` (solid) with a documented anti-bleed-through reason — the bar's material behind it made diffs unreadable. **Do NOT back the card with the glass `BarSurfaceView`.** The card gets its own opaque-panel surface: rounded `controlBackgroundColor` fill (cornerRadius 16, `.continuous`), 0.5pt `separatorColor` border, its own shadow (opacity 0.35 dark / 0.12 light, radius 10, y4 — different from the bar's params). Re-resolve cgColors on `viewDidChangeEffectiveAppearance` (§4.2-3).

2. **Click-through + cursor on a plain NSView, but NOT its descendants (MINOR fix).** `PermissionCardLayerView.hitTest` returns nil only when the deepest hit is the layer view itself; the card subview (including its 14/12 padding) claims clicks. The layer view registers **no** cursor rect (so the transcript I-beam shows through the margin) — but `DiffNSView.resetCursorRects` registers `.pointingHand` for its copy button and selectable text wants the I-beam, so **only the layer view is cursor-rect-free**; descendants keep normal behavior. **`DetailPaneTranscriptHitTestTests` is a CI gate** that hard-references `PassthroughHostingView` and `chatVC.permissionCardHost`: rewrite `enclosingPassthroughHost` to walk to `PermissionCardLayerView`, retype the VC's host property, and re-assert (a) transcript I-beam/`BlockCellView` outside the card, (b) pointing-hand over the diff copy button, (c) click-through during dismiss. This rewrite lands in the **same** PR that deletes `PassthroughHostingView`.

3. **Observation: construction-time reconcile + identity guard (MAJOR fix).** `rebind(for:session)` arms a `withObservationTracking` loop over `session.pendingPermissions.first?.id` (a `String?`) **and** calls `reconcile()` synchronously immediately after arming — otherwise a session re-entered with an already-pending permission strands the card (the loop suspends seeing the pending value and never wakes). Guard `boundSession === session` on each wake. On `present(B)`, cancel A's task and synchronously dismiss A's card (no animation) before arming B (§4.0).

4. **Hit-through during dismiss + animation outside the swap transaction (MAJOR/MINOR fix).** During the dismiss fade, set an `isDismissing` flag the card's `hitTest` checks to return nil (visually present, hit-transparent — matching SwiftUI's "absent from the tree during transition"), `removeFromSuperview` only in the animation completion. Drive the appear/dismiss animation from the observation's async beforeWaiting hop, **outside** any transcript-swap `CATransaction.setDisableActions(true)` window. **Animation fidelity (Decision D5):** the bottom-anchored `.scale(0.96, anchor:.bottom)` needs `anchorPoint`+`position` juggling that fights constraint-driven layout; recommend **opacity + a small center scale** (or a transform-only non-constraint-positioned wrapper) to avoid the post-animation position jump.

5. **Fallback body + nil-diff sub-layouts (MINOR fix).** Keep the `default:` dispatch arm → `PermissionFallbackCardBody` (reads `PermissionCardCopy.parameter`). Each diff-family builder ports **both** arms: `PermissionBoundedDiffView` when `diffBlock != nil`, and the localized secondary-text fallback when nil (SedEdit also appends the literal command). FileWrite/SedEdit do their synchronous FS read **at build time** (in the body-builder func), once per mount, never in a `draw`/`layout` path.

6. **DiffNSView highlight re-homing (MEDIUM fix).** `DiffView`'s SwiftUI `.task` drove `engine.highlightBatch → DiffNSView.update(lineMap:)`. `PermissionBoundedDiffView` owns that Task: on construct kick `Task { let map = await engine.highlightBatch(...); if !Task.isCancelled { diffView.update(lineMap: map) } }` (reproduce the post-await `Task.isCancelled` guard; capture `diffView` weakly), cancel on teardown. `engine` reaches it by property (from `DetailContext.syntaxEngine`), not `@Environment`.

7. **Height-cap from settled width (MAJOR fix — §2.19 analogue).** `DiffNSView.intrinsicContentSize` returns `noIntrinsicMetric` until its width-keyed cache is primed at the current `bounds.width`. After the card is constraint-laid-out (`layoutSubtreeIfNeeded`), call `diffView.height(at: settledWidth)` and clamp the scroll view's height to `min(that, cap)`; re-clamp on width change (user-paced pane resize). Same for `PermissionMonospaceScrollBlock` via the text view's layout manager used-height. This replaces `BoundedHeightScrollView`'s `min(ideal, cap)`.

8. **AskUserQuestion carve-out.** The dispatch retains the `.askUserQuestion` case as a **delegation point** to §4.5; `PermissionCardView` renders no generic chrome for it (the `bodyOwnsChrome` branch).

---

### 4.5 AskUserQuestion wizard (`AskUserQuestionCardViewController`)

**Built:** dedicated `NSViewController` owning the state machine (`currentIndex`, `answers`, `singleSelectIndex`, `multiSelectIndices`, `otherText`/`otherActive`/`otherEditing`) as **plain stored properties + `rebuildForCurrentQuestion()`** (not `@Observable` — view-private interaction state, single reader); `AskOptionRowView` (self-drawn flipped NSView, 36pt, `NSTrackingArea` hover); `AskOtherRowView` (collapsed button ↔ editing `NSTextField`); `AskQuestionHeaderView` (back chevron + progress/header chips + question text); reuses the shared `PermissionDecisionButton`.

**Reused verbatim:** `Question`/`Option` decoders, `composedAnswer`, `commitAnswer`, `goBack` rehydration, `confirmEnabled`, `buildUpdatedInput()` — lifted into a SwiftUI-free `AskUserQuestionModel.swift`; the existing `PermissionAskUserQuestionCardBodyTests` (5 decoder methods referencing `.Question`/`.Option`) are updated to the new home in the same change. `decisionHandlers`' `onSubmit`/`onCancel` closures consumed unchanged.

**Deleted:** the SwiftUI body, `AskOptionRowStyle`, `escapeKeyCapture`, `@FocusState`, `#Preview`.

**Adversarial fixes folded in (this is the hardest piece):**

1. **Esc/Enter were FOCUS-INDEPENDENT before; resolve focus ownership atomically (BLOCKER fix).** Today the card holds no key focus — Esc/Enter work via SwiftUI's focus-independent keyboard-shortcut dispatch while the input bar's `NSTextView` stays first responder. Converting to a first-responder-dependent `cancelOperation`/keyEquivalent over a click-through overlay is the core hazard, compounded by `InputTextView.updateNSView` re-asserting input-bar focus on an async hop. **Decision:** when the wizard mounts, **drive the input bar's focus binding to false** (synchronously, same source phase as mount) so the input bar stops re-asserting, then make the wizard root `acceptsFirstResponder` and `makeFirstResponder(rootView)` in `viewDidAppear`. Implement `cancelOperation(_:)` → `onCancel`, and a single `confirm()` reachable via a default-button keyEquivalent `\r`. On dismiss, restore focus (transcript via `makeFirstResponder(nil)` or the input bar — Decision D6). Logic test: mount over a focused input bar, fire Esc, assert wizard received it.

2. **Enter-while-editing-Other (MEDIUM fix).** When the Other `NSTextField` is first responder, implement `control(_:textView:doCommandBy:)` for `insertNewline` → blur the field (collapse Other) → `confirm()` if `confirmEnabled`. Single `confirm()` source of truth for button/Enter/field-newline. Guard `Return`-during-IME-composition: commit the IME session, do not advance.

3. **Three-responder focus (MAJOR fix).** With the input bar resigned (fix 1), the only contenders are wizard-root ↔ Other-field, both owned by the wizard, both moved **synchronously** after the editing-form view is in the tree. Forbid the async-makeFirstResponder fallback while the input bar's re-assert could be live. Logic test: engage Other, drain one runloop tick, assert Other field still first responder.

4. **Intrinsic-height containment (BLOCKER fix).** The wizard's per-question height changes must not pump `restingBarHost`. Pin the wizard VC bottom + leading/trailing (centered, width-capped at `BlockStyle.maxLayoutWidth`) inside the full-pane `PermissionCardLayerView` with **no top constraint**, so growth flows upward and is absorbed by the host's slack. `sizingOptions=[]` is an `NSHostingView` property and does **not** carry to a pure-AppKit child VC pinned in `view`; re-establish no-leak by constraint topology (the full-pane host is regime-A relative to `ChatSessionViewController.view`; the wizard min-size constraints are non-required where needed so they don't propagate to the host's `fittingSize`). Add to the `AppKitSwiftUIBoundaryTests` family: growing the wizard 2→6 options does not change `restingBarHost.fittingSize.height`.

5. **Deterministic teardown of any event monitor (MAJOR fix).** If an `NSEvent` monitor is used anywhere, it is process-global and eats Esc/Return app-wide if it outlives the card — remove it on dismiss and in the wizard VC's teardown (wired into the chat VC's `prepareForRemoval` chain). Cancel in-flight work, remove tracking areas, restore first responder.

6. **Back-nav rehydration (MEDIUM fix).** `goBack` re-populates single/multi/other from `answers` by label-matching + comma-split + unmatched→Other. Lift verbatim into the VC; cover with a logic test driving public action entry points (`selectOption`, `toggleOther`, `commitOtherText`, `goBack`) and asserting restored state — no test-only seam.

7. **Empty-payload fallback + a11y + selection.** Render the `questions.isEmpty` fallback (two labels + lone Cancel) with `cancelOperation` working in that branch too. Self-drawn rows need explicit `NSAccessibility` roles/labels (SwiftUI Buttons were accessible free) or VoiceOver breaks. Decide whether question text stays user-selectable (today it is, via `.textSelection`); if so use an `NSTextField`. Step transitions are **instant** in v1 (drop `withAnimation`; the corrected rationale is simply that in-place row reconfigure is cheaper — there is no intra-step host `CATransaction` to fight, since `PermissionCardOverlay`'s animation keys on `pending.id`, stable across steps).

---

### 4.6 Compose / Draft-landing / New-session

**Built:** `ComposeSessionViewController`/`DraftSessionLandingViewController` drop their hosts and build a root NSView pinned 4-edge; `ComposeContentView` (`DotGridView` backdrop + centered card running `NewSessionConfiguratorViewController`); `DraftLandingContentView` (DotGrid + hero stack); `NewSessionConfiguratorViewController` (two-column card: recents `NSTableView` + `+` `NSOpenPanel`, AppKit `FadeScrim` overlay, hero + meta row + Recent Sessions table + embedded `InputBarController`); `BranchPickerViewController` (`NSSearchField` + sectioned `NSTableView` in `NSPopover`); `DotGridView` (drawRect/CALayer); AppKit recents fade (reuse `TranscriptScrimView` family).

**Reused verbatim:** `GitProbe`, `submitSessionInput`, `runBuiltinSlashCommand`, `NSOpenPanel` flow (`presentFolderPicker` is already AppKit), `RecentProjectsStore`, `SessionManager`.

**Deleted:** `ComposeSessionView`, `DraftSessionLandingView`, `NewSessionConfigurator` (+ `PlusHoverButtonStyle`/`ResumeRowButtonStyle`/`HideEnclosingScrollerWidth`), `BranchPickerView`, the SwiftUI `DotGridBackground`, compose-side `FadeScrim` usage. **Keep** `SearchField` + `FolderFilterPickerView` (Archive toolbar) — scope the deletion sweep precisely (grep after, only Archive should reference them).

**Adversarial fixes folded in:**

1. **Regime-A no-collapse via constraint topology (BLOCKER fix).** The claim "plain 4-edge NSView publishes no `fittingSize`" is **false** if the inner card carries `@required` min-width/min-height: those propagate to the root's `fittingSize` and re-trip `DetailRouterLayoutDiagnosticsTests`/`AppKitSwiftUIBoundaryTests` (which assert child `fittingSize.height ≤ 1`) and re-cause the window collapse. → The root NSView overrides `intrinsicContentSize = .zero`; the inner card is pinned `centerX`/`centerY` + `<=max @required` + `>=min` at a **non-required** priority + `==ideal @ defaultLow` so the solver satisfies root-fills-pane without propagating the min upward. Keep the documented 880pt min-width window invariant. Update the two diagnostic tests' expectations to the de-SwiftUI'd roots and add a window-resize smoke check.

2. **`cwd → originPath` write coupling (MAJOR fix).** Folder selection (recents click **and** `NSOpenPanel`) calls `draft.setCwd(path); draft.setOriginPath(path)` as a **pair** (confirmed at `ComposeSessionViewController.swift:112-113,186-187`); the empty-folder home-fallback stays in `submitSessionInput`. The four imperative writes replacing the four SwiftUI Bindings: cwd+originPath (paired), `setWorktree`, `setSourceBranch`. `submitSessionInput` reads `originPath` for `recentProjects.markLaunched` — drop the pairing and worktree-pref pre-fill silently breaks.

3. **`applyProbeBindings` + post-`loadHeavy` stale-branch reconcile (MAJOR fix).** The folder→draft reconcile (missing-folder prune + `recents.remove`, worktree pre-fill from `recents.useWorktree(for:)`, `sourceBranch` reset, non-git zeroing) is ~30 lines of glue the GitProbe decision omits. Port it as an explicit method called synchronously after `probe.refresh()` on every folder change; keep the post-`await` stale-branch validation (fall back to `currentBranch` if the saved ref isn't in `probe.branches`) inside the imperative `Task` after `loadHeavy`. Hold the heavy Task in a property and cancel-before-restart for tidiness; correctness relies on `GitProbe`'s own `pendingFolder == path` staleness guard.

4. **Reactive list refresh via re-arming `withObservationTracking` (MAJOR fix).** Both `recents.entries` (left column) and `manager.records` (Recent Sessions) need explicit `tableView.reloadData()` driven by a self-re-arming `withObservationTracking` loop (the `Transcript2SheetPresenter` pattern) — without it, a `+`-added folder won't appear. Read `entries` **lazily** (on first table populate, already user-initiated card open) to preserve the TCC-prompt deferral. On prepend (`add`/`markLaunched` insert at 0): `insertRows(at: [0])` + `scrollRowToVisible(0)` (the inset-bug fix from `HideEnclosingScrollerWidth` is free with native NSTableView; zero `contentInsets`/`scrollerInsets`, `scrollerStyle = .overlay`, `autohidesScrollers = true` once at setup).

5. **Recents context menu (MINOR fix).** Port the per-row `NSMenu` (`"Reveal in Finder"` / `"Remove from Recents"`, both already localized) and preserve `removeFromRecents`' clear-selection-on-current-folder side effect.

6. **Completion prewarm re-fires on compose's live cwd change (MAJOR fix).** `CompletionPrewarmer.prewarm` is keyed on `(cwd, additionalDirs, pluginDirs)` and in compose the **cwd changes** as the user clicks recents rows — the chat resting bar never sees this. The `InputBarController` embedding must re-run prewarm on the resolved session's key change, not just on session-id change. Either the bar owns a prewarmKey observation, or the configurator drives prewarm imperatively on folder change (it already has the `GitProbe` refresh hook there).

7. **Promotion ordering unchanged; teardown during the crossfade.** `submitSessionInput` (`session.send → model.promote → draftSessionId = nil`, synchronous) and the bar's imperative draft-clear stay verbatim. **Bind `draftSessionId` once** in `viewDidLoad` (via `ensureDraftSession()`) as a stored `let` and never read `model.draftSessionId` from the content view — a reactive read would dereference nil during the synchronous promotion teardown window. The router **crossfades** the cross-kind swap, so the dying Compose/Draft VC is alive and visible ~`childCrossfadeDuration` after promotion: give both new VCs a teardown hook (cancel the `GitProbe` Task, close any open `NSPopover`) in `viewWillDisappear` (compose, which is not a `DetailRouterChild`) / `prepareForRemoval` (draft-landing, which **is** — change it from a no-op to real teardown).

8. **Other details.** `submitEnabled` observes `session.cwd` (§4.1-8). Branch-picker `NSSearchField` filter guards on `currentEditor()?.hasMarkedText()` (skip while composing). Popover key routing: Return→Confirm, Esc→dismiss. Worktree control is **writable** (`draft.setWorktree` on selection) and re-read after `applyProbeBindings` — `NSPopUpButton` vs `NSButton+NSMenu` is the only cosmetic part (Decision D7). `onAttachRect`/`onPillRect` stay **no-ops** (no scrims behind compose/draft). Draft-landing branch pill: `sourceBranch ?? worktreeBranch`, hidden when both nil, SF Symbol swaps on `isWorktree`. Localization: keep `String(localized:)` for Projects header, "Start Building", worktree Local/New-Worktree, Recent Sessions, empty states, `NSOpenPanel.message`, branch-search placeholder.

**Sequencing:** lowest-traffic surface, depends on the input bar; lands as a **separate, later PR** after the input bar + permission card.

---

### 4.7 Sheets

**Built:** `TextScrollSheetViewController` (read-only selectable `NSTextView` in `NSScrollView` + divider + Done) replacing `UserBubbleSheetView`; `ImagePreviewSheetViewController` (aspect-fit `NSImageView`, click-to-dismiss, Done) replacing `ImagePreviewSheetView` **and** `InputBarView2.ImagePreviewView` (one preview surface for transcript + input bar). `Transcript2SheetPresenter.makeSheetWindow` flips from generic `<Content: View>` / `NSHostingController` to `contentViewController: NSViewController`; the `withObservationTracking` loop, `OpenSheetTag` identity, `beginSheet`/`endSheet` lifecycle, and explicit `onDismiss` are **unchanged**; drop `import SwiftUI`.

**Adversarial fixes folded in:**

1. **Input-bar preview needs an owner (MAJOR fix).** Do **not** free-hand `view.window?.beginSheet` from a tap closure — an orphaned modal sheet survives the bar's teardown and wedges the window. Give the input bar a small `@MainActor` presenter (mirroring `Transcript2SheetPresenter`) owned by the chat/compose VC, dismissed in `prepareForRemoval`/`stop()`, idempotent, window-guarded. The preview tap never coincides with a session swap.

2. **First-responder on the text sheet (MAJOR fix).** A read-only **selectable** `NSTextView` becomes first responder for ⌘C, and then swallows Return before the Done button's keyEquivalent. → Make the Done button the window's `initialFirstResponder` so Return resolves to it (and/or override the text view's `insertNewline` to forward to `onDismiss`). `isEditable=false` means **no IME marked text** — say so explicitly so nobody copies that machinery. Logic test: fire Return at the sheet window, assert `onDismiss` ran.

3. **Sheet window sizing (MINOR fix).** `beginSheet` does not honor a SwiftUI min/ideal/max envelope. `makeSheetWindow` sets the window `contentMinSize`/`contentMaxSize` from the envelope + resizability; the VC's `preferredContentSize` seeds the ideal. Parameterize per caller (transcript vs the narrower input-bar envelope).

4. **Esc-to-dismiss (MINOR fix).** Today the SwiftUI sheets wire only Return; verify whether they dismiss on Esc and match it (likely add `cancelOperation(_:)` → `onDismiss`). Keep `viewWillDisappear`/`viewDidDisappear` side-effect-free so a sheet dismissed inside the swap's disabled `CATransaction` doesn't run layout/async work mid-swap.

5. **Localization (MAJOR fix).** `"Done"` is **absent** from `Localizable.xcstrings` (it survived on the English fallback); add the key (+ zh-Hans) and use `NSButton(title: String(localized: "Done"))`. `DiffNSView`'s `"Copy"` is the same situation.

---

### 4.8 Shared surfaces (`BarSurfaceView`) + custom leaves

**Built:** one `BarSurfaceView` (NSGlassEffectView on macOS 26 wrapped in `#available`, `NSVisualEffectView` + continuous-rounded mask + 0.5pt `separatorColor` stroke + shadow on macOS 14/15), parameterized by `cornerRadius` (circle = `size/2` for the attach button), reused by the **input pill, chrome buttons, attach button** — **not** the permission card (§4.4-1). `ProgressRingLayer` and `TodoStatusGlyphLayer` per §4.2.

**Adversarial fixes folded in:**

- **`BarSurfaceView` publishes no intrinsic size (MAJOR fix).** Override `intrinsicContentSize → noIntrinsicMetric` both axes; it pins to its content's 4 edges and the **content** drives height (regime B). The shadow lives on a compositing wrapper **outside** the rounded clip. Use `NSVisualEffectView.maskImage` (resizable rounded-rect NSImage) for the corner clip — a `CAShapeLayer` mask on a vibrancy view's own layer is unreliable and can drop vibrancy. `viewDidChangeEffectiveAppearance` re-resolves material/stroke/shadow. The pill's `.clipShape` that clipped the completion popup + thumbnail strip to the rounded shape must be reproduced (a clip mask, not just material).
- **Liquid Glass fidelity is its own task.** Land a "good enough" `NSVisualEffectView` surface first and refine against a `*SnapshotTests` of the bar + buttons in both appearances; treat the macOS-26 `NSGlassEffectView` branch as best-effort polish. Material choice for `.thickMaterial`(dark)/`.bar`(light) → snapshot A/B (Decision D3).

---

## 5. Component mapping table

| SwiftUI type / file | AppKit replacement | Verdict |
|---|---|---|
| `ChatComposeHostRoot`, `ChatComposeStack`, `ChatRestingBar` | (none — folded into `present`/constraints) | **DELETE** |
| `InputBarChrome` | folded into `InputBarController` | **DELETE** |
| `InputBarView2` | `InputBarView` + `InputBarController` | **BUILD** |
| `InputTextView` (representable + Coordinator) | embed `InputNSTextView`/`InputTextScrollView` directly | **UNWRAP** |
| `InputNSTextView`, `InputTextScrollView`, `CompletionState`, `CompletionTriggerRule`, `CompletionItem` | — | **REUSE** |
| `CompletionListView` | `CompletionPopupView` + `CompletionRowView` + `CompletionListLayout` | **BUILD** |
| `AttachButton` | `AttachButtonView` | **BUILD** |
| `InputBarSessionChrome`, `BarChromeButton`, `PopoverList` | `ChromeRowView`, `ChromeButton`, `PopoverMenuViewController` | **BUILD** |
| `PermissionModePicker`/`ModelEffortPicker`/`ContextRingButton`/`BackgroundTaskButton`/`TodoButton` | per-picker `@MainActor` controllers (NSButton + NSPopover + native content VCs) | **BUILD** |
| `ProgressRingView`, `TodoStatusGlyph`, `ContextBreakdownView` bar | `ProgressRingLayer`, `TodoStatusGlyphLayer`, `ContextBarView` (CAShapeLayer/drawRect) | **BUILD** |
| `BackgroundTaskOutputStream`, `BackgroundTaskFormat`, `ModelStore`, `EffortDefaultStore`, `ContextUsage` math, `Session` accessors/setters | — | **REUSE** |
| `PassthroughHostingView`, `PermissionCardOverlay` | `PermissionCardLayerView` + `PermissionCardController` | **DELETE** / **BUILD** |
| `PermissionCardView`, `PermissionDecisionButton`, `PermissionCardSurface`, 12 per-kind bodies | AppKit `PermissionCardView` + custom `PermissionDecisionButton` + opaque surface view + body builders | **BUILD** |
| `decisionHandlers`, `PermissionRequest`/`Kind`/`Copy`/`SedEditParser`, per-kind data getters | — | **REUSE** |
| `PermissionAskUserQuestionCardBody` | `AskUserQuestionCardViewController` (+ row/header/other views); models → `AskUserQuestionModel.swift` | **BUILD** / **REUSE** (models) |
| `DiffView` (SwiftUI) + `DiffViewBridge` | embed `DiffNSView` directly | **UNWRAP** |
| `DiffNSView`, `DiffCore` (`DiffEngine`/`DiffColors`) | — (`DiffCore` also consumed by the live transcript) | **REUSE** / **KEEP-SHARED** |
| `BoundedHeightScrollView` | height-capped `NSScrollView` constraint | **DELETE** |
| `ComposeSessionView`, `DraftSessionLandingView`, `NewSessionConfigurator` (+ `PlusHover`/`ResumeRow` styles, `HideEnclosingScrollerWidth`) | `ComposeContentView`/`DraftLandingContentView`/`NewSessionConfiguratorViewController` | **BUILD** |
| `BranchPickerView` | `BranchPickerViewController` | **BUILD** |
| `DotGridBackground` (SwiftUI), compose `FadeScrim` | `DotGridView`, AppKit fade (reuse `TranscriptScrimView` family) | **BUILD** |
| `UserBubbleSheetView`, `ImagePreviewSheetView`, `InputBarView2.ImagePreviewView` | `TextScrollSheetViewController`, `ImagePreviewSheetViewController` (one shared preview) | **BUILD** |
| `Transcript2SheetPresenter` | edited `makeSheetWindow` (content-type swap) | **REUSE** (edited) |
| `BarSurfaceModifier`, `AttachButton.surface` glass | one `BarSurfaceView` (pill/chrome/attach only) | **BUILD** |
| `VisualEffectView` (representable), `SelectableText` | — | **DELETE** |
| `FolderFilterPickerView`, `SearchField`, `HoverCapsuleStyle`, `MountFillPaneHost`, `DetailContext`, `injectDetailEnvironment` | — (Archive depends) | **KEEP-SHARED** |
| `TranscriptScrimView`, `Components/Markdown/*` | — | **KEEP-SHARED** |

---

## 6. Components/ DELETE / KEEP / UNWRAP ledger

**DELETE (die with the SwiftUI chat page):**
- `PassthroughHostingView.swift` — replaced by `PermissionCardLayerView`; its only production consumer is the card host (+ the DEBUG `PermissionSessionDemoViewController`, ported in lockstep).
- `BoundedHeightScrollView.swift` — height-cap becomes an NSScrollView constraint.
- `ProgressRingView.swift` — replaced by `ProgressRingLayer`.
- `BarSurfaceModifier.swift` — replaced by `BarSurfaceView` (delete only after the chrome row + pill consume it; it currently backs `BarChromeButton` too).
- `VisualEffectView.swift` — **dead** (zero construction sites; real vibrancy uses raw `NSVisualEffectView`).
- `SelectableText.swift` — **DEAD, but VERIFY** before deleting: the two grep hits are an unrelated `hasSelectableText` on the selection coordinator, not construction sites (flagged for confirmation).
- `DotGridBackground.swift`, `BranchPickerView.swift` — die with the compose port. `FadeScrim.swift` dies only when `NewSessionConfigurator` is ported (its sole consumer).

**UNWRAP (keep the AppKit backing, drop the SwiftUI wrapper):**
- `InputTextView.swift` — keep `InputNSTextView`/`InputTextScrollView`, delete `TextInputView` + Coordinator (guards migrate to `InputBarController`).
- `DiffView.swift` — keep `DiffNSView`, delete the SwiftUI `DiffView` + `DiffViewBridge` (travels with the card port; `DiffNSView` is consumed only by `DiffView` + the three diff-family card bodies).

**KEEP-SHARED (Archive / transcript depend — must NOT be deleted by any chat-page PR):**
- `FolderFilterPickerView.swift` + `SearchField.swift` — `MainWindowController`'s Archive-filter toolbar hosts `FolderFilterPickerView` (SwiftUI `.popover` in `NSHostingView`); both share `SearchField`. **FLAG:** `BranchPickerView` also depends on `SearchField`, so deleting `BranchPickerView` does not free `SearchField`.
- `HoverCapsuleStyle.swift` — shared with Archive.
- `DiffCore.swift` (`DiffEngine.computeHunks`, `DiffColors`) — the **live transcript** (`DiffLayout`/`DiffBlock`/`Block.swift`) consumes it; deleting it breaks file-edit rendering. **High-severity sweep hazard.**
- `MountFillPaneHost` + `DetailContext` + `injectDetailEnvironment` — Archive (+ DEBUG demo) depend; only chat/compose/draft call sites switch to direct property passing.
- `TranscriptScrimView.swift`, `Components/Markdown/*` — transcript pipeline.

---

## 7. Phasing / sequencing

Each phase keeps the app **buildable** (filesystem-synced project; no `project.pbxproj` edits) and green on `make test-unit`. Migrated test files land in the **same** phase as the type they reference (the test target must compile).

**Phase 0 — `BarSurfaceView` + custom-drawing leaves (shared dependency).** Build `BarSurfaceView` (glass + fallback, `noIntrinsicMetric`, appearance/Retina handling), `ProgressRingLayer`, `TodoStatusGlyphLayer`, `ContextBarView` as standalone components with their own `*SnapshotTests`. No production wiring yet. *Independently shippable; unblocks Phases 1–2.*

**Phase 1 — Input bar + completion + chrome row.** `InputBarController`/`InputBarView` (text core unwrapped, attachments, send/stop, attach button), `CompletionPopupView` (co-delivered — completion is non-landable alone), `ChromeRowView` + 5 pickers. `ChatSessionViewController.present(sessionId:)` calls `inputBarController.rebind(sessionId:)`; `restingBarHost` hosts `inputBarController.view` (regime-B constraints preserved). Collapse layers 1–4. Migrate `InputBarSnapshotTests`, `CompletionListSnapshotTests`, `ChatComposeStackRoutingTests` (retarget to `present` routing or delete with justification), confirm `InputBarLabelsTests` unaffected. *Depends on Phase 0. The largest phase; the central deliverable.*

**Phase 2 — Permission card + AskUserQuestion.** `PermissionCardLayerView` + `PermissionCardController`, AppKit `PermissionCardView` + opaque surface + `PermissionDecisionButton` (shared) + 12 body builders, then the AskUserQuestion wizard (port **last** — the single hardest piece). Delete `PassthroughHostingView`; rewrite `DetailPaneTranscriptHitTestTests` (CI gate) + the DEBUG `PermissionSessionDemoViewController` in the same PR. Keep all 11 `*CardBodyTests` + `PermissionCardWiringTests` compiling (per-kind getter types preserved). *Depends on Phase 1 (shares `PermissionDecisionButton`, the card host responder contract). Splits into 2a (chrome + diff/text families) and 2b (AskUserQuestion).*

**Phase 3 — Transcript sheets.** Port `UserBubbleSheetView`/`ImagePreviewSheetView` → VCs, reconcile `InputBarView2`'s preview into the shared `ImagePreviewSheetViewController` (behind the bar's owned presenter), flip `Transcript2SheetPresenter.makeSheetWindow`. Keep `Transcript2SheetPresenterLifetimeTests` green; migrate the affected `*SnapshotTests`. *Small; can run in parallel with Phase 2.*

**Phase 4 — Compose / draft / new-session.** De-SwiftUI both VCs (regime-A via constraint topology), `NewSessionConfiguratorViewController`, `BranchPickerViewController`, `DotGridView`, AppKit recents fade. Delete `ComposeSessionView`/`DraftSessionLandingView`/`NewSessionConfigurator`/`BranchPickerView`/`DotGridBackground`/compose-`FadeScrim` usage (precisely — keep `SearchField`/`FolderFilterPickerView`). Update `DetailRouterLayoutDiagnosticsTests`/`AppKitSwiftUIBoundaryTests` expectations; migrate `NewSessionConfiguratorSnapshotTests`. *Lowest-traffic tail; depends on Phase 1 (embeds `InputBarController`). Separate, later PR.*

**Phase 5 — final sweep.** Delete `VisualEffectView`, `SelectableText` (after verification), `BarSurfaceModifier`, `BoundedHeightScrollView`, `ProgressRingView`, the SwiftUI `DiffView`/`DiffViewBridge`, `FadeScrim`. Grep to confirm only Archive references the KEEP-SHARED set. Bump `.github/cache-salt` if stale `.swiftmodule` link errors appear.

---

## 8. Risk register (consolidated, severity-ranked)

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R1 | **Regime-A `fittingSize` leak / window collapse** — inner card/wizard `@required` min-size propagates to a 4-edge-pinned root and re-trips `AppKitSwiftUIBoundaryTests`/`DetailRouterLayoutDiagnosticsTests` (`fittingSize.height ≤ 1`). `sizingOptions=[]` does NOT carry to a pure-AppKit child. | **High** | Root overrides `intrinsicContentSize = .zero`; band on inner subview at non-required priority + `==ideal @defaultLow` + `<=max @required`; bar surface + completion popup publish `noIntrinsicMetric`. Update the two diagnostic tests; add wizard-grow + window-resize(880) layout tests. |
| R2 | **`DiffCore` sweep hazard** — a "delete chat SwiftUI" sweep removes `DiffCore`, breaking live transcript diffs. | **High** | Ledger pins `DiffCore` KEEP-SHARED (transcript consumer). Only `DiffView`/`DiffViewBridge` (SwiftUI) die. Grep before deleting. |
| R3 | **Liquid Glass AppKit backing** — `NSGlassEffectView` (26) sparse API; `NSVisualEffectView` (14/15) material/clip/shadow approximate; vibrancy corner-mask + shadow-outside-clip are sharp edges. | **High** | Phase 0 standalone `BarSurfaceView` with snapshots both appearances; `maskImage` for clip; shadow on a compositing wrapper; `NSGlassEffectView` best-effort. |
| R4 | **Focus / first-responder over a click-through overlay** — Esc/Enter were focus-independent in SwiftUI; AppKit `cancelOperation`/keyEquivalent need a responder, and the input bar re-asserts its own focus async. | **High** | Wizard mounts → drive input-bar focus false synchronously, then wizard root `acceptsFirstResponder` + `makeFirstResponder` window-gated; `cancelOperation`→cancel; single `confirm()`; restore focus on dismiss. Logic test fires Esc/Return. |
| R5 | **Orphaned input-bar preview sheet** — free-hand `beginSheet` survives bar teardown and wedges the window. | **High** | Owned presenter dismissed in `prepareForRemoval`/`stop()`, idempotent, window-guarded. |
| R6 | **Scrim-cutout coordinate base/phase** — wrong `convert(from:)` anchor (bar nested in the controller view) punches the gradient hole at the wrong place; reading off a keystroke uses stale frames. | **Medium** | Report attach/pill frames converted to `inputBarController.view`; chat VC converts from that exact view; recompute in `layout()` post-`super.layout()`, independent of popup state. Logic test pins rects + asserts popup-open/close stability. |
| R7 | **Nested `intrinsicContentSize`** — text-grow invalidates the scroll view's intrinsic size, not the bar's; missed re-sum clips/doesn't grow. | **Medium** | `onIntrinsicHeightChanged` from `InputTextScrollView` → single `relayout()` funnel; multi-line `fittingSize` tracking test. |
| R8 | **AskUserQuestion wizard breadth** — multi-step state, three-responder focus, Other-field expand/collapse, Esc swallowing, back-nav rehydration. | **Medium** | Dedicated VC, plain-property state machine, synchronous focus moves, `goBack` lifted verbatim + driven by public action seams. Port last. |
| R9 | **Write-back side effects re-entrancy** — `backfillModelIfNeeded`/`seedFromDefaultsIfNeeded` are writes, not display updates; collapsing into a display re-arm loop can loop/double-apply effort. | **Medium** | Run as one-shot guards on rebind + the specific `.task(id:)` transitions; idempotent guard re-checked post-write. CI test: backfill-once. |
| R10 | **`applyProbeBindings` + stale-branch reconcile omitted** — folder-switch reintroduces stale worktree-toggle/branch. | **Medium** | Port `applyProbeBindings` synchronously after `probe.refresh()`; keep post-`loadHeavy` stale-branch validation. |
| R11 | **Reactive list refresh** — `recents.entries`/`manager.records` don't reload without explicit observation; `+`-added folder invisible. | **Medium** | Self-re-arming `withObservationTracking` → `reloadData`; lazy first read (TCC deferral); `insertRows(0)`+`scrollRowToVisible(0)` on prepend. |
| R12 | **Completion key routing + provider-result tick** — observed re-arm is one tick late for synchronous nav/dismiss; double-trigger on splice. | **Medium** | Imperative inline `refresh()`+`relayout()` on nav/confirm; observe `items` only; `isApplyingProgrammaticText` guard around splice. |
| R13 | **NSPopover steals key-window vs IME** — picker open strands marked text / drops responder restore. | **Medium** | Capture/restore firstResponder; `discardMarkedText` before show; `popoverDidClose` restore. |
| R14 | **Dark/light + accent re-resolution** — `CALayer.cgColor` freezes on appearance flip. | **Medium** | `viewDidChangeEffectiveAppearance` re-resolves all dynamic cgColors (wrapped in disabled `CATransaction`); prefer semantic `NSColor` in `draw`. |
| R15 | **`submitEnabled` not reactive (compose)** | **Medium** | Observe `session.cwd`; `sendStopButton.updateEnabled()`. CI test. |
| R16 | **Sheet/card animation inside the swap's disabled `CATransaction`** — appear/dismiss snaps or composites under the disabled txn. | **Low** | Drive from the observation's async beforeWaiting hop, outside the swap txn; sheet VC disappear paths side-effect-free. |
| R17 | **Timer/rotation/output-stream teardown leaks** — `.common`-mode timer freezes during scroll; repeatForever animation / `NSEvent` monitor / `DispatchSource` tail outlive their host. | **Low** | `.common` mode; start/stop from `NSPopoverDelegate`; key animation on resolved state; `BackgroundTaskOutputStream.stop()` + monitor removal in teardown. |
| R18 | **even-odd glyph regression** — `CAShapeLayer` defaults `.nonZero` → solid disc. | **Low** | Set `fillRule = .evenOdd` explicitly; snapshot the `.completed` glyph. |
| R19 | **Image-preview thumbnail over-upscale / envelope mismatch** | **Low** | Per-caller `preferredContentSize`; high interpolation; same thumbnail source as today. |

---

## 9. Test strategy

No test-only production seams. Drive the public surface (controller `present`/`rebind`/`handleSend`, bridge events, `CompletionState` fields, a fed `PermissionRequest`) and assert observable results. **CI gates are logic tests** (`*SnapshotTests` are compiled but skipped on CI — they are review-only visual self-checks, never the regression gate).

**Seams to drive, per subsystem:**
- **Architecture / spine:** `ChatSessionViewController.present(sessionId:)` — `present(A)` with a pending permission, `present(B)`, assert A's card gone and only B's renders; assert `inputBarController` constraints identical before/after `rebind`.
- **Input bar:** `InputBarController` — feed text → assert `canSend`; `handleSend` → assert `inputDraftStore.clear` ran before `onSubmit`; flip `session.cwd` → assert `canSend`; type multi-line → assert `restingBarHost.fittingSize.height` tracks; pin reported attach/pill rects + assert stable across popup open/close; fire Return at the text sheet → assert `onDismiss`.
- **Chrome / pickers:** arranged-subview `isHidden` on `tasks`/`todos` empty↔nonempty + bar-band-height invariant; backfill-once / seed-once after `availableModels` transitions; `.ultracode` not persisted to `EffortDefaultStore`; `requestContextUsage` once-per-open (counted via a fake); firstResponder restored across popover open/close.
- **Completion:** `CompletionListLayout.listHeight(...)` pixel-exact across the 4 branches; `reconcile` mapping (`numberOfRows == items.count`, branch selection); confirm an @file item → `CompletionState` inactive; flip `items` off-main → reconcile fires.
- **Permission card:** keep `PermissionCardWiringTests` + 11 `*CardBodyTests` compiling (per-kind getter types + initializers preserved; `decisionHandlers` factory renamed at most); a non-snapshot measurement probe through `present(sessionId:)` with a pre-seeded `pendingPermissions` for the missed-first-edge, cross-session synchronous teardown, and hit-through-during-dismiss; rewrite `DetailPaneTranscriptHitTestTests` (CI gate) to walk to `PermissionCardLayerView`.
- **AskUserQuestion:** migrate `PermissionAskUserQuestionCardBodyTests` decoders to `AskUserQuestionModel`; add `goBack`/`composedAnswer`/`commitAnswer`/`confirmEnabled` logic tests via public action entry points; Esc-over-focused-input-bar test; engage-Other-then-drain-a-tick focus test; wizard-grow `fittingSize` invariant.
- **Compose / draft:** keep `DetailRouterDraftRoutingTests` / `ChatComposeStackRoutingTests` green; update `DetailRouterLayoutDiagnosticsTests`/`AppKitSwiftUIBoundaryTests` `fittingSize ≤ 1` expectations to the de-SwiftUI'd roots; window-resize(880) smoke; drive `present(sessionId:)` with two draft ids → labels re-bind + input bar re-keys; flip `session.cwd` → `canSend`.
- **Sheets:** keep `Transcript2SheetPresenterLifetimeTests` green (content-type swap must not break the retain-cycle dealloc assertion); Return/Esc/click dismiss; sheet-open → host teardown → assert dismissed (no orphan).

**Snapshots (review-only, opt-in):** migrate every existing `*SnapshotTests` that constructs a deleted SwiftUI struct (`InputBarSnapshotTests`, `CompletionListSnapshotTests`, `PermissionCardSnapshotTests`, `DiffViewSnapshotTests`, `TodoStatusGlyphSnapshotTests`, `NewSessionConfiguratorSnapshotTests`) to render the AppKit replacement via `ViewSnapshot.renderViewController` (wrap a bare NSView in a throwaway VC) — these are compiled, so they break the build if left referencing deleted types. Reserve snapshots for pure visual fidelity (glass surface, glyph antialiasing).

---

## 10. Decisions for the human

- **D1 — Settings/About.** They are separate SwiftUI `Window` scenes, not the transcript page, and carry no window-collapse hazard (window-content regime). **Recommend: keep SwiftUI.** Porting them is pure cost toward no stated goal. Flagged because "SwiftUI only in Archive" *read literally* would include them — if that's the intent, schedule them as a separate, lowest-priority follow-up after Phases 0–5.
- **D2 — `sendKeyBehavior`.** Confirmed **vestigial for chat**: `InputBarView2` never passes it, so chat is always `.commandEnter` regardless of the Settings picker (`InputNSTextView.sendKeyBehavior` defaults to `.commandEnter`). The port rewires this exact seam. **Recommend: wire it** — `InputBarController` reads `UserDefaults.standard.string(forKey: "sendKeyBehavior")` and observes `NSUserDefaultsDidChange`, setting `textView.sendKeyBehavior` — so the Settings picker finally works in chat. (Alternative: preserve `.commandEnter`-only and document the picker as compose-only.) Either way, decide explicitly so the port doesn't *silently* change send-key behavior.
- **D3 — macOS 14/15 `NSVisualEffectView.Material` for `BarSurfaceView`** (approximating SwiftUI `.thickMaterial` dark / `.bar` light). Candidates: `.underWindowBackground` / `.menu` / `.headerView`. **Recommend: defer to the Phase-0 snapshot A/B** and pick by eye.
- **D4 — live `hasMarkedText()` into `checkTrigger`.** Today it's hardcoded `false`; passing the live value correctly suppresses trigger detection during IME composition — a **behavior change**, not a pure port. **Recommend: keep the change but ship it with a CJK logic test and a PR note** (don't smuggle it as a free win). Alternative: keep `false` for a true no-op and file the IME fix separately.
- **D5 — permission-card appear/dismiss animation fidelity.** Exact `.scale(0.96, anchor:.bottom)+.opacity` needs `anchorPoint`/`position` juggling that fights constraint-driven layout. **Recommend: opacity + small center scale** (or a transform-only non-constraint wrapper) to avoid a post-animation position jump. Confirm the bottom-anchored scale isn't load-bearing.
- **D6 — focus destination on wizard/card dismiss.** **Recommend: the transcript** (`makeFirstResponder(nil)`), matching today, rather than the input bar.
- **D7 — worktree control rendering.** `NSPopUpButton` gives native checkmarks but renders bordered; `NSButton + NSMenu` with manual `.state` matches the borderless capsule look. Cosmetic only (both must write `draft.setWorktree`). **Recommend: `NSButton + NSMenu`** for visual parity; confirm with a snapshot.
- **D8 — `SelectableText` deletion.** Recon says dead (grep hits are an unrelated `hasSelectableText` property). **Recommend: delete after a final grep confirms zero construction sites** in Phase 5.
