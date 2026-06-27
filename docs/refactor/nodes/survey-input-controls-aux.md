# Survey: Auxiliary input-bar controls (todos, background tasks, context ring, pickers, popovers)

Scope: `macos/ccterm/Content/Chat/InputBarControls/` — the subset assigned for this
survey: `TodoList`, `TodoButton`, `TodoStatusGlyph`, `BackgroundTaskList`,
`BackgroundTaskRow`, `BackgroundTaskButton`, `BackgroundTaskDetailSheet`,
`BackgroundTaskOutputStream`, `ContextRingButton`, `PermissionModePicker`,
`PopoverList`, `SedEditParser`. Two supporting files in the same directory are
included where they are load-bearing for these controls: `BarChromeButton`
(shared trigger), `InputBarSessionChrome` (the host row that mounts all of
them). The permission *card* family (`Permission*CardBody.swift`,
`PermissionCardView`, `PermissionCardKind`) and `ModelEffortPicker` live in the
same directory but are out of this survey's scope except where they share a type
(`SedEditParser` is consumed by `PermissionSedEditCardBody`; `BarChromeButton` /
`PopoverList` are shared with `ModelEffortPicker`).

All claims are cited `file:line`. FACT = read directly in the code; INFERENCE =
my read. Boundary of interest is the AppKit↔SwiftUI seam, who owns/constructs
each object, and whether the documented "read `@Observable` on `session`" rule
is followed.

---

## 1. Component / type inventory

These controls are **all SwiftUI** — they are leaves of the SwiftUI subtree
hosted by `ChatSessionViewController`'s `NSHostingView<ChatRestingBar>` (see §2).
The only AppKit/Foundation object in the set is `BackgroundTaskOutputStream`,
which is an `@Observable @MainActor` service (not a view).

### Todos

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `TodoButton` | SwiftUI `View` | Chrome-row trigger; hidden until `session.todos` non-empty; shows `completed of total`; opens popover. | `TodoButton.swift:9` |
| `TodoList` | SwiftUI `View` | Popover body — `ScrollView` + `ForEach(session.todos)` of `TodoRow`. 340pt wide, 480pt cap. | `TodoList.swift:12` |
| `TodoRow` | SwiftUI `View` | One memo line: status glyph + subject/activeForm + optional description. | `TodoList.swift:40` |
| `TodoStatusGlyph` | SwiftUI `View` | 3-state glyph (pending ring / in-progress dotted ring / completed ring+dot); `muted` quiet variant for chrome. | `TodoStatusGlyph.swift:20` |
| `CompletedRingAndDotShape` | SwiftUI `Shape` (private) | Even-odd donut+dot as a single fill path. | `TodoStatusGlyph.swift:87` |
| `RotatingDottedRing` | SwiftUI `View` (private) | Slowly-rotating dotted ring for the popover in-progress glyph. | `TodoStatusGlyph.swift:113` |
| `TodoEntry` | `struct` model (`Identifiable, Equatable`) | Render-ready todo row (id / subject / description / activeForm / status / timestamps). | `Services/Session/Session/SessionTypes.swift:117` |
| `TodoEntry.Status` | `enum: String` | `pending` / `inProgress="in_progress"` / `completed`. | `SessionTypes.swift:139` |

### Background tasks

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `BackgroundTaskButton` | SwiftUI `View` | Chrome-row trigger; hidden until `session.tasks` non-empty; running-dot + count label; **owns both the popover and the detail `.sheet`**. | `BackgroundTaskButton.swift:17` |
| `BackgroundTaskList` | SwiftUI `View` | Popover body — groups tasks (running / completed) and lists `BackgroundTaskRow`s. Owns a 1s `Timer.publish` for live elapsed counters. | `BackgroundTaskList.swift:13` |
| `BackgroundTaskList.TaskGroup` | `struct` (private, `Identifiable`) | View-local grouping bucket. | `BackgroundTaskList.swift:68` |
| `BackgroundTaskRow` | SwiftUI `View` | One compact row (status dot + title + subtitle + chevron); tap → `onSelect`. | `BackgroundTaskRow.swift:9` |
| `BackgroundTaskFormat` | `enum` (namespace of statics) | Shared formatting (`statusLabel` / `statusedSubtitle` / `elapsedDescription` / `formatElapsed`) used by row + sheet. | `BackgroundTaskRow.swift:87` |
| `BackgroundTaskDetailSheet` | SwiftUI `View` | Modal sheet — command + live output + summary + footer with Stop. Owns the `BackgroundTaskOutputStream` lifecycle. | `BackgroundTaskDetailSheet.swift:39` |
| `BackgroundTaskOutputView` | SwiftUI `View` | `@Bindable` scroll view over a stream; auto-scrolls to tail on `stream.text` change. | `BackgroundTaskDetailSheet.swift:344` |
| `BackgroundTaskOutputStream` | `@Observable @MainActor final class` (service) | Tails a spool file via `DispatchSource` + 1s timer; exposes `text` / `fileMissing` / `isStarting`. One per file path. | `BackgroundTaskOutputStream.swift:19` |
| `BackgroundTask` | `struct` model (`Identifiable, Equatable`) | Off-transcript background-bash record (id / command / outputFile / status / timestamps / summary). | `SessionTypes.swift:56` |
| `BackgroundTask.Status` | `enum` | `running` / `completed` / `failed` / `stopped`. | `SessionTypes.swift:58` |

### Context ring

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `ContextRingButton` | SwiftUI `View` | Footer ring trigger; always renders; opens context popover. | `ContextRingButton.swift:13` |
| `ContextPopoverContent` | SwiftUI `View` (private) | Two-section popover (typed breakdown + compact summary); fires `requestContextUsage()` on appear. | `ContextRingButton.swift:53` |
| `ContextBreakdownView` | SwiftUI `View` (private) | Sorted category bar + per-category rows + expandable Memory/MCP/agents groups. | `ContextRingButton.swift:133` |
| `CategoryRow` | SwiftUI `View` (private) | One category line (swatch + name + tokens + %). | `ContextRingButton.swift:276` |
| `ExpandableGroup` | SwiftUI `View` (private) | Disclosure group for Memory files / MCP tools / Custom agents. | `ContextRingButton.swift:313` |
| free funcs `isBufferName` / `formatTokens` | file-private helpers | Category-name predicate + token humanizer. | `ContextRingButton.swift:270`, `:375` |
| `ProgressRingView` | SwiftUI `View` (shared, `Components/`) | The ring glyph itself — used by the button **and** the popover summary. | `Components/ProgressRingView.swift:8` |
| `ContextUsage` | `struct` model (from `AgentSDK`) | Typed `get_context_usage` breakdown. | (AgentSDK) |

### Permission-mode picker

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `PermissionModePicker` | SwiftUI `View` | Chrome-row trigger; reads `session.permissionMode`, writes `setPermissionMode`; seeds from `NewSessionDefaultsStore` for drafts; gates `.auto` on model capability. | `PermissionModePicker.swift:12` |
| `PermissionModePicker.SeedKey` | `struct` (private, `Hashable`) | `.task(id:)` key (sessionId + supportsAuto) to re-run the defaults seed. | `PermissionModePicker.swift:49` |
| `PermissionModePopoverContent` | SwiftUI `View` (private) | The mode list (`PopoverSectionHeader` + `PopoverRow`s). | `PermissionModePicker.swift:83` |

### Shared popover primitives + trigger

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `PopoverList` | `enum` (constants namespace) | Shared sizing constants (`width` 240 / `rowHeight` 28 / `horizontalInset` 10 / `outerPadding` 6 / `maxHeight` 480). | `PopoverList.swift:9` |
| `PopoverSectionHeader` | SwiftUI `View` | Small gray section header ("Mode" / "Models" / …). | `PopoverList.swift:22` |
| `PopoverRow<Accessory>` | SwiftUI `View` (generic) | Selectable row + trailing checkmark; `EmptyView` convenience init. | `PopoverList.swift:39`, ext `:68` |
| `PopoverRowHoverStyle` | SwiftUI `ButtonStyle` | Shared hover/press background — also used by `ModelEffortPicker`'s `ModelPopoverRow`. | `PopoverList.swift:77` |
| `BarChromeButton<Content>` | SwiftUI `View` (generic) | The pill trigger shell (22pt `.barSurface`, hover overlay) for permission / model / todo / task buttons. | `BarChromeButton.swift:12` |
| `InputBarSessionChrome` | SwiftUI `View` | The chrome row that mounts all six controls in left/spacer/right order; resolves `activeModel`. | `InputBarSessionChrome.swift:13` |

### Sed parser (consumed by a permission card, not by the in-scope controls)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `SedEditInfo` | `struct` model (`Equatable`) | Parsed `sed -i 's/p/r/flags' file` parts + `apply(to:)`. | `SedEditParser.swift:8`, ext `:187` |
| `SedEditParser` | `enum` (statics) | Pure parser: `parse(_:) -> SedEditInfo?`. | `SedEditParser.swift:29` |
| `ShellTokenizer` | `enum` (statics) | Minimal shell-quote tokenizer (single/double/bare); bails on shell metachars. | `SedEditParser.swift:299` |

Consumer (out of scope but the only call sites): `PermissionSedEditCardBody.swift:72`
and `PermissionCardKind.swift:38`. `SedEditParser` is **not** referenced by any
of the in-scope controls — it is bundled in this directory only by physical
proximity to the permission cards.

---

## 2. Component tree (this area)

AppKit ownership above the SwiftUI boundary (FACT; from
`Content/Chat/CLAUDE.md:11`, `:40` and `App/AppKit/ChatSessionViewController.swift`):

```
ChatSessionViewController                            [AppKit NSViewController]
└─ NSHostingView<ChatRestingBar>                     [AppKit→SwiftUI boundary]
   · sizingOptions = [.intrinsicContentSize]         (bottom-anchored bar component; CLAUDE.md root §host sizing)
   └─ ChatRestingBar                                 [SwiftUI]  (InputBarChrome.swift:111)
      └─ ZStack(alignment: .bottom)
         ├─ InputBarChrome                           [SwiftUI]  (InputBarChrome.swift:12)
         │  └─ VStack
         │     ├─ InputBarView2                      [SwiftUI]  (pill — out of scope)
         │     └─ InputBarSessionChrome              [SwiftUI]  (InputBarSessionChrome.swift:13)
         │        └─ HStack
         │           ├─ PermissionModePicker         [SwiftUI]  (PermissionModePicker.swift:12)
         │           │  └─ BarChromeButton + .popover → PermissionModePopoverContent
         │           │        └─ ScrollView/VStack → PopoverSectionHeader + PopoverRow×N
         │           ├─ BackgroundTaskButton         [SwiftUI]  (BackgroundTaskButton.swift:17)
         │           │  ├─ BarChromeButton
         │           │  ├─ .popover → BackgroundTaskList
         │           │  │     └─ ScrollView/VStack → section(TaskGroup) → BackgroundTaskRow×N
         │           │  └─ .sheet(item: detailBinding) → BackgroundTaskDetailSheet
         │           │        └─ VStack(titleBar / ScrollView(command+output+summary) / footer)
         │           │           └─ outputBody → BackgroundTaskOutputView(@Bindable stream)
         │           │              · owns BackgroundTaskOutputStream  [@Observable @MainActor service]
         │           ├─ TodoButton                   [SwiftUI]  (TodoButton.swift:9)
         │           │  └─ BarChromeButton + .popover → TodoList
         │           │        └─ ScrollView/VStack → TodoRow×N → TodoStatusGlyph
         │           ├─ Spacer
         │           ├─ ModelEffortPicker            [SwiftUI]  (out of scope; sibling)
         │           └─ ContextRingButton            [SwiftUI]  (ContextRingButton.swift:13)
         │              └─ Button(ProgressRingView) + .popover → ContextPopoverContent
         │                    ├─ ContextBreakdownView → barTrack + CategoryRow×N + ExpandableGroup×{0..3}
         │                    └─ summarySection (ProgressRingView + text)
         └─ PermissionCardView (when pending)        [SwiftUI]  (out of scope)
```

Hosting notes (FACT):
- Every `.popover` and `.sheet` here is a **SwiftUI** presentation — there is no
  `NSHostingController`/`NSPopover`/`NSWindow.beginSheet` in any of these files.
  This is the opposite of the transcript's user-bubble sheet, which routes
  through `Transcript2SheetPresenter` + AppKit `beginSheet`
  (`NativeTranscript2/CLAUDE.md:356`). The aux controls deliberately stay on the
  SwiftUI presentation path because they're already deep in a SwiftUI subtree.
- A SwiftUI `.popover` is presented in **its own window**; a `.sheet` presents in
  the **enclosing window**. `BackgroundTaskButton` hosts the `.sheet` at the
  button level (not inside `BackgroundTaskList`) precisely so the sheet lands
  centered in the app window rather than stacked on the popover bubble
  (`BackgroundTaskButton.swift:21-28`). This is a load-bearing placement choice,
  documented inline.

---

## 3. Data flow

### Inbound (state → controls): all reads go through `Session` `@Observable` forwarders

Every in-scope control reads its data off the injected `session: Session`
value and SwiftUI tracks the `@Observable` forwarders automatically. The
forwarders all funnel into `runtime?.X ?? default` (FACT):

| Control | Reads | Session forwarder | Runtime source |
|---|---|---|---|
| `TodoButton` / `TodoList` | `session.todos` | `Session.swift:349` | `SessionRuntime.todos` `internal(set)` (`SessionRuntime.swift:347`) |
| `BackgroundTaskButton` / `List` / `Row` / `Sheet` | `session.tasks` | `Session.swift:345` | `SessionRuntime.tasks` `internal(set)` (`SessionRuntime.swift:339`) |
| `ContextRingButton` / popover | `session.contextUsedTokens` / `contextWindowTokens` / `contextUsage` / `isFetchingContextUsage` | `Session.swift:353/357/378/386` | `SessionRuntime.swift:244/245/310/317` |
| `PermissionModePicker` | `session.permissionMode`, `session.draft`, `session.model`, `session.availableModels` (via `InputBarSessionChrome.activeModel`) | `Session.swift:475/271/463/337` | draft `SessionDraft.permissionMode` or `SessionRuntime.permissionMode` |

This is **fully compliant** with the documented rule "The UI only reads
`@Observable` properties on the session; it never holds its own copy"
(`Content/Chat/CLAUDE.md:59`, `Services/Session/CLAUDE.md:74`). No control caches
session state into its own `@State`. (FACT — verified each file: the only
`@State` in these views is local UI state: `isPresented`, `isHovering`,
`isOpen`, `now`, `didRequest`, `selectedTaskId`, `stream`.)

The runtime mutation paths that *populate* this state are off-transcript signal
handlers, all `@MainActor`, all synchronous writes to the `@Observable`
`internal(set)` properties:
- todos: `SessionRuntime+Todos.swift` — `captureTodoToolUses` (assistant
  tool_use → scratch dict) paired with `applyTodoToolResult` (user tool_result →
  `todos`), `upsert` at `:159`.
- tasks: `SessionRuntime+Tasks.swift` — `handleTaskStarted` / `handleTaskUpdated`
  / `handleTaskNotification` / `rememberOutputFileFromBashResult`, `upsert` at
  `:134`.
- context: `SessionRuntime+ContextUsage.swift` — `requestContextUsage` writes
  `contextUsage`/`contextUsageFetchedAt` on the main actor (`:36-39`).
  `contextUsedTokens`/`contextWindowTokens` are set elsewhere (token tracking;
  not in these files).

Direction: **strictly unidirectional inbound** for reads — runtime → `@Observable`
→ SwiftUI body re-eval. (FACT)

### Outbound (events / mutations from controls)

Three distinct outbound shapes, **only one of which is clean**:

1. **`PermissionModePicker` → `session.setPermissionMode(mode)`** —
   `PermissionModePicker.swift:31`. This routes through the `Session` façade
   (`Session.swift:656`), which dispatches on phase to `draft.setPermissionMode`
   or `runtime.setPermissionMode`. **Clean / documented** — matches "Runtime-mutable
   setters … are called as `session.setX(...)` regardless of phase"
   (`Content/Chat/CLAUDE.md:58`). It additionally writes
   `NewSessionDefaultsStore.shared.setPermissionMode(mode)` for drafts
   (`:32-34`) — a persistence side-effect, fine.

2. **`ContextRingButton`/popover → `session.requestContextUsage()`** —
   `ContextRingButton.swift:83`. Routes through the `Session` façade
   (`Session.swift:393`) which forwards to the runtime. **Clean** — a façade
   method, not a runtime reach-through. The result lands back on the
   `@Observable` `contextUsage` (pull-by-observation), and a completion callback
   is supported but the popover does not use it (it just re-reads
   `session.contextUsage`).

3. **`BackgroundTaskButton` → `session.runtime.markTaskStoppedLocally(taskId:)`**
   — `BackgroundTaskButton.swift:80-85`. **This is the one back-channel.** The
   Stop button reaches **into `session.runtime` directly** and calls a runtime
   method that is *not* exposed on the `Session` façade. There is no
   `session.stopBackgroundTask(...)` forwarder (verified: the only definition is
   `SessionRuntime+Tasks.swift:124`, and the only caller is this button —
   `grep` confirms no façade method). This is the **only production UI** outside
   the demo VCs that reaches `session.runtime` directly (grep over `Content/`
   returns only `BackgroundTaskButton.swift:81` plus
   `PermissionSessionDemo/*`). See §5 smell #1.

### Hidden back-channels / bidirectional coupling

- `BackgroundTaskButton.detailBinding` (`BackgroundTaskButton.swift:68-78`) is a
  computed `Binding<BackgroundTask?>` whose **getter re-reads
  `session.tasks.first(where:)` live** on every `.sheet(item:)` sample, and whose
  **setter only writes back `selectedTaskId`** (not the task). This is a
  deliberate read-through so the sheet observes status flips while open. It is a
  one-way data path dressed as a two-way `Binding` — the `set` is effectively
  "dismiss" only. INFERENCE: this is correct but subtle; the `Binding`'s
  bidirectionality is an artifact of the `.sheet(item:)` API, not real two-way
  state. Worth a comment-level callout in any refactor; the data really flows
  one way (session → sheet).
- `BackgroundTaskOutputStream` is a **side data source independent of the
  session**: it tails a file on disk by path (`session.tasks[i].outputFile`),
  not through any session/runtime channel (`BackgroundTaskOutputStream.swift`).
  The session is the *source of the path*; the actual output bytes never pass
  through `Session`/`SessionRuntime`. INFERENCE: this is a clean separation (the
  CLI owns the spool file; the runtime only forwards its path), but it means the
  output stream is a second, parallel I/O channel that bypasses the entire
  session state model. Any refactor that tries to "centralize all session I/O on
  `SessionRuntime`" must consciously leave this out — see §6 invariant.

### Event flow summary (direction)

```
runtime signal handlers ──(sync @MainActor write)──▶ SessionRuntime.@Observable
        ▲                                                     │
        │                                            Session forwarder (read)
        │                                                     ▼
   setPermissionMode / requestContextUsage           SwiftUI body re-eval
   (via Session façade — CLEAN)                              │
        │                                                     ▼
        └──── markTaskStoppedLocally ◀── session.runtime ◀── BackgroundTaskButton  (BACK-CHANNEL)

   filesystem spool ──(DispatchSource)──▶ BackgroundTaskOutputStream.text ──▶ BackgroundTaskOutputView
   (parallel I/O channel; session supplies only the path)
```

---

## 4. Ownership & lifetime

- **The controls themselves** are SwiftUI value types — they don't have an
  identity to "own". They are reconstructed on each body re-eval of
  `InputBarSessionChrome`, which is reconstructed by `InputBarChrome`, hosted by
  `NSHostingView<ChatRestingBar>` owned by `ChatSessionViewController`
  (`Content/Chat/CLAUDE.md:11`). Lifetime of the *subtree* = lifetime of the
  mounted chat VC; a session switch tears the host down and rebuilds it for the
  new session (router-driven, `Content/Chat/CLAUDE.md:51`). (FACT)
- **`session: Session`** is resolved (not constructed) by
  `InputBarChrome`/`ChatRestingBar` via
  `manager.prepareDraftSession(sessionId)` — idempotent get-or-create, returns
  the manager-cached instance (`InputBarChrome.swift:33-35`, `:125`). The
  controls receive it by value-injection (`let session: Session`). They never
  construct or retain a `Session`/`SessionRuntime`. (FACT)
- **`@State private var isPresented` / `selectedTaskId` / `isHovering` / `isOpen`
  / `didRequest`** — view-private UI state, owned by SwiftUI's storage for the
  view identity, lives as long as the view is in the tree. (FACT)
- **`BackgroundTaskOutputStream`** — constructed and owned by
  `BackgroundTaskDetailSheet` via `@State private var stream`
  (`BackgroundTaskDetailSheet.swift:46`). Created in `rebindStream()`
  (`:330`), `.start()`ed there, and torn down in two places: `.task(id:
  task.outputFile)` rebinds when the path changes (`:73`), and `.onDisappear {
  stream?.stop() }` stops it when the sheet closes (`:74`). Its `deinit`
  (`BackgroundTaskOutputStream.swift:59`) is a defensive fd/source close.
  Lifetime = while the detail sheet is open for a given task. **One instance per
  file path** (the class documents this as its identity invariant,
  `:21-22`), but the *enforcement* of one-per-path lives in
  `rebindStream` (`:328` `if stream?.path != path`), i.e. it's actually
  one-per-open-sheet, re-created if the path changes. (FACT)
- **`Timer.publish` in `BackgroundTaskList`** (`BackgroundTaskList.swift:25`) —
  `.autoconnect()`'d publisher owned by the view; fires while the popover is
  mounted, torn down with the popover. (FACT)
- **Models (`TodoEntry` / `BackgroundTask` / `ContextUsage`)** — plain value
  types stored in the runtime's `@Observable` arrays
  (`SessionRuntime.swift:339/347`); the controls hold copies-by-value per render.
  No reference identity to manage. (FACT)
- **`ProgressRingView`** — shared value-type view in `Components/`, no ownership.

---

## 5. Smells / debt

### #1 — `BackgroundTaskButton` reaches into `session.runtime` directly (back-channel write) — **HIGH**

`BackgroundTaskButton.swift:80-85`:
```swift
private var stopAction: ((String) -> Void)? {
    guard let runtime = session.runtime else { return nil }
    return { taskId in
        runtime.markTaskStoppedLocally(taskId: taskId)
    }
}
```
This is the only production UI (outside demo VCs) that pierces the `Session`
façade to call a `SessionRuntime` method (grep over `Content/` returns only this
site + the demo VCs). It violates two explicit project rules:
- `Content/Chat/CLAUDE.md:56` — "Views never mutate session running / status /
  message state directly. All writes go through `Session` methods".
- `Services/Session/CLAUDE.md:74` — "The transcript controller is owned by
  `Session` … reads it, never constructs one" (same spirit: the runtime is an
  internal of `Session`).

There is no `Session.stopBackgroundTask(taskId:)` forwarder; `markTaskStoppedLocally`
is defined only on the runtime (`SessionRuntime+Tasks.swift:124`). The clean fix
is a one-line phase-aware forwarder on `Session` (no-op on `.draft`), mirroring
`requestContextUsage` (`Session.swift:393`). Why it matters: it's the single
unidirectional-flow violation in this whole area; every other control routes
through the façade. (FACT)

### #2 — Detail sheet's elapsed clock is frozen while the sheet is open — **MEDIUM**

`BackgroundTaskButton.swift:52-58` constructs the sheet with `now: Date()` — a
**static snapshot captured once** when `.sheet(item:)` first builds its content.
The sheet's `elapsedLine` (`BackgroundTaskDetailSheet.swift:308-311`) and footer
read this fixed `now`, so for a *running* task the elapsed time does not tick in
the sheet — whereas the popover rows *do* tick via `BackgroundTaskList`'s 1s
`Timer` (`BackgroundTaskList.swift:24-43`, passed as `now:` to
`BackgroundTaskRow`). Inconsistent live-ness between two surfaces showing the
same data. The output *body* is live (it's a separate `DispatchSource` stream),
so only the elapsed/timestamps freeze. INFERENCE: likely a latent bug, not
intentional — the sheet documents itself as observing live status flips
(`:64-67`) but the timing clock contradicts that. Fix: give the sheet its own
`TimelineView`/`Timer` or thread the popover's `now` through (the popover is gone
once the sheet opens, so the sheet needs its own ticker). (FACT for the freeze;
INFERENCE for intent.)

### #3 — Duplicated derivation logic across the three task surfaces — **MEDIUM**

`titleLine` (description-or-first-command-line-or-"Background task") is
implemented **twice, verbatim**: `BackgroundTaskRow.swift:69-75` and
`BackgroundTaskDetailSheet.swift:292-298`. `statusColor` is implemented **three
times** with diverging palettes: `BackgroundTaskRow.swift:60-67`
(completed = `tertiaryLabelColor`), `BackgroundTaskDetailSheet.swift:313-320`
(completed = `secondaryLabelColor`), and the running-dot in
`BackgroundTaskButton.runningIndicator` (`:93-98`). `BackgroundTaskFormat`
(`BackgroundTaskRow.swift:87`) already exists as the shared-formatting home for
timing/status text — `titleLine` and `statusColor` belong there too but weren't
hoisted. Same kind of derived value (`percent`) is computed twice in
`ContextRingButton` — once in the button (`:36-41`) and once in the popover
(`:119-122`) — though those read different token sources so the duplication is
milder. Why it matters: the diverging `statusColor` palette is a real visual
inconsistency (completed task is a different gray in row vs sheet). (FACT)

### #4 — `BackgroundTaskList.group(...)` is static + view-local; grouping/sorting policy buried in the view — **LOW**

`BackgroundTaskList.swift:74-105` holds the running/completed split and the
"most-recent-completion-first" sort as a `private static func` on the view, with
a private `TaskGroup` struct. This is presentation policy living in the view
layer (acceptable per the no-ViewModel stance), but it's the kind of pure
function that a refactor toward testable derivation would want extractable. No
test currently pins this ordering (only `BackgroundTaskSheetSnapshotTests`
exists, not a list-grouping logic test). (FACT)

### #5 — `ContextRingButton` is one 387-line file holding 6 view types + 2 free functions — **LOW**

`ContextRingButton.swift` packs `ContextRingButton`, `ContextPopoverContent`,
`ContextBreakdownView`, `CategoryRow`, `ExpandableGroup`, plus `isBufferName` and
`formatTokens`. Per the project rule "child views with their own state become
separate `View` structs (and usually their own files)" (root `CLAUDE.md`
SwiftUI rules), the breakdown sub-views are candidates for extraction. The
`ContextBreakdownView.ordered`/`rankInActive`/`color` sorting+coloring logic
(`:139-267`) is non-trivial pure logic with no unit test. INFERENCE: not urgent
(it's cohesive), but it's the largest single file in the in-scope set and the
densest pure logic. (FACT for size; INFERENCE for severity.)

### #6 — `formatTokens` defined privately in `ContextRingButton`, not shared — **LOW**

`ContextRingButton.swift:375` is a `private func formatTokens(_:)` (1k/M/B
humanizer). This is generic enough that other surfaces (e.g. any token display)
would re-implement it. Minor duplication risk. (FACT)

### #7 — `now: Date` plumbed as a parameter through the task row chain — **LOW**

`BackgroundTaskList` owns the timer and passes `now` down to every
`BackgroundTaskRow` (`BackgroundTaskList.swift:60`, `BackgroundTaskRow.swift:11`)
purely to force elapsed re-render. This is a reasonable SwiftUI idiom, but it
couples the row's signature to the parent's ticking strategy. A `TimelineView`
inside the row (or `BackgroundTaskFormat` reading a `Date.now` via
`TimelineView`) would localize the concern. Contrast with smell #2 — the sheet
*doesn't* get a ticker at all, which is the inconsistency. (FACT)

### #8 — `SedEditParser` is physically colocated with controls it has no relationship to — **LOW (organizational)**

`SedEditParser.swift` (parser + `ShellTokenizer`) lives in `InputBarControls/`
but is consumed only by `PermissionSedEditCardBody` and `PermissionCardKind`
(`grep` confirmed). It is a pure model/utility with no view, no session
coupling. It sits in this directory by proximity to the permission cards.
INFERENCE: a refactor reorganizing by feature might move the permission-card
family (cards + `SedEditParser` + `PopoverList`-shared bits) into a
`PermissionCards/` subdirectory; `SedEditParser` would follow the cards, not the
input-bar controls. Not a behavior issue. (FACT for location/usage.)

### #9 — `BarChromeButton` / `PopoverList` shared but `ModelEffortPicker` partially can't reuse them — **LOW**

`PopoverRow` can't express a two-line layout, so `ModelEffortPicker` re-implements
the row as `ModelPopoverRow` (`ModelEffortPicker.swift:258`) but borrows the
shared `PopoverRowHoverStyle` (`PopoverList.swift:77`, internal for exactly this
reason — documented at `:74-76`). This is a contained, documented seam, not a
bug; flagged only because a refactor consolidating popover rows should know the
two-line case is the reason `PopoverRow` isn't universal. (FACT)

### #10 — Two independent 1-second timers + one DispatchSource, all `@MainActor` — **LOW (perf hygiene)**

The task popover runs a `Timer.publish(every: 1)` (`BackgroundTaskList.swift:25`)
*and*, when a sheet is open, `BackgroundTaskOutputStream` runs its own
`DispatchSource` timer at 1s (`BackgroundTaskOutputStream.swift:80-81`) plus the
filesystem-event source — both on `.main`. They are mutually exclusive in
practice (the popover closes when the sheet opens —
`BackgroundTaskButton.swift:48`), so concurrent main-thread timer load is
bounded. INFERENCE: fine today; just noting the area has three separate
main-queue tickers if a future change keeps the popover alive under the sheet.
(FACT for the timers; INFERENCE for the bound.)

---

## 6. Load-bearing invariants (a refactor MUST preserve)

1. **Reads stay observation-only; no shadow copies.** Every control reads
   session state via the `@Observable` forwarders on `Session`
   (`Session.swift:345/349/353/357/378/386/475`) and holds no cached copy.
   Preserving this keeps the documented data-reaches-UI contract
   (`Services/Session/CLAUDE.md:73-74`) intact and is why session-switch is O(1)
   on the UI side. Do not introduce a ViewModel that snapshots these into local
   state.

2. **Mutations route through the `Session` façade.** `setPermissionMode`
   (`Session.swift:656`) and `requestContextUsage` (`Session.swift:393`) are
   phase-aware (`.draft` vs `.active`). Any new mutation (including a fix for
   smell #1) must go through a `Session` method, never `session.runtime.X`. The
   façade's phase dispatch is what makes the controls work identically for draft
   and active sessions.

3. **`BackgroundTaskOutputStream` is a parallel I/O channel by design.** It tails
   the CLI's spool file directly on disk
   (`BackgroundTaskOutputStream.swift:104-183`); the output bytes never flow
   through `Session`/`SessionRuntime`. A refactor must NOT try to route this
   through the runtime — the runtime only knows the *path*
   (`SessionRuntime+Tasks.swift:106` sets `outputFile`). The stream's identity
   contract (one instance per path) and its start/stop lifecycle keyed to the
   sheet's open/close (`BackgroundTaskDetailSheet.swift:73-74`) are load-bearing
   for both correctness (no double-tailing) and resource cleanup (fd/source).

4. **Sheet vs popover hosting placement.** The detail `.sheet` is hosted at
   `BackgroundTaskButton` level (not inside `BackgroundTaskList`) so it presents
   in the app window, not the popover's own window
   (`BackgroundTaskButton.swift:21-28`, `:42-59`). The popover is torn down
   (`isPresented = false`) *before* `selectedTaskId` is set
   (`:43-50`) to avoid the popover hanging behind the sheet. Preserve this
   ordering and placement.

5. **`detailBinding` getter must re-read live `session.tasks`.** The sheet
   observes status flips while open *because* the binding getter re-resolves the
   task from `session.tasks` on every sample (`BackgroundTaskButton.swift:68-78`).
   A refactor that captures the `BackgroundTask` value once (instead of the id +
   live lookup) would freeze the sheet's status — regressing the documented
   behavior at `:64-67`.

6. **`PermissionModePicker` seed is idempotent and gated on `.default`.** The
   draft-seed from `NewSessionDefaultsStore` only fires while `permissionMode ==
   .default` (the "no user choice yet" sentinel) and re-runs via the
   `SeedKey(sessionId, supportsAuto)` `.task(id:)` so the async model-catalog
   arrival doesn't miss a saved `.auto` (`PermissionModePicker.swift:37-70`).
   Both the idempotency and the two-component key are required — a sessionId-only
   key drops the saved `.auto` on cold launch (documented at `:42-48`).

7. **`.auto` visibility is model-capability-gated.** `visibleModes(for:)`
   (`PermissionModePicker.swift:75-80`, kept `internal` for the
   `PermissionModePickerVisibilityTests` merge test) hides `.auto` unless
   `model.supportsAutoMode == true`. The seed also refuses to seed `.auto` when
   unsupported (`:68`). Preserve both, and keep the function reachable by the
   existing test.

8. **`ContextRingButton` always renders (no slot churn).** The button renders
   even at 0% (`ContextRingButton.swift:8-12`) so the chrome row keeps its shape
   across sessions. By contrast `TodoButton`/`BackgroundTaskButton` are
   *conditionally* mounted (hidden until non-empty:
   `TodoButton.swift:16`, `BackgroundTaskButton.swift:31`) and stay mounted
   thereafter. These visibility policies are intentional and differ per control —
   don't unify them.

9. **`requestContextUsage` is fired once per popover open.** `ContextPopoverContent`
   guards with `didRequest` (`ContextRingButton.swift:60`, `:80-84`) so SwiftUI
   re-renders (e.g. when `contextUsage` lands and the body re-evaluates) don't
   re-hammer the CLI. The runtime additionally coalesces concurrent requests
   (`SessionRuntime+ContextUsage.swift:30`). Preserve the per-open guard.

10. **`SedEditParser` purity.** The parser never touches the filesystem
    (`SedEditParser.swift:28`); `apply(to:)` returns input unchanged on regex
    compile failure (`:210-212`). It is pinned by `SedEditParserTests`. Keep it
    pure and keep the fallback-on-failure behavior — the card body relies on a
    non-throwing parse to fall back to the raw shell command.

11. **`TodoStatusGlyph` constant outer footprint across states.** All three
    states render at the same outer frame so a status flip never jitters the
    row's leading edge (`TodoStatusGlyph.swift:5-19`, ring uses `strokeBorder` to
    keep the stroke inside the frame). The `muted` chrome variant deliberately
    suppresses the rotation + accent color (`:40-46`, `:74-81`). Both are
    visual-stability invariants pinned by `TodoStatusGlyphSnapshotTests`.

---

## Cross-references

- Mount path & no-ViewModel coordination: `Content/Chat/CLAUDE.md:11`, `:54-62`.
- Data-reaches-UI rules (read `@Observable`, write via façade, never both
  channels): `Services/Session/CLAUDE.md:69-77`.
- Host sizing for the bar (`.intrinsicContentSize` component, not `[]`): root
  `CLAUDE.md` "Embedding SwiftUI in AppKit: host sizing".
- AppKit-native sheet pattern the aux controls deliberately do **not** use:
  `NativeTranscript2/CLAUDE.md:356-358` + `Content/Chat/CLAUDE.md:14`.
- Test coverage that pins these controls: `cctermTests/TodoListSnapshotTests`,
  `TodoStatusGlyphSnapshotTests`, `BackgroundTaskSheetSnapshotTests`,
  `PermissionModePickerVisibilityTests`, `SedEditParserTests`.
