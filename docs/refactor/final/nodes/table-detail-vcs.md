# Ownership table — Detail VCs, transcript swap, hosts/scrims

Scope: the chat / compose / draft-landing / archive detail children, the
target-new `TranscriptSwapCoordinator`, and the scrim / host / scrim-overlay /
sheet-presenter leaf classes around them. Rows are the **TARGET** design
(REFACTOR-PLAN §5/§8); the as-is is noted parenthetically where it differs.
PR labels are stable mnemonics mapped to §9 phases (PRPlan finalizes numbers):
`PR-A*` = Phase A (DI/dead-code/forwarder), `PR-B*` = Phase B (card overlay,
mountFillPaneHost+un-erase, DetailContext, naming), `PR-C*` = Phase C (sidebar),
`PR-D*` = Phase D (transcript swap).

FACT citations are `file:line` against this worktree. INFERENCE = judgment.

## Table (fixed schema)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `ChatSessionViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild` (FACT `DetailRouterViewController.swift:365`) | router; same-kind reuse, cross-kind rebuild (FACT REFACTOR-PLAN §3.2) | ctor-injected `DetailContext` (TARGET; as-is 7-arg bag, FACT `ChatSessionViewController.swift:127`) | imperative controller call (router→`present(sessionId:)`, FACT `:252`); `model.select` indirectly via injected `onSubmit`/`onBuiltinCommand` closures | — (container VC; hosts B + A overlays) | PR-B1 (card host added), PR-B3 (DetailContext), PR-D1 (swap split) | ✓ (TARGET; after PR-D1 sheds the swap state machine. As-is = god-VC mixing "what to show" + attach/swap, P5) |
| `TranscriptSwapCoordinator` ★NEW | AppKit-coordinator | AK-NSObject | `ChatSessionViewController` (PR-D1, INFERENCE per §5/§8.P5) | the chat VC; lifetime of the VC | ctor-injected (controller-per-session + `topScrim`/insert-closure handed in, FACT §8.P5 seam (i)) | imperative controller call (`Transcript2Controller.apply/scrollToTail/setLoading/setTurnUsage`) | — (owns per-attach hosts but is not itself a hosting boundary) | PR-D1 | ✓ (TARGET, highest-risk; conformant only if §8.P5 seam contract is honored — single `currentSession` owner, z-anchor `.below topScrim`, cutout coord transform survive the split. INFERENCE: clean placement is conditional on the seam, hence flagged in defects below) |
| `transcriptScroll: Transcript2ScrollView` | Per-attach | AK-View | `TranscriptScrollViewFactory.make` (FACT `ChatSessionViewController.swift:344`) | swap coordinator (TARGET; as-is chat VC); rebuilt per session attach | n/a (driven imperatively) | imperative controller call (bound to `session.controller` via `bindData`) | — (4-edge-pinned bare scroll view, not a SwiftUI host) | PR-D1 (moves into coordinator) | ✓ |
| `transcriptSheetPresenter: Transcript2SheetPresenter` | Per-attach | AK-NSObject | `ChatSessionViewController.attachSession` (FACT `:405`; TARGET → coordinator) | swap coordinator (TARGET; as-is chat VC); per-attach, `stop()` on swap | `@Observable` pull (`withObservationTracking` on `controller.pendingUserBubbleSheet`/`pendingImagePreview`, FACT `Transcript2SheetPresenter.swift:51`) | imperative controller call (`view.window?.beginSheet`, FACT `:192` per BOUNDARY-SPEC §1 D-ref) | D (modal-sheet host: `NSHostingController(UserBubble/ImagePreview)` → `beginSheet`, default sizingOptions, FACT BOUNDARY-SPEC §1 row D) | PR-D1 (moves into coordinator) | ✓ |
| `topScrim: TranscriptTopScrimView` | Per-attach | AK-View | `ChatSessionViewController.loadView` (FACT `:156`) | chat VC; lifetime of VC (mounted once) | n/a | imperative controller call (`window.performDrag`/`performZoom`, FACT `TranscriptScrimView.swift:183-191`) | — (pure `NSView`, deliberately not an `NSHostingView` so it registers no cursor rect, FACT `:88-91`) | unchanged (z-anchor stays in VC, fed to coordinator, §8.P5 seam (i)) | ✓ |
| `bottomScrim: TranscriptBottomScrimView` | Per-attach | AK-View | `ChatSessionViewController.loadView` (FACT `:160`) | chat VC; lifetime of VC | ctor/`didSet` (rects pushed via `applyScrimCutouts`, FACT `:234`) | none (decorative; `hitTest→nil`, FACT `TranscriptScrimView.swift:61`) | — (pure `NSView`, hitTest passthrough + even-odd cutouts) | unchanged | ✓ |
| `TranscriptScrimView` (base) | Pure-value | AK-View | n/a (base class, subclassed by top/bottom) | n/a | n/a | none (decorative, `hitTest→nil`) | — | unchanged (doc drift: `Content/Chat/CLAUDE.md` calls top scrim by base name, fixed P12) | ✓ |
| `restingBarHost: NSHostingView<ChatComposeStack>` ★RENAMED ★UNERASED | Per-attach | AK-View | `ChatSessionViewController.loadView` (FACT `:164`, as-is `composeOrBarHost`) | chat VC; lifetime of VC | n/a (host); content reads `@Observable` | none (host shell; content emits via injected closures) | B (centered, width-capped, bottom-anchored component; `[.intrinsicContentSize]` + centerX + width≤cap(req) + width==cap(@high) + leading≥ + bottom==, FACT `:172,205-210`; BOUNDARY-SPEC §1 row B, §3 "optimal") | PR-B1 (card moves out), PR-B4 (rename + un-erase `AnyView`) | ✓ (TARGET; as-is name `composeOrBarHost` is distorted + `AnyView`-erased, P12) |
| `ChatComposeStack` | SwiftUI-view | SU-View | `restingBarHost` root (FACT `:164`, `:548`) | host; per-attach | `@Observable` pull (`@Bindable model`, FACT `:609`) | injected closure (`onSubmit`/`onAttachRect`/`onPillRect`/`onBuiltinCommand`, FACT `:610-615`) | — (inside regime-B host) | PR-B4 (un-erased; card child removed §7) | ✓ |
| `ChatRestingBar` | SwiftUI-view | SU-View | `ChatComposeStack.body` `.id(sid)` (FACT `:662`) | view identity (`sid`) | `@Observable` pull (`session.*`) | `Session` method (e.g. `session.respond` was here; moves to overlay §7) + injected closures | — | PR-B1 (★CHANGED: card ZStack + body `.animation` removed, collapses to "just the bar", §7.3) | ✓ (TARGET; as-is hosts the card `ZStack(alignment:.bottom)` reporting UNION height → bar-host coupling, FACT `InputBarChrome.swift:126,166`, P-headline) |
| `permissionCardHost: PassthroughHostingView<PermissionCardOverlay>` ★NEW | Per-attach | AK-View | `ChatSessionViewController.loadView` (PR-B1, after `restingBarHost` for z-order, §7.4 M5) | chat VC; lifetime of VC | n/a (host); content reads `@Observable` | none (host shell) | A-hybrid: regime-A sizing (`sizingOptions = []` + 4-edge pin → publishes no fittingSize) + passthrough hit-testing (`hitTest→nil` + cursor/tracking-rect suppression, §7.4 M2/M4; §7.8 calls this "regime-A sizing + passthrough hit-testing", explicitly NOT B″) | PR-B1 | ✓ (TARGET; the hybrid is documented & test-backed — `DetailPaneTranscriptHitTestTests`. INFERENCE: conformant because §7.8 reconciles it to regime A; would be ✗ if mis-filed as B″) |
| `PassthroughHostingView` ★NEW (re-introduced) | Per-attach | AK-View | n/a (subclass type; instance = `permissionCardHost`) | n/a | n/a | none (overrides `hitTest`→`nil` off-card + empty `resetCursorRects`, §7.4 M2/M4) | — (it IS the host backing class for regime-A-hybrid) | PR-B1 (NB: only a tombstone comment exists today, FACT `DetailRouterViewController.swift:27` — re-add, do not reuse old) | ✓ |
| `PermissionCardOverlay` ★NEW | SwiftUI-view | SU-View | `permissionCardHost` root (PR-B1) | host; lifetime of VC | `@Observable` pull (`session.pendingPermissions.first`, routed by `model.selection` + `.id(sid)`, §7.3 R4) | `Session` method (4 decision closures → `session.respond(...)`, moved verbatim from `ChatRestingBar`, FACT `InputBarChrome.swift:143-162`) | — (constant-size content inside regime-A-hybrid host; bottom inset 36 = `chatBottomInset`, §7.4 M1) | PR-B1 | ✓ (TARGET; backed by new `PermissionCardWiringTests` for closure→`respond` routing, §7.7 R5) |
| `Transcript2SheetPresenter` | Per-attach | AK-NSObject | (duplicate of row above — single canonical row) | — | — | — | D | PR-D1 | ✓ (see per-attach row above) |
| `ComposeSessionViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild` (FACT `:375`) | router; mounted only for `.newSession` | ctor-injected `DetailContext` (TARGET; as-is 7-arg, FACT `ComposeSessionViewController.swift:44`) | `model.select` (via `onResumeSession`, FACT `:96`) + injected `onSubmit` | A (fill-a-pane; `NSHostingController`, `sizingOptions = []` + 4-edge pin, FACT `:115-124`; BOUNDARY-SPEC §1 row A) | PR-B2 (mountFillPaneHost + un-erase), PR-B3 (DetailContext) | ✓ |
| `ComposeSessionView` | SwiftUI-view | SU-View | `ComposeSessionViewController.viewDidLoad` host root (FACT `:82`) | host; lifetime of VC | `@Observable` pull (`@Environment SessionManager`, draft config bindings, FACT `:165,210`) | injected closure (`onSubmit`/`onResumeSession`) + `session.draft?` setters via bindings | — (inside regime-A host) | PR-B2 (un-erased from `AnyView`) | ✓ |
| `DraftSessionLandingViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild` (FACT `:385`) | router; mounted for `.session(_)` whose `Session` is `.draft` | ctor-injected `DetailContext` (TARGET; as-is 7-arg, FACT `DraftSessionLandingViewController.swift:40`) | imperative controller call (router→`present(sessionId:)`, FACT `:76`) + injected `onSubmit`/`onBuiltinCommand` | A (fill-a-pane; `NSHostingController`, `sizingOptions = []` + 4-edge pin, FACT `:136-145`; BOUNDARY-SPEC §1 row A) | PR-B2 (mountFillPaneHost + un-erase), PR-B3 (DetailContext) | ✓ |
| `DraftSessionLandingView` | SwiftUI-view | SU-View | `DraftSessionLandingViewController.mountHost` root (FACT `:102`) | host; rebuilt on `boundSessionId` change | `@Observable` pull (`@Environment SessionManager`, FACT `:163,166`) | injected closure (`onSubmit`/`onBuiltinCommand`) | — (inside regime-A host) | PR-B2 (un-erased) | ✓ |
| `ArchiveViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild` (FACT `:395`) | router; mounted only for `.archive` | ctor-injected `DetailContext` (TARGET; as-is 7-arg, FACT `ArchiveViewController.swift:31`) | `model.select` (via `onUnarchive`, FACT `:71-73`) + two-way `@Bindable` on `model.archiveSelectedFolderPath` (FACT `:63-66`) | A (fill-a-pane; `NSHostingController`, `sizingOptions = []` + 4-edge pin, FACT `:102-111`; BOUNDARY-SPEC §1 row A; binding is height-neutral, §2.2/§4) | PR-B2 (mountFillPaneHost + un-erase), PR-B3 (DetailContext) | ✓ |
| `ArchiveView` | SwiftUI-view | SU-View | `ArchiveViewController.viewDidLoad` host root (FACT `:68`) | host; lifetime of VC | `@Observable` pull + two-way `Binding<String?>` (folder filter, FACT `:63`) | `model.select` (via `onUnarchive`) + binding write to `model.archiveSelectedFolderPath` | — (inside regime-A host) | PR-B2 (un-erased) | ✓ |
| `mountFillPaneHost(_:in:)` helper ★NEW | DI-context | translator | n/a (free helper called by the 3 fill-pane VCs) | call-site | n/a | none (returns/pins a 4-edge `[]` host) | A (encodes regime-A: `sizingOptions = []` + 4-edge pin; canonicalizes the Archive/Compose/DraftLanding triple, FACT REFACTOR-PLAN §8 C9 / §9 step 6) | PR-B2 | ✓ (TARGET; chat's regime-B `restingBarHost` is deliberately NOT folded in, §10 rule 6) |
| `DetailContext` ★NEW | DI-context | value/MDL | `MainSplitViewController` (TARGET, §5 ★CHANGED-P2) | window shell; one value threaded through `makeChild` | n/a (it IS the carried bag: `model` + consumed services) | ctor-injected into each detail VC | — | PR-B3 | ✓ (TARGET; replaces 7-arg fan-out + 5 duplicated `.environment` blocks, P2; consumed set = `{SessionManager, RecentProjectsStore, InputDraftStore, syntaxEngine}` after dead `notifications`/`searchBus` injections removed, P1) |
| `injectDetailEnvironment(_:)` View modifier ★NEW | DI-context | translator | n/a (SwiftUI `View` extension) | call-site | n/a | `@Observable` write (`.environment(...)` of the 4 consumed services) | — | PR-B3 | ✓ (TARGET; replaces 5 copies; landing requires un-erase first so a missed injection becomes a compile error, §9 step 6→7 ordering) |

## Non-conformant / defects (design flags)

All scoped classes place cleanly in the TARGET design. There are **no
unplaceable classes** — but three rows carry conditional / latent defects worth
surfacing, plus the as-is god-VC that the TARGET fixes.

1. **`ChatSessionViewController` (AS-IS only) — dual responsibility (P5).** As
   shipped, the VC mixes "what to show" (scrim, bar host, focus, turn-usage,
   running-obs) with the transcript-swap state machine (attach orchestration,
   same-session crossfade, `fadingOutTranscript` parking, the §2.19 single-width
   contract, chat-I3/I4/I5/I14). That is two layers in one class — a genuine
   dual-layer defect. TARGET resolves it by extracting `TranscriptSwapCoordinator`
   (PR-D1). Conformant ✓ only **after** the split; flagged here as the reason the
   split exists. (FACT `ChatSessionViewController.swift:284-544`.)

2. **`TranscriptSwapCoordinator` (TARGET) — clean placement is conditional on
   the seam contract (§8.P5).** The extraction is the highest-risk item. It
   places cleanly **only if** the cross-VC seam is honored: (i) a single owner of
   `currentSession` (both the turn-usage sink at `:441-445` and the running-obs at
   `:540` compare `currentSession === session`; duplicating the field across VC +
   coordinator would desync mid-crossfade and let a stale sink call
   `setTurnUsage`/`setLoading` on the wrong controller); (ii) z-anchor stays
   `.below topScrim` with the scrim owned by the VC and handed in (FACT `:356`);
   (iii) the `applyScrimCutouts` coord transform (`bottomScrim.convert(_:from: composeOrBarHost)`, FACT `:235`) keeps working when the scroll view migrates
   but the scrim/bar host do not. If any seam is violated the class straddles two
   owners → ambiguous owner. The two merge gates cover §2.19 attach but **not**
   the same-session-crossfade finish-before-attach ordering (`:309`,
   `:502-509`) — that path needs added coverage or explicit manual-only
   acceptance (§9.1, §8.P5 R6). INFERENCE.

3. **`permissionCardHost` / `PassthroughHostingView` (TARGET) — host regime is a
   documented hybrid, not a clean BOUNDARY-SPEC bucket.** It is **regime-A sizing
   + passthrough hit-testing**, not regime B″. The distinction is load-bearing:
   B″ floating overlays use *default* sizingOptions and must pin position-only (a
   4-edge pin would leak their fittingSize into the split, BOUNDARY-SPEC §1 row
   B″), whereas this host pins all 4 edges under `sizingOptions = []` so it
   publishes **no** fittingSize (collapse mechanism root-cut, §2.2) and adds
   `hitTest→nil` + cursor/tracking-rect suppression (§7.4 M2/M4) so it does not
   shadow the transcript I-beam. §7.8 explicitly reconciles this to regime A.
   Conformant ✓ as filed, but it is the **one host in scope a reader must not
   pattern-match to the table by name** — mis-filing it as B″ (position-only pin)
   would reintroduce either window collapse or an unclickable transcript. Backed
   by `DetailPaneTranscriptHitTestTests`. INFERENCE/FACT mix.

### Notes on clean rows worth recording

- The three fill-pane children (`Archive`/`Compose`/`DraftLanding`) are
  regime-A and their `[]`+4-edge pattern is canonicalized by `mountFillPaneHost`
  (PR-B2). The chat `restingBarHost` is regime-B and is deliberately **excluded**
  from that helper (§10 rule 6) — keeping the one asymmetric host explicit is
  intentional, not a defect.
- All scrims are pure `NSView` (never `NSHostingView`) by design so they register
  no cursor rect — this is the same root reason `PassthroughHostingView` must
  suppress cursor rects (§7.4 M4). Not a hosting boundary, host regime "—".
- `Transcript2SheetPresenter` is the only regime-D (modal sheet) instance in
  scope; its `beginSheet` host is by-design and untested-by-design
  (BOUNDARY-SPEC §6).
