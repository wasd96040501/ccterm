# Survey: Input bar composition (text field, chrome, attach, new-session configurator)

Scope: the SwiftUI input-bar stack and its AppKit host seams. Files surveyed:

- `macos/ccterm/Content/Chat/InputBarView2.swift` — the pure-UI pill.
- `macos/ccterm/Content/Chat/InputBarChrome.swift` — per-session wrapper (`InputBarChrome`) + chat-mode resting region (`ChatRestingBar`).
- `macos/ccterm/Content/Chat/AttachButton.swift` — standalone `+` button.
- `macos/ccterm/Content/Chat/NewSessionConfigurator.swift` — compose card.
- `macos/ccterm/Content/Chat/InputBarControls/InputBarSessionChrome.swift` — the footer chrome row.
- `macos/ccterm/Content/Chat/InputBarControls/BarChromeButton.swift` — shared pill-style trigger button.

Adjacent files read for boundary facts (not in primary scope, cited where load-bearing): `App/AppKit/ChatSessionViewController.swift`, `Content/Chat/ComposeSessionViewController.swift` (+ `ComposeSessionView`), `Services/Draft/InputDraftStore.swift`, `App/AppKit/MainSelectionModel.swift`, `Content/Chat/SessionInputSubmit.swift`, `Components/TranscriptScrimView.swift`, `Components/InputTextView.swift` (`TextInputView`), `Components/BarSurfaceModifier.swift`, `Content/Chat/DraftSessionLandingViewController.swift`.

FACT = present in code (cited). INFERENCE = my read, labeled.

---

## 1. Component / type inventory

| Type | Kind | One-line responsibility | file:line |
|---|---|---|---|
| `InputBarView2` | SwiftUI `View` | The "pure UI" pill: text field + send/stop + attach + thumbnail strip + drop + completion popup. No session handle. | `InputBarView2.swift:21` |
| `InputBarView2.Attachment` | `struct` (Equatable, Identifiable) | One attached file or in-memory image (`.image(data,mediaType)` / `.file(path)`) + thumbnail + filename. | `InputBarView2.swift:55` |
| `InputBarView2.Attachment.Kind` | `enum` | Image-vs-file discriminator carried by an attachment. | `InputBarView2.swift:56` |
| `InputBarView2.Submission` | `struct` | Payload to `onSubmit`: `text` + `images` + `filePaths`. | `InputBarView2.swift:90` |
| `ReportFrame` | private SwiftUI `ViewModifier` | Centralized `.onGeometryChange` reporter for attach/pill rects; no-op when `coordSpace`/`action` nil. | `InputBarView2.swift:738` |
| `AttachmentCard<Content>` | private SwiftUI `View` | Wraps an attachment view with a hover-fade remove-X; owns its own `@State isHovered`. | `InputBarView2.swift:761` |
| `ImagePreviewView` | private SwiftUI `View` | Modal preview sheet for an attached image. | `InputBarView2.swift:790` |
| `PreviewImage` | private `struct` (Identifiable) | UUID-keyed wrapper for the `.sheet(item:)` preview payload. | `InputBarView2.swift:819` |
| `AttachButton` | SwiftUI `View` | `+` `Menu` → "Attach Image or File"; fires injected `onPick`; visual-only. | `AttachButton.swift:18` |
| `InputBarChrome` | SwiftUI `View` | Per-session wrapper: resolves `Session`, feeds `InputBarView2` its observed state, stacks `InputBarSessionChrome` below; owns the completion-prewarm `.task`. | `InputBarChrome.swift:12` |
| `ChatRestingBar` | SwiftUI `View` | Chat-mode resting region: `InputBarChrome` + floating `PermissionCardView` in a bottom-aligned `ZStack`; applies width caps + insets. | `InputBarChrome.swift:111` |
| `NewSessionConfigurator<InputBar>` | SwiftUI `View` (generic over the bar slot) | Compose card: recent-projects column + hero/meta/recents column + embedded `inputBar()` slot; git probe glue. | `NewSessionConfigurator.swift:28` |
| `PlusHoverButtonStyle` | private `ButtonStyle` | Hover/press background for the Projects header `+`. | `NewSessionConfigurator.swift:742` |
| `ResumeRowButtonStyle` | private `ButtonStyle` | Hover/press background for a recent-session row. | `NewSessionConfigurator.swift:761` |
| `HideEnclosingScrollerWidth` | private `NSViewRepresentable` | Suppresses the recents `List`'s scroller width / stale top inset (AppKit interop). | `NewSessionConfigurator.swift:781` |
| `InputBarSessionChrome` | SwiftUI `View` | Footer control row under the pill: `[Permission][BgTask][Todo] — [Model·Effort][ContextRing]`, inset to the pill's leading edge. | `InputBarSessionChrome.swift:13` |
| `BarChromeButton<Content>` | SwiftUI `View` | Shared 22pt pill-style trigger used by the permission / model·effort popovers. | `BarChromeButton.swift:12` |
| `BarSurfaceModifier` / `.barSurface(cornerRadius:)` | SwiftUI `ViewModifier` + `View` ext | Shared glass/material surface for pill + chrome buttons. | `BarSurfaceModifier.swift:22`, `:58` |
| `TextInputView` | `NSViewRepresentable` (wraps `InputNSTextView`) | The actual NSTextView the pill's text area hosts (cursor tracking, key interception, IME, auto-height). | `InputTextView.swift:6` |
| `CompletionViewModel` | `@Observable` (referenced) | Drives the completion popup; created once per `InputBarView2` (`@State`), rewired every render via `triggerContext`. | `InputBarView2.swift:167` |

Adjacent (boundary) types, for ownership context:

| Type | Kind | Role at this boundary | file:line |
|---|---|---|---|
| `ChatComposeStack` | SwiftUI `View` | The body hosted by the chat VC's bar host; routes `model.selection` → `ChatRestingBar` (chat) / `EmptyView`; declares the `detailCoordSpace`. | `ChatSessionViewController.swift:605` |
| `ChatSessionViewController` | `NSViewController` | Hosts `ChatComposeStack` in an `NSHostingView<AnyView>` (`.intrinsicContentSize`); stores `lastAttachRect`/`lastPillRect`; drives `bottomScrim` cutouts. | `ChatSessionViewController.swift:46` |
| `ComposeSessionViewController` / `ComposeSessionView` | `NSViewController` / SwiftUI `View` | Hosts `NewSessionConfigurator` (with `InputBarChrome` slot) in an `NSHostingController<AnyView>` (`sizingOptions = []`). | `ComposeSessionViewController.swift:28`, `:160` |
| `InputDraftStore` | `@Observable @MainActor` service | File-backed per-key draft persistence (`load`/`save`/`clear`, debounced). | `InputDraftStore.swift:12` |
| `MainSelectionModel` | `@Observable @MainActor` | Shared selection + `draftSessionId`; `select`/`promote`. | `MainSelectionModel.swift:35` |
| `TranscriptBottomScrimView` | `NSView` (`final class`) | The sole consumer of the attach/pill rects: punches even-odd cutouts. | `TranscriptScrimView.swift:110` |
| `submitSessionInput(...)` | free `@MainActor func` | Shared send handler for compose + chat; draft promotion. | `SessionInputSubmit.swift:16` |

---

## 2. Component tree (this area)

Two host paths converge on the same SwiftUI bar stack. AppKit nodes marked `[AK]`, SwiftUI `[SW]`, hosting bridges called out with `sizingOptions`.

### Path A — chat resting bar (`.session(_)`)

```
ChatSessionViewController.view (NSView)                                    [AK]
└── composeOrBarHost: NSHostingView<AnyView>   sizingOptions=[.intrinsicContentSize]   ── AK↔SW boundary
    └── ChatComposeStack                                                   [SW]   (declares .coordinateSpace "ChatSessionViewController.detail")
        └── ZStack { case .chat(sid) }                                     [SW]
            └── ChatRestingBar  .id(sid)                                   [SW]
                └── ZStack(alignment: .bottom)                            [SW]
                    ├── InputBarChrome (.frame minWidth..composeMaxWidth, .padding(.horizontal detailHorizontalInset))   [SW]
                    │   └── VStack(spacing: InputBarSessionChrome.barSpacing)                                            [SW]
                    │       ├── InputBarView2                              [SW]
                    │       │   └── HStack(alignment:.bottom)              [SW]
                    │       │       ├── AttachButton  .modifier(ReportFrame → onAttachRect)                              [SW]
                    │       │       └── pill          .modifier(ReportFrame → onPillRect)                                [SW]
                    │       │           └── VStack { CompletionListView? · thumbnailStrip? · HStack(textArea, sendOrStopButton) }
                    │       │               └── textArea → TextInputView   [SW→AK]  (NSViewRepresentable wrapping InputNSTextView)
                    │       └── InputBarSessionChrome                      [SW]
                    │           └── HStack { PermissionModePicker · BackgroundTaskButton · TodoButton · Spacer · ModelEffortPicker · ContextRingButton }
                    │               (each is a BarChromeButton-based popover trigger)
                    └── PermissionCardView?  (pending permission, .frame maxWidth BlockStyle.maxLayoutWidth)            [SW]
```

Sibling AppKit overlays in the same `view` (not part of the bar but cooperating with it): `topScrim: TranscriptTopScrimView` and `bottomScrim: TranscriptBottomScrimView` (`ChatSessionViewController.swift:92-93`), plus the `transcriptScroll` behind them. The bottom scrim consumes the rects the bar reports (§3).

### Path B — compose card (`.newSession`)

```
ComposeSessionViewController.view (NSView)                                 [AK]
└── host: NSHostingController<AnyView>   sizingOptions=[]                  ── AK↔SW boundary (full-bleed)
    └── ComposeSessionView                                                 [SW]   (declares same .coordinateSpace "ChatSessionViewController.detail")
        └── ZStack { DotGridBackground · NewSessionConfigurator }          [SW]
            └── NewSessionConfigurator<InputBarChrome>                     [SW]
                ├── projectsColumn (List of RecentProjectsStore.entries)   [SW]   (HideEnclosingScrollerWidth → NSScrollView tweak [AK])
                └── mainColumn                                             [SW]
                    ├── titleRow / subtitleView / metaRow / Divider / recentSessions…
                    └── .overlay(.bottom) { inputBar() }                   [SW]
                        └── InputBarChrome (slot, supplied by ComposeSessionView)   [SW]
                            └── VStack { InputBarView2 · InputBarSessionChrome }    [SW]  (same subtree as Path A)
```

### Path C — `/new` `/clear` draft-landing bar

`DraftSessionLandingViewController` (`DraftSessionLandingViewController.swift:244`) hosts an `InputBarChrome` directly with `autofocus: true` and `onAttachRect/onPillRect` no-ops — same subtree as Path A's `InputBarChrome` node downward. Path D is the demo VC (`PermissionSessionDemoViewController.swift:106`) hosting `ChatRestingBar`.

Key boundary observations (FACT):

- Both real coordinate spaces are named identically — `"ChatSessionViewController.detail"` (`ChatSessionViewController.swift:50`) — and declared on `ChatComposeStack` (`:677`) and `ComposeSessionView` (`:193`). `InputBarChrome` receives the name as a plain `coordSpace: String` (`InputBarChrome.swift:14`) and forwards it to `InputBarView2.coordSpace`.
- `InputBarView2` is **never constructed directly** outside `InputBarChrome.body` (`InputBarChrome.swift:51`) and the `#Preview` (`InputBarView2.swift:833`). `InputBarChrome` is the only production caller; it is in turn constructed by `ChatRestingBar` (`InputBarChrome.swift:127`), `ComposeSessionView` (`ComposeSessionViewController.swift:178`), and `DraftSessionLandingViewController` (`:244`).

---

## 3. Data flow

### 3.1 How state enters the bar

`InputBarView2` is, by design, a **leaf with injected closures + injected values** — it holds no session handle (doc at `InputBarView2.swift:4-5`, `CLAUDE.md:13`). Inbound (all read-only into the bar except the two-way `@Binding`s into `TextInputView`):

- Session-derived values are resolved **in `InputBarChrome`** and passed down by value: `isRunning`, `directory`, `additionalDirs`, `pluginDirs`, `knownSlashCommands`, `submitEnabled` (`InputBarChrome.swift:49-75`). `InputBarChrome` resolves the `Session` synchronously every render via `manager.prepareDraftSession(sessionId)` (`InputBarChrome.swift:33-35`) — get-or-create, idempotent, returns the same instance the host VC holds.
- `onSubmit`, `onStop`, `onAttachRect`, `onPillRect`, `onBuiltinCommand`, `draftKey`, `coordSpace`, `autofocus` are closures/config injected from the host VC down through `InputBarChrome` (`InputBarChrome.swift:13-26`, `:51-75`).
- `InputDraftStore` enters via `@Environment` (`InputBarView2.swift:154`), injected at the host VC's hosting boundary (`ChatSessionViewController.swift:578`, `ComposeSessionViewController.swift:102`).

Bar-private state (`@State`): `text`, `isFocused`, `desiredCursorPosition`, `attachments`, `previewImage`, `isDropTargeted`, `completion` (`InputBarView2.swift:155-167`). These are the bar's own UI state and never leak upward except through `onSubmit`.

### 3.2 Direction of propagation (mostly unidirectional, two named back-channels)

- **Send (out, unidirectional):** `handleSend()` (`InputBarView2.swift:444`) builds a `Submission` and calls injected `onSubmit`. In Path A, `ChatComposeStack.onSubmit` → VC closure → `submitSessionInput(...)` (`ChatSessionViewController.swift:548-556` → `SessionInputSubmit.swift:16`). In Path B, `ComposeSessionView.onSubmit` → VC closure → same `submitSessionInput` (`ComposeSessionViewController.swift:85-93`). `submitSessionInput` promotes the draft, calls `session.send`, and flips selection via `model.promote(...)` (`SessionInputSubmit.swift:49-67`).
- **Stop (out, unidirectional):** `onStop` is wired in `InputBarChrome` to `session.interrupt()` (`InputBarChrome.swift:53`). Note `InputBarView2.onEscape` also calls `onStop()` when running and no completion is active (`InputBarView2.swift:400-406`).
- **Running state (in, unidirectional, observed):** `session.isRunning` read in `InputBarChrome.body` (`:54`) → `InputBarView2.isRunning` → drives `sendOrStopButton` (`InputBarView2.swift:417-436`). Because `InputBarChrome` reads `session.isRunning` inside `body`, SwiftUI Observation re-evaluates the bar on flips. (Separately, the loading **pill** in the transcript is driven imperatively from the VC, not the bar — `CLAUDE.md:49`, `ChatSessionViewController.startRunningObservation` `:525`.)
- **Builtin commands (out):** `onBuiltinCommand` threaded into `triggerContext` (`InputBarView2.swift:482-490`) so the completion rule can fire `/new` `/clear`; in chat mode it routes through `ChatComposeStack` → `runBuiltinSlashCommand` (`ChatSessionViewController.swift:567-574`).

### 3.3 BACK-CHANNEL 1 — rect reporting (`onAttachRect` / `onPillRect`), the "coordinate-space dance"

This is a **SwiftUI→AppKit geometry feedback loop**, not part of the input data flow:

1. `InputBarView2` attaches `ReportFrame(coordSpace:action:)` to the attach button and the pill (`InputBarView2.swift:182`, `:184`). `ReportFrame` runs `.onGeometryChange(for: CGRect.self) { proxy.frame(in: .named(coordSpace)) }` (`:744-747`) — i.e. it reports the frame **in the named coordinate space**, not in the bar's own space.
2. The named space is declared at the **top of the hosted SwiftUI tree** by `ChatComposeStack` (`ChatSessionViewController.swift:677`). So the reported rect is in detail-pane SwiftUI coordinates.
3. The rect crosses the host boundary through the closures `onAttachRect`/`onPillRect`, forwarded verbatim `InputBarView2` → `InputBarChrome` → `ChatRestingBar` → `ChatComposeStack` → VC closure (`InputBarChrome.swift:57-58`, `:133-134`; `ChatSessionViewController.swift:663-664`, `:557-566`).
4. The VC stores them in `lastAttachRect`/`lastPillRect` (private fields, `ChatSessionViewController.swift:100-101`) and calls `applyScrimCutouts()` (`:231`), which converts the rect from `composeOrBarHost`'s coordinate space into the bottom scrim's local space via `bottomScrim.convert(_:from: composeOrBarHost)` (`:232-233`) and writes `bottomScrim.attachRect`/`.pillRect`.
5. `TranscriptBottomScrimView` punches an even-odd cutout — a `Circle` for attach, a `RoundedRect(cornerRadius:16)` for pill (`TranscriptScrimView.swift:141-156`). Two rects are reported separately precisely so the 8pt gap between attach and pill is **not** cut and the gradient bridges them (`InputBarView2.swift:118-122`).

INFERENCE: the coordinate-space identity (SwiftUI `.named(coordSpace)` == the AppKit `composeOrBarHost`'s frame) holds only because the host pins the hosting view to `view` and the SwiftUI `.coordinateSpace` is declared at the root of that host's tree. This is a deliberate "share the coordinate space across the AppKit↔SwiftUI boundary" trick (echoed by the scrim doc, `TranscriptScrimView.swift:104-108`). It is FACT that the conversion source is `composeOrBarHost` (`:232`), and FACT that the bottom scrim's bounds are full-bleed to the detail VC's `view` (`:104-108`, scrim constraints `ChatSessionViewController.swift:197-200`).

The other three `InputBarChrome` sites pass **no-op** rect closures (`ComposeSessionViewController.swift:184-185`, `DraftSessionLandingViewController.swift:253-254`, `PermissionSessionDemoViewController.swift:110-111`) — only the chat resting bar has a scrim consumer behind it.

### 3.4 BACK-CHANNEL 2 — imperative draft clear on send (the "imperative-clear hack")

Normal draft persistence is **reactive**: `.onChange(of: text)` / `.onChange(of: attachments)` → `scheduleDraftSave()` → `draftStore.save(...)` (debounced) (`InputBarView2.swift:206-207`, `:215-225`). Restore is `.task(id: draftKey)` reading `draftStore.load(...)`, gated on `text.isEmpty && attachments.isEmpty` (`:198-205`).

But on send, `handleSend()` **imperatively** calls `draftStore.clear(key)` *before* `onSubmit` (`InputBarView2.swift:467-473`). The why (documented at `:458-466`, and `CLAUDE.md:52`): `onSubmit` in compose mode triggers `model.promote/select`, which swaps the routed child VC **synchronously in the same source phase** — tearing this bar down before SwiftUI re-evaluates the body. So the reactive `.onChange(of: text) → clear` path can never fire (`text=""` write happens, but the body that would observe it is gone). The direct `clear` runs on the stack regardless of teardown.

INFERENCE: this is correct and minimal, but it means there are **two** code paths that clear the draft (reactive empty-save→clear at `InputDraftStore.save` `:66-69`, and the imperative `clear` at `:471`) plus a teardown-timing assumption baked into the bar. The bar now knows about a host lifecycle fact (synchronous VC swap) — a small leak of host concerns into the "pure UI" leaf.

### 3.5 Compose-card config flow (single source of truth, no mirror)

`ComposeSessionView.composeBindings` binds the configurator's `folder` / `useWorktree` / `sourceBranch` directly to `session.draft.config` getters/setters (`ComposeSessionViewController.swift:210-229`). There is **no** parallel copy on `MainSelectionModel` (explicitly documented `MainSelectionModel.swift:84-91`, `NewSessionConfigurator.swift:22-27`). `NewSessionConfigurator` mutates those bindings (e.g. `applyProbeBindings` `:707`) and the same `session.draft` is what `submitSessionInput` and the bar's completion `directory`/`additionalDirs` read — one source, no sync hop. This is the cleanest sub-flow in the area.

---

## 4. Ownership & lifetime

- **`InputBarView2` instance** — constructed inside `InputBarChrome.body` (`InputBarChrome.swift:51`); SwiftUI owns its lifetime. Its `@State` (text/attachments/completion/focus) is reset across session switches by `.id(sid)` on `ChatRestingBar` in `ChatComposeStack` (`ChatSessionViewController.swift:659-667`; rationale `:649-658`). FACT: without `.id(sid)` the bar's state persists across sessions and would clobber the next session's draft.
- **`completion` (`CompletionViewModel`)** — `@State` created once per `InputBarView2` (`InputBarView2.swift:167`); its provider closures are rebuilt every render via `triggerContext` (`:482-490`). Lifetime = the bar identity (so tied to `.id(sid)`).
- **`InputBarChrome` / `ChatRestingBar`** — SwiftUI value views; reconstructed every render. They hold no retained references — `Session` is resolved fresh from the environment `SessionManager` each `body` (`InputBarChrome.swift:33`, `:125`). The `Session` itself is owned by `SessionManager` (`CLAUDE.md` ownership graph), not by any bar view.
- **`NewSessionConfigurator`** — value view; constructed by `ComposeSessionView.body` (`ComposeSessionViewController.swift:172`). It owns one piece of real state: `@State private var probe: GitProbe`, seeded synchronously in `init` (`NewSessionConfigurator.swift:98-120`) and refreshed in `.task(id: folderPath)` (`:169-199`). `RecentProjectsStore` + `SessionManager` come from `@Environment` (`:90-91`).
- **The hosting boundary objects:**
  - `composeOrBarHost: NSHostingView<AnyView>` — owned by `ChatSessionViewController`, created in `loadView()` (`ChatSessionViewController.swift:161`), `sizingOptions = [.intrinsicContentSize]` (`:169`), bottom-anchored, lives for the VC's lifetime. The hosted body switches content on `model.selection`.
  - `host: NSHostingController<AnyView>` — owned by `ComposeSessionViewController`, created in `viewDidLoad()` (`ComposeSessionViewController.swift:108`), `sizingOptions = []` (`:115`), pinned 4-edge. Lives while `.newSession` is the routed selection; the router tears the whole VC down on a cross-kind switch.
- **`InputDraftStore`** — process-scoped service owned by `AppState`/`AppDelegate` (per root `CLAUDE.md` AppState list), injected by both host VCs (`ChatSessionViewController.swift:578`, `ComposeSessionViewController.swift:102`). Bar views never construct it. Pending debounced saves are keyed by `sessionId` and cancelled/replaced per key (`InputDraftStore.swift:65-81`).
- **`lastAttachRect`/`lastPillRect`** — owned privately by `ChatSessionViewController` (`:100-101`); explicitly local, "no cross-VC consumer" (`:98-99`).
- **`draftSessionId` lifecycle** — allocated lazily by `ComposeSessionViewController.ensureDraftSession()` (`:135-146`), seeded onto `model.draftSessionId`; nilled on submit (`SessionInputSubmit.swift:67`) or on resume (`ComposeSessionViewController.swift:97`). The compose card captures it as a **plain value** at `viewDidLoad`, deliberately NOT read reactively (`:75-80`), so the card doesn't blank for one tick during the submit flip.

---

## 5. Smells / debt

### S1 — `AnyView` erasure at both bar host boundaries — MEDIUM
`ChatSessionViewController.composeOrBarHost: NSHostingView<AnyView>` (`ChatSessionViewController.swift:94`, body `:161` `AnyView(makeComposeOrBarStack())`) and `ComposeSessionViewController.host: NSHostingController<AnyView>` (`:42`, `:82` `AnyView(ComposeSessionView(...))`). `AnyView` defeats SwiftUI's structural-identity/diff optimizations and obscures the type at the seam. Why it matters for the refactor: a cleaner generic host (`NSHostingView<ChatComposeStack>` etc.) would make the dependency direction explicit and let the compiler enforce the environment injections. INFERENCE: `AnyView` here is likely incidental, not load-bearing (the bodies are single concrete types) — but verify no `if #available`-style branch returns differing types before un-erasing.

### S2 — Six-step closure relay for the rect back-channel — MEDIUM
`onAttachRect`/`onPillRect` are forwarded verbatim through `InputBarView2 → InputBarChrome → ChatRestingBar → ChatComposeStack → VC closure` (`InputBarChrome.swift:57-58`/`133-134`, `ChatSessionViewController.swift:663-664`/`557-566`). Three of four `InputBarChrome` call sites pass no-ops (`ComposeSessionViewController.swift:184-185`, `DraftSessionLandingViewController.swift:253-254`, `PermissionSessionDemoViewController.swift:110-111`). The chrome wrapper and resting bar carry these as **non-optional** `(CGRect) -> Void` (`InputBarChrome.swift:18-19`, `:115-116`) even though only one consumer exists, forcing every other site to invent `{ _ in }`. INFERENCE: candidate for a single optional reporter (or a tiny `RectSink` struct) so non-chat hosts opt out by passing `nil` rather than two no-ops; would shrink the relay and make "who actually consumes this" obvious.

### S3 — The "pure UI" leaf knows host teardown timing — MEDIUM
`InputBarView2.handleSend` reaches into `draftStore.clear(key)` (`InputBarView2.swift:471`) specifically because of a host-side synchronous-VC-swap fact (comment `:458-466`). The bar is otherwise admirably handle-free, but this couples the leaf to a lifecycle invariant owned by the router/VC. Why it matters: a refactor that changes the swap timing (e.g. makes selection async again) silently breaks draft clearing with no compile error. The clear is correct today; the **coupling** is the debt. INFERENCE: could be lifted by having `submitSessionInput`/the host clear the draft after promotion, leaving the bar to only reset its `@State` — but note the host would then need the `draftKey`, which it already has (`ChatComposeStack` passes `draftKey: sid`).

### S4 — `ChatRestingBar` resolves `Session` twice per render — LOW
`ChatRestingBar.body` calls `manager.prepareDraftSession(sessionId)` (`InputBarChrome.swift:125`) for `pendingPermissions`, and the nested `InputBarChrome` resolves it **again** (`:33`). `prepareDraftSession` is idempotent/cheap (get-or-create), so this is correctness-safe, but it's a duplicated lookup and a subtle observation-tracking footgun (two independent reads of the same `@Observable`). LOW because it's cheap and documented as idempotent.

### S5 — Magic-constant duplication of pill geometry across module boundaries — MEDIUM
The pill corner radius `16` is declared in `InputBarView2.cornerRadius` (`InputBarView2.swift:22`) and **re-hardcoded** in `TranscriptBottomScrimView.pillCornerRadius = 16` (`TranscriptScrimView.swift:138`, with a comment acknowledging the duplication "so the scrim stays a pure leaf with no upward dependency"). Similarly `InputBarSessionChrome.pillLeadingInset = AttachButton.size + 8` reconstructs `InputBarView2`'s private `attachToPillSpacing = 8` (`InputBarSessionChrome.swift:26-29`, vs `InputBarView2.swift:27`), and `ChatSessionViewController.bottomFadeScrimHeight = 100` is hand-summed from four constants (`:54-59`). Each is a deliberate decoupling (avoid an upward dependency), but they're **silent** couplings: change `attachToPillSpacing` to 6 and the chrome row misaligns and the scrim cutout drifts with no test catching it. MEDIUM — these are exactly the kind of cross-file invariant a refactor can break invisibly.

### S6 — `NewSessionConfigurator` is oversized and mixes concerns — MEDIUM
~900 lines (`NewSessionConfigurator.swift`) covering: two-column layout, recent-projects list (+ `HideEnclosingScrollerWidth` AppKit scroller hack `:781-875`), git-probe orchestration (`:169-199`, `:707-738`), branch picker, worktree menu, recent-sessions list, and relative-time formatting (`:657-667`). The `inputBar` slot is clean (generic `@ViewBuilder`, `:41`), but the surrounding card carries far more than "where the bar lives." Violates the "split a body past ~40 lines" guidance (root `CLAUDE.md` SwiftUI rules). MEDIUM — large, but internally cohesive; refactor target is extraction (projects column, git-probe glue) not redesign.

### S7 — `Submission.text`/`images`/`filePaths` re-composition split across two layers — LOW
`InputBarView2.handleSend` splits attachments into `images`/`filePaths` (`:447-457`), then `submitSessionInput` re-joins `filePaths` into `@"..."` mentions and decides image-vs-text send (`SessionInputSubmit.swift:40-55`). The attachment model is thus assembled in the bar, disassembled into the `Submission` struct, and re-assembled into a command string downstream. LOW — works and is testable, but the round-trip is a mild smell; the doc comment on `Submission` even points at `RootView2.submit` (`:88-89`) which no longer exists (stale reference).

### S8 — Stale doc references to deleted `RootView2` — LOW
Multiple comments still cite `RootView2` as the owner/composer (`InputBarView2.swift:88-89`, `:107-109`; `NewSessionConfigurator.swift:18-27`, `:51-52`; `AttachButton`-adjacent prose). The actual owners are now `ChatSessionViewController` / `ComposeSessionViewController` / `submitSessionInput`. Documentation drift only, but it misleads a reader tracing ownership. LOW.

### S9 — `onEscape` send-stop coupling lives in the bar — LOW
`InputBarView2.onEscape` calls `onStop()` when `isRunning` (`:400-406`), duplicating the stop affordance that the send/stop button already owns. Minor behavioral logic ("Esc interrupts") embedded in the otherwise-presentational bar. LOW; arguably correct UX placement.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

1. **`InputBarView2` stays handle-free.** It must not gain a `Session` reference; all session-derived inputs arrive by value from `InputBarChrome` and all mutations leave via injected closures (`InputBarView2.swift:4-5`, `:97-152`; rule at `CLAUDE.md:61`). This is what lets the same bar serve chat, compose, draft-landing, and demo hosts.

2. **Imperative draft clear on send must run before/around teardown.** `handleSend` must clear the persisted draft on the stack (`InputBarView2.swift:467-473`), because the synchronous VC swap (`MainSelectionModel.select`/`promote` → router) tears the bar down in the same source phase and the reactive `.onChange` clear can't fire (`InputBarView2.swift:458-466`, `CLAUDE.md:52`). Any refactor that relocates the clear must keep it on a path that survives synchronous teardown.

3. **`.id(sid)` on the per-session bar is required.** `ChatComposeStack` applies `.id(sid)` so `InputBarView2`'s `@State` resets per session (`ChatSessionViewController.swift:659-667`); removing it lets a non-empty bar both display the previous session's text and clobber the new session's draft on next keystroke (`:649-658`).

4. **Rect coordinate-space identity.** `onAttachRect`/`onPillRect` are reported in `.named("ChatSessionViewController.detail")` (`InputBarView2.swift:744-747`, space declared `ChatSessionViewController.swift:677`), and the VC converts them from `composeOrBarHost` into the bottom-scrim space (`:232-233`). The contract: the named SwiftUI space == `composeOrBarHost`'s frame == full-bleed over the detail `view`. Attach and pill must remain **separate** rects (the 8pt gap is intentionally uncut, `InputBarView2.swift:118-122`). A refactor that re-parents the hosting view, renames/relocates the coordinate space, or merges the two rects breaks the scrim cutouts.

5. **Host `sizingOptions` are non-negotiable.** Chat bar host = `[.intrinsicContentSize]` (component over a transcript that fills the pane; `ChatSessionViewController.swift:169`, rationale in root `CLAUDE.md` host-sizing section). Compose host = `[]` (fills the pane; `ComposeSessionViewController.swift:115`). Swapping these collapses/resizes the window.

6. **`ChatRestingBar` must be a `ZStack` (not `.overlay`) for the permission card.** The card's footprint must grow the bottom-anchored host so its upper half stays inside hit-test bounds; an overlay clips it and kills its buttons (`InputBarChrome.swift:84-110`). The card width is hoisted to `BlockStyle.maxLayoutWidth` outside `InputBarChrome`'s `composeMaxWidth` cap (`:103-106`, `:143-158`).

7. **Single source of truth for compose config.** The configurator binds directly to `session.draft.config`; no mirror on `MainSelectionModel` (`ComposeSessionView.composeBindings` `:210-229`, `MainSelectionModel.swift:84-91`). The bar's completion `directory`/`additionalDirs`, the configurator, and `submitSessionInput` must keep reading the same `session.draft` — do not reintroduce a parallel copy.

8. **`draftSessionId` captured as a plain value in the compose VC.** Read reactively, the card blanks for one tick during the submit selection flip (`ComposeSessionViewController.swift:75-80`). Keep it a captured value, nilled by the submit/resume paths, not re-read from `model` inside the card body.

9. **Draft-restore gating.** The `.task(id: draftKey)` restore only applies when `text.isEmpty && attachments.isEmpty` (`InputBarView2.swift:201`) so an async disk read can't clobber in-flight typing. Preserve this guard.

10. **Geometry reporting must stay opt-out via nil.** `ReportFrame` is a no-op when `coordSpace`/`action` is nil (`InputBarView2.swift:743-751`); previews and non-scrim hosts rely on this. Any consolidation of the rect channel must keep a nil/no-op path.

11. **`prepareDraftSession` idempotence is relied on in `body`.** Multiple views resolve `Session` from inside `body` every render (`InputBarChrome.swift:33`, `:125`; `ComposeSessionView.swift:168`). This is only safe because `prepareDraftSession` is pure in-memory get-or-create returning the same instance the VC holds (`InputBarChrome.swift:32-35`, `CLAUDE.md` Session doc). Don't make it side-effecting.
