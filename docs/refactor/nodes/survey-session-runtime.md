# Survey: `Session` façade + `SessionRuntime` + `SessionDraft` (the UI-facing state core)

Scope: `macos/ccterm/Services/Session/Session/`. This is the runtime state core that every chat surface reads. The three protagonists are `Session` (façade), `SessionRuntime` (CLI engine), and `SessionDraft` (compose carrier). Read `Services/Session/CLAUDE.md` and `Content/Chat/CLAUDE.md` before this file — they are the design intent; this file is the as-built map plus debt.

Everything here is `@MainActor`. All three protagonists declare `nonisolated deinit {}` to dodge a macOS 26 SDK abort in `swift_task_deinitOnExecutorImpl` (documented at `SessionRuntime.swift:450-455`, `SessionDraft.swift:45-49`, `Session.swift:243`).

---

## 1. Component / type inventory

### Façade + phase carriers

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Session` | `@Observable @MainActor final class` | UI-facing façade. Holds `phase` (`.draft`/`.active`), forwarding accessors, render-side state (`controller`+`bridge`), six external closure sinks, `send`/promotion, `loadHistory`. | `Session.swift:44-690` |
| `Session.Phase` | nested `enum` | `.draft(SessionDraft)` \| `.active(SessionRuntime)`. Flips exactly once. | `Session.swift:48-51` |
| `SessionDraft` | `@Observable @MainActor final class` | Compose-card carrier: `config`/`title`/presence. Setters are unconditional writes (no CLI, no DB, no RPC). | `SessionDraft.swift:27-117` |
| `SessionRuntime` | `@Observable @MainActor final class` | CLI-bound engine: status, messages, config, token usage, tasks/todos, model catalog, streaming, 7 closure sinks. | `SessionRuntime.swift:18-545` |
| `SessionRuntime.Status` | nested `enum` | `.notStarted/.starting/.idle/.responding/.interrupting/.stopped`. | `SessionRuntime.swift:20-27` |
| `SessionRuntime.HistoryLoadState` | nested `enum` | `.notLoaded/.loading/.loaded`; idempotency gate for `Session.loadHistory()`. | `SessionRuntime.swift:34-44` |
| `SessionRuntime.ReceiveMode` | nested `enum` | `.live`/`.replay`; replay suppresses lifecycle + `hasUnread` + outgoing change events. | `SessionRuntime+Receive.swift:10` |

### Plain value models (struct, mostly `Codable`/`Equatable`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `SessionConfig` | `struct Equatable` | Plain-value snapshot of user config (cwd/worktree/dirs/model/effort/permissionMode/fastMode). Carried verbatim draft→runtime. | `SessionConfig.swift:16-163` |
| `PendingPermission` | `struct Identifiable` | One CLI permission request + a `respond` closure that auto-removes self. | `SessionTypes.swift:8-14` |
| `SlashCommand` | `struct` | Advertised command name + optional description. | `SessionTypes.swift:17-20` |
| `TurnEndedNotice` | `struct` | Display-ready payload for "turn finished on session" (notification fanout). | `SessionTypes.swift:28-32` |
| `PermissionPromptNotice` | `struct` | Display-ready payload for "this session needs approval" (notification fanout). | `SessionTypes.swift:45-49` |
| `BackgroundTask` | `struct Identifiable, Equatable` | Off-timeline background-bash task state for the tasks popover. | `SessionTypes.swift:56-106` |
| `TodoEntry` (+`CreateScratch`/`UpdateScratch`) | `struct Identifiable, Equatable` | One row in the CLI todo plan; scratch structs hold tool_use input until the paired tool_result lands. | `SessionTypes.swift:117-144`, `SessionRuntime+Todos.swift:29-47` |
| `MessagesChange` | `enum` | Per-mutation imperative signal: `.appended/.updated/.removed`. The AppKit renderer's only outgoing channel. | `MessagesChange.swift:24-35` |
| `deriveTitleFromFirstMessage(_:)` | free function | Normalize first message → sidebar title. | `SessionTypes.swift:155-166` |

### Streaming / typewriter support (off the observation path)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `StreamingTurnAssembler` | `struct` | Folds SSE deltas into live text + per-turn token usage estimate. One per turn, lives on runtime. | `StreamingTurnAssembler.swift` |
| `TypewriterReveal` | `struct` | Single active glyph-by-glyph reveal; parks `pendingFinalize`. | `TypewriterReveal.swift` |
| `FrameTicker` (protocol) + `TimerFrameTicker` | protocol + `@MainActor final class` | Per-frame callback driving the reveal. Injected for tests (`ManualFrameTicker`). | `FrameTicker.swift:13-77` |
| `ReverseEntryBuilder` | (history-load helper) | Pure reverse grouping + tool-pairing for backfill (parity with live `receive`). | `ReverseEntryBuilder.swift` |
| `MessageEntry` / `SingleEntry` / `GroupEntry` / `LocalUserInput` | render-ready entry models | The `messages` element type. (Surveyed elsewhere; referenced heavily here.) | `MessageEntry.swift` |

### Render-side state (owned by `Session`, defined elsewhere)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Transcript2Controller` | imperative controller | Owns `blocks`/coordinator; `apply`/`setHistory`/`setLoading`/`setTurnUsage`/`setTurnStartedAt`. Lifetime = `Session`. | `Content/Chat/NativeTranscript2/` |
| `Transcript2EntryBridge` | translator | Converts each `MessagesChange` → controller `apply`. Always wired to runtime. | `Content/Chat/NativeTranscript2Bridge/Transcript2EntryBridge.swift` |
| `TranscriptBackfillPipeline` | one-load pipeline | Off-main reverse history producer; applies blocks straight to controller, bypassing the bridge. | `Content/Chat/NativeTranscript2Bridge/` |

### Registry (one level up)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `SessionManager` | `@Observable @MainActor final class` | Registry: get-or-create one `Session` per id, wire manager-facing callbacks, records list, archive/unarchive. | `SessionManager.swift:15-501` |

---

## 2. Component tree (this area)

All nodes here are plain Swift objects (no AppKit/SwiftUI in this module). The AppKit/SwiftUI boundary is at the *consumers*, shown with `▸` (outside this scope). `NSHostingView`/`NSHostingController` boundaries live in the chat-VC survey, not here.

```
SessionManager  [@Observable @MainActor]                       ── Services/Session/SessionManager.swift
└── sessions: [String: Session]   (cache; observation-tracked)
    └── Session  [@Observable @MainActor]  (the façade)        ── Session.swift
        ├── sessionId: String                  (stable identity across phase flip)
        ├── phase: Phase
        │   ├── .draft(SessionDraft)  [@Observable @MainActor] ── SessionDraft.swift
        │   │   ├── config: SessionConfig  (struct)
        │   │   ├── title / isFocused / hasUnread
        │   │   └── repository (ref, @ObservationIgnored)
        │   └── .active(SessionRuntime)  [@Observable @MainActor] ── SessionRuntime.swift (+ 9 extensions)
        │       ├── config: SessionConfig  (struct; dot-accessors mirror draft surface)
        │       ├── messages: [MessageEntry]                  (SwiftUI-read + AppKit-via-onMessagesChange)
        │       ├── status / isRunning / historyLoadState / hasRecord / termination
        │       ├── title / isGeneratingTitle
        │       ├── pendingPermissions / tasks / todos / slashCommands / availableModels
        │       ├── contextUsedTokens / contextWindowTokens / contextUsage(+fetchedAt/isFetching)
        │       ├── turnUsage / turnStartedAt   (@ObservationIgnored — imperative pill channel)
        │       ├── streaming scratch: streamingAssembler / activeReveal / frameTicker / preview ids
        │       ├── cliClient: any CLIClient?   (bound subprocess; @ObservationIgnored cliClientFactory)
        │       └── 7 closure sinks (see §3)
        │
        ├── controller: Transcript2Controller   ── render-side, CONTINUOUS LIFETIME (created in every init)
        ├── bridge: Transcript2EntryBridge       ── render-side, ALWAYS WIRED to runtime.onMessagesChange
        ├── backfillPipeline: TranscriptBackfillPipeline?  (alive only during one load)
        └── 6 forwarding closure sinks + onMessagesChange external slot (see §3)

  ▸ Consumers (outside scope):
    ▸ SwiftUI input-bar controls read @Observable fields (session.tasks/todos/status/availableModels/…)
    ▸ ChatSessionViewController (AppKit) reads session.controller + installs onTurnUsageChange + isRunning observation
    ▸ DetailRouterViewController installs SessionManager.onLaunchFailure
    ▸ AppState wires SessionManager.onTurnEndedNotice / onPermissionPromptNotice → NotificationService
```

---

## 3. Data flow

There are **two deliberately separate channels** out of the runtime, documented in `Services/Session/CLAUDE.md § Talking to the renderer`. The architectural rule is "pick one per piece of state; never emit on both."

### A. State INTO this area

1. **From a persisted record** (resume): `SessionManager.makeSession` → `Session(record:)` → `SessionRuntime.init` calls `apply(record)` to hydrate `title`/`termination`/`config` (`SessionRuntime.swift:444-447, 459-463`). One-directional: repository → runtime.
2. **From a draft** (compose): user fills compose card → `session.draft?.setCwd(...)` etc. → unconditional writes to `SessionDraft.config` (`SessionDraft.swift:53-95`). At promotion, `SessionRuntime.fromDraft` copies `config`/`title`/presence **verbatim** (`SessionRuntime+Start.swift:234-237`).
3. **From the CLI subprocess**: `attachCallbacks` installs SDK callbacks (`SessionRuntime+Start.swift:716-775`); each hops to main actor and calls `receive` / `consumeStreamEvent` / `enqueuePermission` / `handleProcessExit`. This is the dominant inbound flow and is **unidirectional CLI → runtime state**.

### B. Channel 1 — SwiftUI: `@Observable` fields (pull)

SwiftUI surfaces read forwarding accessors on `Session`, which `switch phase` and read either the draft or the runtime field (`Session.swift:302-498`). Confirmed consumers (read-only, no caching — the "views never cache" rule holds):
- `InputBarSessionChrome`, `ModelEffortPicker`, `BackgroundTaskList/Button`, `TodoList/Button`, `ContextRingButton`, `InputBarChrome` read `session.tasks/todos/status/availableModels/slashCommands/pendingPermissions/contextUsage` via `@Observable`.
- `SessionManager.records` is itself `@Observable`; sidebar reads `existingSession(id)?.isRunning/hasUnread`.

Direction: runtime field write → Observation registers → SwiftUI body re-eval at `beforeWaiting`. Strictly one-directional (UI never writes the field; it calls a `Session` method).

### C. Channel 2 — AppKit: synchronous closure sinks (push)

This is the load-bearing fast path for the transcript. **Every** site that writes `messages` synchronously fires `onMessagesChange?(...)` in the same call stack (e.g. `SessionRuntime+Start.swift:138`, `+Receive.swift:169/278/282/409/448`, `+Streaming.swift:278/282`, `+Messaging.swift:79`). The wiring multiplexes:

```
runtime.onMessagesChange = { change in
    self.bridge.apply(change)          // always — the canonical consumer
    self.onMessagesChange?(change)     // optional external fanout (tests/debug)
}
```
installed by `Session.wireRuntimeMessagesSink` (`Session.swift:250-264`).

**All seven runtime closure sinks**, with fire-site and subscriber:

| Runtime sink (`SessionRuntime.swift`) | Fired at | Forwarded via `Session` | Ultimate subscriber |
|---|---|---|---|
| `onMessagesChange` (`:158`) | every `messages` write | `wireRuntimeMessagesSink` multiplex (`Session.swift:251`) | `bridge.apply` (always) + `Session.onMessagesChange` external |
| `onTurnFinishedLive` (`:201`) | every live `.result` (`+Receive.swift:496`) | `wireRuntimeMessagesSink` (`Session.swift:256`) | `bridge.handleTurnFinished()` |
| `onLaunchFailure` (`:168`) | `failLaunch` (`+Start.swift:711`) | `Session.onLaunchFailure` `didSet` (`Session.swift:103-107`) | `SessionManager.onLaunchFailure` → `DetailRouterViewController` alert |
| `onRecordPersisted` (`:181`) | fresh `save` in `persistConfiguration` (`+Start.swift:524`) + collision patch (`+Start.swift:382`) + title-gen (`+Start.swift:198`) | `Session.onRecordPersisted` `didSet` (`Session.swift:113-117`) | `SessionManager.refreshRecords()` |
| `onTurnEnded` (`:190`) | `.responding`→`.idle` edge (`+Receive.swift:509`) | `Session.onTurnEnded` `didSet` (`Session.swift:124-128`) | `SessionManager.onTurnEndedNotice` → `NotificationService` |
| `onPermissionPrompt` (`:212`) | `enqueuePermission` (`+Start.swift:808`) | `Session.onPermissionPrompt` `didSet` (`Session.swift:145-149`) | `SessionManager.onPermissionPromptNotice` → `NotificationService` |
| `onTurnUsageChange` (`:262`) | `publishTurnUsage` (`+Streaming.swift:66-69`) | `Session.onTurnUsageChange` `didSet` (`Session.swift:134-138`) | `ChatSessionViewController` → `controller.setTurnUsage/setTurnStartedAt` |

`Session` mirror sinks: `onMessagesChange` (external slot, no didSet) + 5 `didSet` forwarders + `onPromoted` (`Session.swift:66`, fired at promotion `:631`).

**Hybrid AppKit state (worth flagging):** `isRunning` is `@Observable` but the AppKit loading pill reads it via a hand-rolled `withObservationTracking` re-arm loop in `ChatSessionViewController.startRunningObservation` (`ChatSessionViewController.swift:525-541`) → `controller.setLoading`. This is a *third* delivery shape: a pull-model observation bridged into an imperative controller call. `turnUsage`/`turnStartedAt` by contrast are `@ObservationIgnored` and ride the pure push sink — but `turnStartedAt` is *also* read synchronously on mount and inside the `onTurnUsageChange` closure (`ChatSessionViewController.swift:437/441`), i.e. the usage sink doubles as the clock-anchor sink.

### D. Mutations / events OUT of this area

- `send` / `interrupt` / `cancelMessage` / `setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories` / `respond` / `setFocused` — all enter through `Session` methods that `switch phase` and forward to draft or runtime (`Session.swift:642-689`). Runtime config setters do optimistic local write + DB write + CLI RPC (`SessionRuntime+Configuration.swift:35-109`).
- **Authoritative reply self-heal (bidirectional but principled):** `setPermissionMode` issues an RPC; the CLI echoes a `system.status` that `adoptPermissionMode` adopts *without* re-issuing an RPC (`+Receive.swift:561-571`). The optimistic local write is intentionally overwritten by CLI truth. Same shape for model/effort via init replies. This is a controlled loop, documented, and the `adopt*` path deliberately skips the setter to avoid an RPC echo storm.

### Direction summary

- Repository → runtime: one-directional (hydrate).
- Draft config → runtime config: one-directional (verbatim copy at promotion).
- CLI → runtime state: one-directional inbound.
- Runtime state → SwiftUI: one-directional pull (`@Observable`).
- Runtime `messages`/events → AppKit: one-directional push (closures).
- UI command → runtime → CLI → runtime (self-heal): a *controlled* round-trip, not a hidden back-channel.

**No hidden back-channels found** in the strict sense (no view writes an observable behind the runtime's back; the rule at `Services/Session/CLAUDE.md:75` holds). The two coupling points to flag are (1) the `withObservationTracking`-to-imperative bridge for `isRunning`, and (2) `turnStartedAt` riding the `onTurnUsageChange` sink rather than its own — both are *intra-AppKit* plumbing, not module-internal.

---

## 4. Ownership & lifetime

- **`SessionManager`** is constructed once (by `AppState`, per `Content/Chat/CLAUDE.md` ownership graph) and retains the `sessions: [String: Session]` cache (`SessionManager.swift:40`). It is the sole owner of every `Session`.
- **`Session`** is created lazily by `SessionManager.session(_:)` / `prepareDraftSession(_:)` / `createSidebarDraft` via `makeSession` (`SessionManager.swift:176-190, 217-237`). One per `sessionId`, cached, stable identity. Torn down only when evicted from the cache: `archive`/`unarchive` call `sessions.removeValue` (`SessionManager.swift:431, 493`).
- **`Session.controller` + `Session.bridge`** are created eagerly in **every** `Session.init` (`Session.swift:166-167, 190-191, 213-214, 237-238`) and have the **same lifetime as the `Session`**. The bridge is wired to the runtime once (init for `.active`, promotion for draft→active) and never re-wired on view mount. Consequence: live CLI events flow into `controller.blocks` even with no view mounted (documented `Session.swift:34-43`, `Services/Session/CLAUDE.md:12-18`).
- **`SessionRuntime`** is owned by the `Session` (held inside the `.active` phase enum). Created either in `Session(record:)`/`Session(runtime:)` init or by `SessionRuntime.fromDraft` at promotion (`SessionRuntime+Start.swift:229-233`). `Session` retains it; the runtime weakly references back only through closures (`Session.wireRuntimeMessagesSink` captures `[weak self]` at `Session.swift:251` — avoids the retain cycle since runtime is owned by `Session`).
- **`SessionDraft`** is owned by the `Session` (inside the `.draft` phase enum). Retired (deallocated) at the phase flip when `phase = .active(runtime)` (`Session.swift:619`) drops the enum's draft payload.
- **`cliClient`** is owned by the runtime, assigned after `start()` (`SessionRuntime+Start.swift:614`), cleared on exit/stop/failLaunch (`+Start.swift:703, 837`). The factory (`cliClientFactory`) is captured at runtime init.
- **`backfillPipeline`** is retained by `Session` only for the duration of one history load (`Session.swift:90, 559`), so its off-main producer Task isn't torn down mid-flight.
- **`frameTicker`** is owned by the runtime (`SessionRuntime.swift:303`), production `TimerFrameTicker` self-invalidates via its weak-self timer block.
- **Manager-facing callbacks** (`onLaunchFailure`/`onRecordPersisted`/`onTurnEnded`/`onPermissionPrompt`) are installed by `SessionManager.wireSessionCallbacks` once per session (`SessionManager.swift:330-349`); `onPromoted` is injected at construction (`SessionManager.swift:177`).
- **`onTurnUsageChange` + `isRunning` observation** are installed by `ChatSessionViewController.attachSession` per attach and re-installed on each session switch (`ChatSessionViewController.swift:438, 445`). These are the only sinks owned by a view rather than the manager.

---

## 5. Smells / debt

### S1 — `Session` is a wide forwarding façade (~690 lines, ~40 forwarders). MEDIUM
`Session.swift:300-498` is a long wall of `switch phase` / `runtime?.x ?? default` accessors — ~26 read forwarders + ~7 write forwarders + 6 closure-mirror `didSet`s. Each new runtime field requires touching `SessionRuntime` (field) **and** `Session` (forwarder), per `Services/Session/CLAUDE.md:78-91`. Evidence: `Session.swift:325-388` is ~15 near-identical `runtime?.field ?? default` one-liners. This is mechanical, low-risk boilerplate, but it is the single biggest "two-files-per-field" tax in the codebase. *Why it matters for the refactor goal:* it's the place where "clean unidirectional" most tempts an over-engineered fix (e.g. a protocol both phases conform to). Note the trap: the draft and runtime read-surfaces **already diverge** — `status`/`messages`/`tasks`/`todos`/`turnUsage` are runtime-only (draft returns a default), while `title`/`isFocused`/config are phase-shared. A naive shared protocol would have to fabricate runtime-only fields on the draft.

### S2 — `SessionRuntime` is a god-object: 23 `@Observable` fields + 7 closure sinks across 9 files (~3000 lines). MEDIUM
`SessionRuntime.swift:53-367` declares status, history-load, metadata, config (11 dot-accessors), messages, permissions, context tokens (×4), turn usage (×2), streaming scratch (×6), slash commands (×2), tasks, todos (×2), models, presence (×2). The extensions span receive (725 lines), start/bootstrap (905 lines), streaming (308), tasks (238), todos (199). It is the de-facto owner of: CLI lifecycle, message timeline, streaming/typewriter, token accounting, background-task tracking, todo-plan tracking, context-usage caching, title generation, permission queue, and config persistence. Several of these (tasks, todos, context-usage, streaming/typewriter) are **self-contained projections** with their own scratch state and zero coupling to the core state machine beyond "read `messages`/fire `onMessagesChange`". *Why it matters:* these are natural extraction candidates (e.g. a `TodoTracker`/`TaskTracker`/`TurnUsageMeter` value/service the runtime composes) that would shrink the observable surface and clarify ownership — but only if done without breaking the synchronous-fire contract (§6).

### S3 — Closure sinks are declared/forwarded/wired in three places per sink. MEDIUM
For each AppKit-channel notification there are three declarations: the runtime field (`SessionRuntime.swift`), the `Session` mirror `didSet` (`Session.swift:103-149`), and the runtime re-assignment inside `wireRuntimeMessagesSink` (`Session.swift:259-263`). Example: `onTurnEnded` appears at `SessionRuntime.swift:190`, `Session.swift:124-128`, and `Session.swift:261`. The wiring is correct but the pattern is easy to get wrong on a new sink (CLAUDE.md spends 4 bullets explaining it, `Services/Session/CLAUDE.md:71-76`). The `didSet { runtime?.onX = onX }` forwarder + the `wireRuntimeMessagesSink` re-assignment are two redundant-looking paths that exist for two distinct timings (set-before-promotion vs set-at-promotion). This is genuinely subtle coupling, not gratuitous — but it is the most error-prone surface in the area.

### S4 — `onMessagesChange` overloads two responsibilities (canonical bridge + external fanout). LOW
`Session.onMessagesChange` (`Session.swift:100`) is documented as a tests/debug slot, but it is wired *inside the same closure* as the canonical `bridge.apply` (`Session.swift:251-255`), so a stray production assignment to `session.onMessagesChange` would silently piggyback on the render path. The name collides with `SessionRuntime.onMessagesChange` (same name, different role: the runtime one is the raw sink, the Session one is an after-bridge observer). The two same-named fields with different semantics are a readability hazard.

### S5 — `turnStartedAt` has no sink of its own; it free-rides the `onTurnUsageChange` channel. LOW
`turnStartedAt` is `@ObservationIgnored` (`SessionRuntime.swift:270`) and the only way it reaches the pill is: (a) read once on mount (`ChatSessionViewController.swift:437`), and (b) re-read inside the `onTurnUsageChange` closure (`:441`). This works only because `turnStartedAt` is guaranteed to change *at the same site* as a `turnUsage` publish (`resetStreamingTurn` sets `turnStartedAt` then `publishTurnUsage` at `+Streaming.swift:51-52`; `fromDraft` sets it at `+Start.swift:270`). The coupling ("clock anchor only ever moves when usage publishes") is an implicit invariant with no compile-time guard — a future turn-start that updates `turnStartedAt` without a usage publish would silently stop updating the pill clock. Documented in a comment (`ChatSessionViewController.swift:429-435`) but fragile.

### S6 — `SessionRuntime` carries draft-shaped config setters it can't honor. LOW
The runtime exposes settable `cwd`/`isWorktree`/`originPath`/`sourceBranch`/`worktreeBranch`/`pluginDirectories` dot-accessors (`SessionRuntime.swift:91-134`) even though the design says those are launch-only and "not user-editable" at runtime (comment `:84-88`). Internally `ensureStarted` *does* write `self.cwd`/`self.worktreeBranch` (`+Start.swift:357-359`), so they can't be made get-only — but the public mutability invites a caller to mutate a launched session's cwd with no effect. The "which setters are legal in which phase" rule is enforced only by convention + the `Session` façade routing, not by the type.

### S7 — `receive` is a 145-line switch with deep inline CLI-quirk commentary. MEDIUM (size, not correctness)
`SessionRuntime+Receive.swift:25-170` mixes the dispatch table, six synchronous side-effect arms (usage/init/thinking/status/task×3), and the action→mutation→change-emit pipeline. The arms encode hard-won CLI behavior (e.g. `isRunning` self-heal `:47`, follow-up-turn reset `:60-72`). It is correct and well-commented but is the densest single method; any extraction (e.g. pulling the task/todo arms into the trackers from S2) must preserve exact ordering (§6 I3).

### S8 — Four `Session.init` variants with near-duplicate bodies. LOW
`Session.swift:156-241` has four initializers (`record:`, `draftSessionId:`, `draftRecord:`, `runtime:`) that each repeat the controller/bridge construction + sink wiring. The `record:` and `runtime:` paths both call `wireRuntimeMessagesSink`; the two draft paths don't. Minor duplication; the `runtime:` init is test-only (`Session.swift:228`).

---

## 6. Load-bearing invariants (a refactor MUST preserve)

### I1 — `onMessagesChange` fires **synchronously** in the same call stack as the `messages` write.
The whole AppKit fast path (`Services/Session/CLAUDE.md:64-68`, `MessagesChange.swift:13-23`) depends on the mutation and `controller.apply` landing in one source-phase tick — no `AsyncStream`, no `@Observable` pull, no `DispatchQueue.main.async`. Every `messages` mutation site already pairs the write with a synchronous `onMessagesChange?(...)` (e.g. `+Start.swift:119` then `:138`; `+Receive.swift` returns a change then fires at `:169`). A refactor must not introduce a hop between the write and the fire. (Root CLAUDE.md "runloop tick model": an async hop is one frame of latency.)

### I2 — The bridge is wired **once** per session and survives view mount/dismount.
`controller`+`bridge` have session lifetime; the bridge is the canonical, always-on consumer (`Session.swift:75-84`, `:250-255`). Switch-away does not pause renderer processing; switch-back is O(1) (no JSONL re-read). A refactor must not move bridge wiring to attach-time or make it conditional on a mounted view, or it reintroduces the deleted "switch-back re-emit" path and breaks the O(1) re-entry that `TranscriptHostReentryLayoutCacheTests` guards.

### I3 — Side-effect ordering inside `receive` / `finishTurn` / `failLaunch` is exact.
- `send`/`enqueueAndSend`: append entry → set `isRunning = true` → fire `.appended` → `ensureStarted` → write CLI (`+Start.swift:113-152`). `isRunning` flips *before* any side effect so the spinner shows immediately.
- `finishTurn` (`+Receive.swift:468-516`): set `contextWindow` → `isRunning = false` → `hasUnread` → `onTurnFinishedLive` → then (if `.responding`) `status = .idle` + `onTurnEnded`. The `.result`-vs-`.responding→.idle` split (every-turn vs user-turn) is load-bearing for not double-posting banners.
- `failLaunch` (`+Start.swift:696-712`): status/isRunning flip first ("visible to UI first"), then detach client, fail queued entries, write repo error, then `onLaunchFailure`.
- `isRunning` is mirrored off the CLI's `.assistant`/`.result` stream (self-healing), **not** a counter — explicitly chosen (`SessionRuntime.swift:229-240`). Do not reintroduce a `pendingTurnCount`.

### I4 — `isRunning` source-of-truth + the AppKit observation bridge.
`isRunning` is the one field consumed on **both** channels in spirit: SwiftUI input bar reads it as `@Observable`; the AppKit pill reads it via `withObservationTracking` → `controller.setLoading` (`ChatSessionViewController.swift:525-541`). A refactor that converts `isRunning` to a closure sink (to "purify" the AppKit path) must keep the SwiftUI `@Observable` read working, or vice-versa. This is the one field that intentionally bends the "never emit on both channels" rule and must stay legible.

### I5 — `turnStartedAt` only changes at sites that also publish `turnUsage`.
The pill clock is delivered by re-reading `turnStartedAt` inside the `onTurnUsageChange` closure (S5). Preserve the co-location: any new turn-boundary write to `turnStartedAt` must be accompanied by a `publishTurnUsage` (`+Streaming.swift:51-52`, `+Start.swift:270`). If you give `turnStartedAt` its own sink, update both mount-read sites.

### I6 — Promotion is a one-shot, ordered sequence; sinks attach BEFORE bootstrap.
`promoteOrForward` (`Session.swift:599-635`): `fromDraft` → `wireRuntimeMessagesSink` → fire queued `.appended` → `phase = .active` → `ensureStarted` → `generateTitle` → `onPromoted`. `fromDraft` deliberately does **not** bootstrap (`+Start.swift:213-218`) because `ensureStarted` fires `onRecordPersisted` synchronously inside its persist path — the sink must already be attached. Reordering wiring after bootstrap "races those events into the void" (comment `Session.swift:610-615`). `SessionPromotionTests` is the regression net.

### I7 — `historyLoadState` idempotency + `fromDraft` marks `.loaded`.
`Session.loadHistory()` no-ops on `.loading`/`.loaded` (`Session.swift:542-547`); the bridge has been streaming live the whole time, so there is no replay. A draft-promoted runtime is marked `.loaded` at `fromDraft` (`+Start.swift:244`) so a later view-mount's `loadHistory` skips JSONL replay — otherwise replayed echoes whose `.queued` window closed would append as duplicates. Preserve both.

### I8 — Config carried verbatim draft→runtime; phase flips exactly once.
`SessionRuntime.fromDraft` copies the entire `SessionConfig` value (`+Start.swift:234`); the draft's `sessionId` becomes the runtime's `sessionId` (`Session.swift:54-56`). The phase flip is irreversible. A refactor must not split config copying field-by-field (it would reintroduce the `fresh: Bool` class of bug centralized away at `+Start.swift:566-580`).

### I9 — `adopt*` self-heal must not re-issue RPCs.
`adoptPermissionMode` (`+Receive.swift:561-571`) and the init-reply model/effort adoption write memory + DB but deliberately **skip** the setter's RPC, or the CLI's `system.status` echo would loop. CLI reply is authoritative over the optimistic local write. Preserve the asymmetry between `setPermissionMode` (writes + RPC) and `adoptPermissionMode` (writes only).

### I10 — `nonisolated deinit {}` on all three protagonists + `TimerFrameTicker` + `SessionManager`.
macOS 26 SDK abort workaround (`SessionRuntime.swift:450-455`). Any refactor introducing a new `@MainActor` class in this area must repeat it.

### I11 — `replay` mode suppresses outgoing change events.
`receive(_:mode:)` updates `messages` but returns early before `onMessagesChange` when `mode == .replay` (`+Receive.swift:168-169`). Production history now flows through `TranscriptBackfillPipeline`, so `.replay` exists only for the `ReverseEntryBuilder` grouping-parity test (`TranscriptReverseBuilderTests.A6`). Keep the visibility/grouping rules (`Message2*.isVisible`, `isGroupableAssistant` at `+Receive.swift:605-710`) module-internal so the live path and the reverse builder share one source of truth.
