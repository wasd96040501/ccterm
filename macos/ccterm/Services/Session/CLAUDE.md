# Session runtime

`Session` (`@Observable @MainActor`) is the UI-facing façade for one chat session. It carries **both** the business state (a phase that toggles between `.draft(SessionDraft)` and `.active(SessionRuntime)`) and the render-side state (the `Transcript2Controller` + `Transcript2EntryBridge` that translate `messages` into `NSTableView` rows).

- `.draft(SessionDraft)` — the user is still configuring a New Session card; no CLI, no persisted record, no messages.
- `.active(SessionRuntime)` — the session has been promoted; a `SessionRuntime` owns the CLI subprocess, the message timeline, history load state, etc.

The phase flips **exactly once**: a draft session sending its first message constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, wires the bridge to the new runtime, then swaps `phase` to `.active`. After that, every `send` / `interrupt` / `setModel` etc. routes to the runtime. UI code reads forwarding properties (`session.title`, `session.messages`, `session.isRunning`, `session.status` …) and never inspects the phase directly.

## Render-side state lives on `Session`

`session.controller: Transcript2Controller` and `session.bridge: Transcript2EntryBridge` are eagerly created in **every** `Session.init` and have the **same lifetime as the session itself**. The bridge is permanently wired to `runtime.onMessagesChange` — at session creation for `.active`-from-record sessions, at promotion time for draft → active sessions — and processes events continuously. This has three knock-on consequences:

1. **Live CLI events flow into `controller.blocks` even when no transcript view is mounted.** Switching the sidebar to a different session does not pause renderer-side processing for the one you left; tool results, streaming assistant text, and group rollups all keep applying.
2. **Switch-away → switch-back is O(1) on the renderer side.** No JSONL re-read, no markdown reparse, no block-list rebuild. The new `NSTableView` rebinds to the same coordinator on mount; the host's `view.layoutSubtreeIfNeeded()` sizes the table from `.zero` to its real frame and drives `NSTableView.tile()` inline, so the table picks up the coordinator's current `blocks` before `controller.scrollToTail()` runs.
3. **`Transcript2Coordinator.apply` mutates `coordinator.blocks` even when no table is bound.** A backfill prepend (or any other background-emitted change) that arrives on a session with no view still lands in `coordinator.blocks`; layouts compute lazily once a table re-attaches.

`Session.loadHistory()` is correspondingly simpler: `.loading` / `.loaded` are idempotent no-ops. There is no "switch-back re-emit" path — the bridge has been processing all along.

`session.onMessagesChange` remains as an **optional external fanout slot** (tests, debugging). It fires *after* the bridge has consumed the same event, inside the same call stack.

Source lives in `Session/`:

| File | Responsibility |
|---|---|
| `Session.swift` | The façade. `Phase` enum, forwarding accessors, render-side state (`controller` + `bridge`), `send(...)` (draft → runtime promotion), `wireRuntimeMessagesSink` (one-shot bridge + external-fanout multiplex). |
| `SessionDraft.swift` | Compose-card carrier. Holds `config` / `title` / presence; setters are unconditional writes (no `guard !isAttached`, no DB writes, no RPC). |
| `SessionRuntime.swift` | CLI-bound engine. Class definition, `@Observable` properties, init. |
| `SessionRuntime+Start.swift` | `activate` / `stop` / `send` / bootstrap / `fromDraft` factory. |
| `SessionRuntime+Messaging.swift` | `interrupt`, `cancelMessage`. |
| `SessionRuntime+Configuration.swift` | Runtime-mutable setters (`setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories`) + `respond` / `setFocused`. **No** draft-only setters — those live on `SessionDraft`. |
| `SessionRuntime+History.swift` | `historyJSONLURL` path forwarder. (History-load orchestration moved to `Session.loadHistory()` + `TranscriptBackfillPipeline`.) |
| `SessionRuntime+Receive.swift` | Incoming-message path from the CLI; `appendToTimeline` walks the live group boundary by inspecting `messages.last`. |
| `SessionRuntime+Streaming.swift` | Typewriter-reveal pacing of streaming assistant text (`frameTicker` / `StreamingTurnAssembler`). |
| `SessionRuntime+Tasks.swift` | Background-bash-task forwarders into `taskTracker` (incl. `markTaskStoppedLocally`). |
| `SessionRuntime+Todos.swift` | Todo-plan forwarders into `todoTracker`. |
| `SessionRuntime+ContextUsage.swift` | `requestContextUsage` forwarder handing the bound `cliClient` to `contextUsageCache`. |
| `SessionRuntime+SideQuestion.swift` | `/btw`-style side-question call against the running CLI. |
| `TodoTracker.swift` / `TaskTracker.swift` / `ContextUsageCache.swift` | `@Observable @MainActor` child objects held by `SessionRuntime` via plain `let` props (`todoTracker` / `taskTracker` / `contextUsageCache`). Runtime accessors (`todos` / `tasks` / `contextUsage`) forward into them so in-place element patches are tracked through the nested chain. |
| `SessionTypes.swift` | `PendingPermission`, `SlashCommand`, `deriveTitleFromFirstMessage`. |
| `MessageEntry.swift` | Render-ready entries (`SingleEntry` / `GroupEntry`), `LocalUserInput`. |
| `MessagesChange.swift` | Live timeline change events the bridge consumes (`.appended` / `.updated` / `.removed`). History load is **not** a `MessagesChange`. |

History load no longer lives on the runtime: `Session.loadHistory()` drives a `TranscriptBackfillPipeline` (`Content/Chat/NativeTranscript2Bridge/`) over a reverse-streaming `JSONLReversePageSource`, building already-paired blocks off-main and applying them straight to the controller. The old two-phase Phase A/B read, the `tailBaseline`/`newTailStart` offset math, the throwaway in-memory `SessionRuntime` (`buildEntries`), and `ToolResultReresolver` are deleted; grouping + tool-pairing is now `ReverseEntryBuilder.swift` (in `Session/`, beside the live path it mirrors).

### Load vs. live parity invariants

History load and the live CLI stream produce the same blocks two different ways; these invariants keep them identical:

- **History load never goes through the bridge.** `TranscriptBackfillPipeline` builds already-paired blocks off-main and applies them straight to `controller` (`.prepend` for older pages). A history load emits **no** `MessagesChange` and fires no `.update` — emitting a partial group then growing it would force a `.replace` the load path forbids.
- **One grouping predicate, two traversals.** The live `SessionRuntime+Receive.appendToTimeline` (forward, inspects `messages.last`) and the cold `ReverseEntryBuilder` (reverse, newest-first) share the single `isGroupableAssistant` predicate. They stay separate implementations because traversal direction differs; `TranscriptReverseBuilderTests` locks their 1:1 equivalence.
- **Cross-page tool-result pairing is withheld + buffered.** Reading bottom-up hits a `tool_result` before its `tool_use`, so an orphan result is held in `ReverseEntryBuilder.withheld` keyed by `tool_use_id` and attached when its `tool_use` is reached — the buffer spans page boundaries, and results resolve in document order.

`SessionManager` (one level up at `Services/Session/SessionManager.swift`) is the registry: lazily creates and caches one `Session` façade per `sessionId`. `session(_:)` returns an active-phase façade for an existing record; `prepareDraftSession(_:)` returns a draft-phase façade (or active when a record happens to already exist for that id — idempotent get-or-create).

`SessionConfig` (`Services/Session/SessionConfig.swift`) is the plain-value snapshot of the user-facing configuration (cwd / worktree / dirs / model / effort / permission mode / fast mode). Both `SessionDraft` and `SessionRuntime` carry one. Promotion copies the draft's `SessionConfig` verbatim into the runtime.

## Sibling services

`SessionRuntime` delegates I/O to four sibling services so the runtime state machine stays focused on `messages` / `status` / `isRunning` / config writes:

| Service | Lives at | Responsibility |
|---|---|---|
| `CLIClient` protocol + `AgentSDKCLIClient` + `FakeCLIClient` | `CLIClient/` | Thin abstraction over `AgentSDK.Session`. Factory injected at `SessionManager.init(... cliClientFactory:)` and forwarded into every `Session` the manager constructs; production defaults to `AgentSDKCLIClient.defaultFactory`, tests pass `{ _ in FakeCLIClient() }`. |
| `TitleGenerator` | `TitleGenerator.swift` | Stateless one-shot LLM call (`Prompt.runTitleAndBranch`) inside a scratch dir. Runtime's `generateTitle(from:)` calls into it; injectable `runner` seam for tests. |
| `WorktreeProvisioner` | `Worktree/WorktreeProvisioner.swift` | Off-main `git worktree add` invocation via `DispatchQueue.global`. Wraps `Worktree.create`; injectable `creator` seam for tests. |
| `HistoryLoader` | `HistoryLoader.swift` | Path resolution (`locate(sessionId:slug:)` with root-injected overload) + `parseLines` (per-page line→`Message2` decode). Reverse paging itself is a single streaming backward reader — `JSONLReversePageSource` + `ReverseLineReader` (`Content/Chat/NativeTranscript2Bridge/`) — with no tail/prefix split (the old `parseTail` / `parsePrefix` are gone). |

## Talking to the renderer

The notification channel depends on whether the renderer is AppKit or SwiftUI. Pick one per piece of state; never mix.

| Renderer | Channel | Notes |
|---|---|---|
| **AppKit-native** (e.g. `NativeTranscript2`, anything driving an `NSTableView`) | Synchronous closure callback → direct imperative controller call | The runtime mutates `messages` and fires `runtime.onMessagesChange` inside the same call stack. `Session.wireRuntimeMessagesSink` installs a single closure on that field that **first** calls `bridge.apply(change)` (always wired), **then** `session.onMessagesChange?(change)` (optional external observer — tests, debugging). Subscribers don't survive promotion by re-wiring; the bridge is the canonical consumer and was wired at `Session.init`. |
| **SwiftUI** | `@Observable` field (for continuous state) or `AsyncStream` (for discrete side effects) | The view tracks `session.status` / `session.isRunning` directly; one-shot effects go through `eventStream()`. The forwarding accessors on `Session` route through `phase` so observation works in both `.draft` and `.active`. |

The AppKit path deliberately skips `AsyncStream` and `@Observable`:

- `AsyncStream` adds at least one main-actor hop — one frame of latency over a synchronous callback.
- `@Observable`-driven `updateNSView` is a pull model: SwiftUI has to recompute the diff. Going imperative lets the bridge hand the controller exactly the increment it needs.

## Rules

- **AppKit channel** — declare a `@ObservationIgnored var onXxxChange: ((XxxChange) -> Void)?` on `SessionRuntime`. For `onMessagesChange` specifically, the wiring is **one-shot inside `Session`** (`wireRuntimeMessagesSink`): the closure fires `bridge.apply(change)` followed by `session.onMessagesChange?(change)`. For new sinks that don't have a bridge consumer, follow the `onLaunchFailure` / `onRecordPersisted` pattern — a `didSet` on the façade re-wires the runtime when phase is `.active`.
- **Adding a new notification on the AppKit path** — add the closure on the runtime, fire it synchronously at the mutation site, expose a matching forwarder on `Session`, add a dispatch arm to the bridge, then call `controller.apply(...)`.
- **Never emit a state change on both channels.** Pick one. `SessionRuntime.messages` is delivered only through `onMessagesChange`; there is no shadow snapshot.
- **Views never cache session properties as their own state.** Read the `@Observable` field directly or expose a computed property. The transcript controller is owned by `Session` (`session.controller`) — `ChatSessionViewController` reads it, never constructs one.
- **Views call the `Session` façade, never `session.runtime.*`.** Action forwarders live on `Session` and are phase-aware. Example: `Session.stopBackgroundTask(taskId:)` returns `Void`, no-ops on `.draft` (no runtime, `tasks` empty), and forwards to `runtime.markTaskStoppedLocally`; `BackgroundTaskButton` calls the façade. Add new actions the same way rather than reaching into the runtime from a view.
- **Local actions** (`send` / `interrupt` / `setPermissionMode`) either issue a stdin request or perform a local state transition. They never write to observables behind the runtime's back.
- **New change variants** — add a `case` to `MessagesChange`, fire `onMessagesChange?(...)` at the mutation site in `SessionRuntime`, add the matching arm in `Transcript2EntryBridge.apply`. The bridge is wired once per session, so no view-side attach work is needed.

## Adding new runtime state

1. Add the `@Observable` field to `SessionRuntime`.
2. Add a forwarding accessor on `Session` if UI needs to read it (most do).
3. Read it directly in the view that cares (no copies, no shadow state).
4. If AppKit needs to react, add a closure field on `SessionRuntime`, forward it through `Session` via `didSet`, and fire it synchronously at the mutation point.

## Adding new draft-time config

1. Add the field to `SessionConfig` (defaults included).
2. Add a setter on `SessionDraft` that writes `config.<field>`.
3. Add a runtime-time setter on `SessionRuntime+Configuration.swift` if the field is mutable at runtime; otherwise the draft setter is the only one. The post-promotion runtime always carries the draft's value verbatim because `fromDraft` copies the entire config.
4. Add a phase-aware forwarder on `Session` (`switch phase { ... }`).

## Test infrastructure

Unit tests inject `InMemorySessionRepository` (DEBUG only) when constructing a `SessionManager` so they don't touch the on-disk CoreData store. CLI-path tests construct `SessionRuntime` directly with `cliClientFactory: { _ in FakeCLIClient() }` — driving the runtime through its public surface (send / interrupt / receive) and asserting on the observable result. History-load tests instead wrap the runtime in a `Session` (`Session(runtime:)`) and call `session.loadHistory(overrideURL:)`, because the load orchestration lives on the façade now (see `SessionRuntimeHistoryTests`). Do not add `forceXxxForTest()` methods on `SessionRuntime` / `SessionDraft` / `Session` / `SessionManager` — drive them through the public surface instead.

Façade-level tests live in `SessionFacadeTests` (phase init + forwarding) and `SessionPromotionTests` (the regression net for the draft → active flip). Draft-only behavior lives in `SessionDraftTests`. Runtime-only behavior continues to live in `SessionRuntimeBootstrapModeTests` / `SessionRuntimeCLIWiringTests` / `SessionRuntimeHistoryTests`.
