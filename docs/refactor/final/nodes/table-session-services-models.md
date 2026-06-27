# Ownership table — Session core + infra + app services + models

Scope: `Services/Session/Session/*`, `Services/Session/*` (manager / repository /
config / record / history / CLIClient / Worktree / title), `Services/*` (syntax,
recent-projects, draft, notifications, model/effort/new-session stores, git-probe,
ClaudeCodeStats, open-in, completion-stores reached as `.shared`), `Models/*`,
`Components/Markdown/*`. Plus the **target-new** runtime projections
(`TodoTracker` / `TaskTracker` / `ContextUsageCache`) from REFACTOR-PLAN §5/§8 P8.

TARGET rows reflect REFACTOR-PLAN §5 (target tree) / §8 (per-item). As-is noted in
parentheticals where it differs. `Target Δ (PR#)` uses stable mnemonic labels
(phase letter from §9 migration + item) — numbers finalized in PRPlan.

Fixed schema. Layer / Kind / Host regime per COMMON + BOUNDARY-SPEC. FACT = read in
source (cited inline / verified against the listed files). None of these types is a
hosting boundary — every "Host regime" is `—` (these are services / values /
runtime; the AppKit↔SwiftUI hosts live in the chat-VC / detail / sidebar nodes).

PR-label legend (mnemonic, §9 phase): **PR-A4** Session.stopBackgroundTask forwarder ·
**PR-A2** searchEngine→syntaxEngine rename · **PR-A3** dead-code deletion ·
**PR-C12** SessionRuntime projection extraction (todos/tasks/context-usage) ·
**PR-C11** grouping dedupe (shrunk/abandoned) · **PR-D15** layering nits (Models move, GitProbe @MainActor).

---

## Session core (`Services/Session/Session/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Session` | Session-core | @Observable-SVC | `SessionManager.makeSession` (lazy, cached by id) | `SessionManager.sessions[id]` / session lifetime | ctor-injected (repository, cliClientFactory); reads `phase` | Session method (façade fwd); @Observable write (phase) | — | unchanged (+ PR-A4 adds `stopBackgroundTask`) | ✓ |
| `Session.Phase` | Pure-value | value/MDL | `Session` | inline in `Session` | n/a | none | — | unchanged | ✓ |
| `SessionDraft` | Session-core | @Observable-SVC | `Session.init`/`SessionManager.prepareDraftSession` | `Session.phase=.draft` / until promotion | ctor-injected (repository) | @Observable write (config/title/presence) | — | unchanged | ✓ |
| `SessionRuntime` | Session-core | @Observable-SVC | `SessionRuntime.fromDraft` (promotion) / `Session.init` (from record) | `Session.phase=.active` / session lifetime | ctor-injected (repository, cliClientFactory, frameTicker); @Observable pull | injected closure (7 sinks: onMessagesChange/onTurnEnded/onTurnUsageChange/onPermissionPrompt/onLaunchFailure/onRecordPersisted/onTurnFinishedLive); @Observable write | — | PR-C12 (sheds 3 projections) | ✓ |
| `SessionRuntime.Status` / `.HistoryLoadState` | Pure-value | value/MDL | `SessionRuntime` | inline | n/a | none | — | unchanged | ✓ |
| `SessionRuntime+Start` (ext: activate/stop/send/bootstrap/`fromDraft`) | Session-core | @Observable-SVC (ext) | n/a (extension) | part of `SessionRuntime` | @Observable pull | @Observable write; CLIClient calls | — | unchanged | ✓ |
| `SessionRuntime+Messaging` (interrupt/cancel) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | @Observable pull | CLIClient calls | — | unchanged | ✓ |
| `SessionRuntime+Configuration` (setModel/Effort/.../respond/setFocused) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | @Observable pull | @Observable write; CLIClient RPC | — | unchanged | ✓ |
| `SessionRuntime+Receive` (CLI inbound; `appendToTimeline`/`attachToolResult`; grouping/pairing) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | @Observable pull | @Observable write; fires `onMessagesChange` (sync, runtime-I1) | — | PR-C11 (factor residual grouping into shared engine — **shrunk/optional**, see §8 P7) | ✓ |
| `SessionRuntime+Streaming` (typewriter; `publishTurnUsage`; `resetStreamingTurn`) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | @ObservationIgnored (turnUsage/turnStartedAt) | injected closure (`onTurnUsageChange`) | — | unchanged (TurnUsageMeter **excluded** — §11) | ✓ |
| `SessionRuntime+Tasks` (`handleTaskStarted/Notification/Updated`; `markTaskStoppedLocally`) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` (`tasks: [BackgroundTask]`, observed) | @Observable pull | @Observable write (`tasks`) | — | **PR-C12 → moves into `TaskTracker`** | ✗ as-is: `markTaskStoppedLocally` is reached past the `Session` façade by `BackgroundTaskButton` (P4 violation) — closed by PR-A4 forwarder + PR-C12 relocation |
| `SessionRuntime+Todos` (`captureTodoToolUses`/`applyTodoToolResult` + scratch dicts) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` (`todos: [TodoEntry]`, observed; scratch `@ObservationIgnored`) | @Observable pull | @Observable write (`todos`) | — | **PR-C12 → moves into `TodoTracker`** | ✓ (clean projection; the extraction target) |
| `SessionRuntime+ContextUsage` (`requestContextUsage`, coalescing) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` (`contextUsage`, observed; callbacks `@ObservationIgnored`) | @Observable pull | @Observable write (`contextUsage`/`fetchedAt`) | — | **PR-C12 → moves into `ContextUsageCache`** | ✓ |
| `SessionRuntime+History` (`historyJSONLURL` fwd) | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | computed | none | — | unchanged | ✓ |
| `SessionRuntime+SideQuestion` | Session-core | @Observable-SVC (ext) | n/a | part of `SessionRuntime` | @Observable pull | CLIClient call | — | unchanged | ✓ |
| **`TodoTracker`** ★NEW | Session-core | @Observable-SVC (sub-object) | `SessionRuntime` (composed) | held by `SessionRuntime` via tracked prop | inline; observed-nested | @Observable write | — | **PR-C12 (NEW)** | ✓ (target; must be `@Observable` held by tracked prop so nested change propagates — §8 P8) |
| **`TaskTracker`** ★NEW | Session-core | @Observable-SVC (sub-object) | `SessionRuntime` (composed) | held by `SessionRuntime` via tracked prop | inline; observed-nested | @Observable write | — | **PR-C12 (NEW)** | ✓ (target; closes P4 because the popover reads `session.tasks`→tracker and writes via `Session.stopBackgroundTask`) |
| **`ContextUsageCache`** ★NEW | Session-core | @Observable-SVC (sub-object) | `SessionRuntime` (composed) | held by `SessionRuntime` via tracked prop | inline; observed-nested | @Observable write | — | **PR-C12 (NEW)** | ✓ (target; **@Observable**, not pure value — `ContextRingButton` reads via `session.contextUsage`; §5/§8 corrected the earlier `[value]` mislabel) |
| `SessionConfig` | Pure-value | value/MDL | `SessionDraft`/`SessionRuntime`/decode | held by draft & runtime (copied verbatim at promotion) | n/a | none | — | unchanged | ✓ |
| `MessageEntry` (`.single`/`.group`) | Pure-value | value/MDL | `+Receive` / `ReverseEntryBuilder` | `SessionRuntime.messages` | n/a | none | — | unchanged | ✓ |
| `SingleEntry` / `GroupEntry` / `LocalUserInput` / `ToolResultPayload` / `DeliveryState` / `GroupableToolName` | Pure-value | value/MDL | builders | inside `MessageEntry` | n/a | none | — | unchanged | ✓ |
| `MessagesChange` (`.appended`/`.updated`/`.removed`) | Pure-value | value/MDL | `SessionRuntime` mutation sites | transient (closure arg) | n/a | none (carried by `onMessagesChange`) | — | unchanged | ✓ |
| `ReverseEntryBuilder` | Per-load | translator | `TranscriptBackfillPipeline` (cold load) | per cold load | ctor-injected | none (returns built entries) | — | PR-C11 (shares `isGroupableAssistant` already; residual fold may unify — **shrunk**) | ✓ (predicate already shared; only traversal direction differs by design) |
| `StreamingTurnAssembler` | Renderer-internal | value/MDL | `SessionRuntime` (`streamingAssembler`) | `@ObservationIgnored` field of runtime | n/a | none (mutated in place) | — | unchanged | ✓ |
| `TypewriterReveal` | Renderer-internal | value/MDL | `SessionRuntime+Streaming` | `@ObservationIgnored activeReveal` | n/a | none | — | unchanged | ✓ |
| `FrameTicker` (protocol) | App-scope-service | @Observable-SVC (proto) | ctor-injected into `SessionRuntime` | per runtime | n/a | imperative controller call (tick) | — | unchanged | ✓ |
| `TimerFrameTicker` | App-scope-service | @Observable-SVC | `SessionRuntime.init` default | per runtime; `nonisolated deinit` | n/a | injected closure (tick callback) | — | unchanged | ✓ |
| `PendingPermission` / `SlashCommand` / `TurnEndedNotice` / `PermissionPromptNotice` / `BackgroundTask` / `TodoEntry` (`SessionTypes.swift`) | Pure-value | value/MDL | runtime mutation sites | runtime-held arrays | n/a | none | — | unchanged | ✓ |

---

## Session infra (`Services/Session/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SessionManager` | App-scope-service | @Observable-SVC | `AppState.init` | `AppState.sessionManager` / process | ctor-injected (repository, cliClientFactory); @Observable (`records`) | injected closure (push callback for record changes); @Observable write | — | unchanged | ✓ |
| `SessionRepository` (protocol) | App-scope-service | @Observable-SVC (proto) | n/a | injected into `SessionManager`/`Session` | n/a | n/a | — | unchanged | ✓ |
| `CoreDataSessionRepository` | App-scope-service | @Observable-SVC | `SessionManager.init` default (`CoreDataStack.shared`) | process; `nonisolated deinit` | ctor-injected (CoreDataStack) | none (persistence) | — | unchanged | ✓ |
| `InMemorySessionRepository` (DEBUG) | App-scope-service | @Observable-SVC | test fixtures | test lifetime; `nonisolated deinit` | inline | none | — | unchanged | ✓ |
| `SessionExtraUpdate` (`SessionRepository.swift`) | Pure-value | value/MDL | repository callers | transient | n/a | none | — | unchanged | ✓ |
| `SessionRecord` / `SessionStatus` / `SessionExtra` | Pure-value | value/MDL | repository / decode | repository-owned rows | n/a | none | — | unchanged | ✓ |
| `HistoryLoader` (`nonisolated static` namespace) | Per-load | translator | n/a (static) | stateless | n/a | none (returns `[Message2]` / URL) | — | unchanged | ✓ |
| `TitleGenerator` (`enum`, static one-shot) | App-scope-service | translator | n/a (static) | stateless; injectable `runner` seam | n/a | none (returns title/branch) | — | unchanged | ✓ |
| `CLIClient` (protocol) | App-scope-service | @Observable-SVC (proto) | factory-injected | per runtime | n/a | injected closure (event callbacks) | — | unchanged | ✓ |
| `CLIClientFactory` (typealias) | Pure-value | value/MDL | `AppState`/`SessionManager` | process | n/a | none | — | unchanged | ✓ |
| `AgentSDKCLIClient` | App-scope-service | @Observable-SVC | `AgentSDKCLIClient.defaultFactory` | per runtime; `nonisolated deinit` | wraps `AgentSDK.Session` | injected closure (event callbacks) | — | unchanged | ✓ |
| `FakeCLIClient` (DEBUG/test) | App-scope-service | @Observable-SVC | test factory | test lifetime; `nonisolated deinit` | inline | injected closure | — | unchanged | ✓ |
| `WorktreeProvisioner` (`enum`, off-main `git worktree add`) | App-scope-service | translator | n/a (static) | stateless; injectable `creator` seam | n/a | none (returns `Result`) | — | unchanged | ✓ |
| `Worktree` (+ `+Lifecycle`, `+Internals`, `GitQuery`) | Pure-value | value/MDL | `WorktreeProvisioner` / git probes | transient | n/a | none | — | unchanged | ✓ |

---

## App services (`Services/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SyntaxHighlightEngine` | App-scope-service | actor-SVC | `AppState` stored-prop init | `AppState.syntaxEngine` / process | n/a | none (returns tokens; LRU) | — | PR-A2 (renamed at injection sites `searchEngine→syntaxEngine`; type unchanged) | ✗ as-is: threaded under the misleading param/property name `searchEngine` across 5 VCs (P10b) — type is fine, the *channel name* is wrong; pure-rename fix |
| `RecentProjectsStore` | App-scope-service | @Observable-SVC | `AppState` (lazy) | `AppState.recentProjects` / process; `nonisolated deinit` | @Observable pull | @Observable write | — | unchanged | ✓ |
| `InputDraftStore` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.inputDraftStore` / process; `nonisolated deinit` | @Observable pull | @Observable write; imperative `clear` (send-time, teardown-proof I12) | — | unchanged | ✓ |
| `InputDraft` | Pure-value | value/MDL | `InputDraftStore` | store-held (Codable) | n/a | none | — | unchanged | ✓ |
| `SidebarSessionGroupOrderStore` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.sidebarGroupOrder` / process (NOT @Observable — UserDefaults wrapper) | ctor-injected (UserDefaults) | none (persistence) | — | unchanged | ✓ (in scope of sidebar node for full treatment; app-scope owner here) |
| `AppActivationTracker` | App-scope-service | @Observable-SVC | `AppState.init` (before notifications) | `AppState.activationTracker` / process; `nonisolated deinit` | @Observable pull | @Observable write | — | unchanged | ✓ (private dep of NotificationService; no other reader — deliberate) |
| `NotificationService` | App-scope-service | @Observable-SVC (NSObject) | `AppState.init` (`NotificationService(activation:)`) | `AppState.notificationService` / process; `nonisolated deinit` | ctor-injected (activationTracker) | injected closure (`onActivateSession` push) | — | unchanged | ✗ as-is: injected into every detail-VC host as dead `.environment(notifications)` (0 SwiftUI reader, P1); reaches consumers only via AppKit `onActivateSession` push — PR-A1 deletes the dead injection (no-op), placing it cleanly as a push-only service |
| `OpenInAppService` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.openInService` / process | @Observable pull | imperative (launch external app) | — | unchanged | ✓ |
| `ModelStore` | App-scope-service | @Observable-SVC | `ModelStore.shared` (static) | process singleton | @Observable pull (`.shared` from views) | @Observable write; spawns CLI subprocess | — | unchanged (stays `.shared`, §11) | ✗ ownership-inconsistency (P11): app-scope catalog reached as a `.shared` singleton from inside views/runtime rather than injected; deliberately kept (spawns CLI subprocess, per-process cache) — flagged as the most-questionable singleton but a *retain* decision |
| `EffortDefaultStore` | App-scope-service | @Observable-SVC | `EffortDefaultStore.shared` (static) | process singleton | `.shared` from views | @Observable write (UserDefaults) | — | (optional) PR may fold onto AppState (§5 ★MOVED, low-risk); else unchanged | ✗ ownership-inconsistency (P11): thin UserDefaults wrapper as `.shared` singleton while peers live on AppState — low-harm; optional fold onto AppState |
| `NewSessionDefaultsStore` | App-scope-service | @Observable-SVC | `NewSessionDefaultsStore.shared` (static) | process singleton | `.shared` from views | @Observable write (UserDefaults) | — | (optional) PR fold onto AppState; else unchanged | ✗ ownership-inconsistency (P11): same as EffortDefaultStore — low-harm singleton vs AppState peers |
| `FileCompletionStore` | App-scope-service | @Observable-SVC | `FileCompletionStore.shared` (static) | process singleton | `.shared` from closures | @Observable write | — | PR-A3 (delete `invalidate*` dead methods — 0 caller, FSEvent leak) | ✗ partial: `invalidate*` are dead (0 caller, slow FSEvent-stream leak, P13); store itself is a legit per-process cache but reached as `.shared` from inside trigger-rule closures (E inconsistency) |
| `SlashCommandStore` | App-scope-service | @Observable-SVC | `SlashCommandStore.shared` (static) | process singleton | `.shared` from closures | @Observable write | — | unchanged | ✗ ownership-inconsistency (P11/E): per-process cache reached via `.shared` from closures rather than injected; low-harm, retained |
| `GitProbe` | View-scope-state | @Observable-SVC | SwiftUI `@State` (compose / draft-landing views) | view identity | @Observable pull | @Observable write | — | PR-D15 (add `@MainActor` — peers all have it; P15) | ✗ layering-nit: `@Observable` **without `@MainActor`** while every peer carries it (P15); legitimate view-scoped state machine otherwise |
| `ClaudeCodeStats` (`enum`) | — (dead) | value/MDL | n/a | none — **no production consumer** | n/a | none | — | **PR-A3 (DELETE)** ~460 lines + its tests | ✗ DEAD: fully tested but zero production consumer (P13) — placeable only as "delete." Design defect = it exists |
| `CoreDataStack` | App-scope-service | @Observable-SVC (NSObject-ish) | `CoreDataStack.shared` (static) | process singleton; `nonisolated deinit` | n/a | none (persistence container) | — | unchanged | ✓ (legit single Core Data container) |

---

## Models (`Models/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SyntaxToken` | Pure-value | value/MDL | `SyntaxHighlightEngine` | transient | n/a | none | — | unchanged | ✓ |
| `TurnTokenUsage` | Pure-value | value/MDL | `StreamingTurnAssembler` / runtime | transient | n/a | none | — | unchanged | ✓ |
| `PermissionMode` (enum) | Pure-value | value/MDL | config / pickers | inline | n/a | none | — | unchanged | ✓ |
| `SendKeyBehavior` (enum) | Pure-value | value/MDL | settings | inline | n/a | none | — | unchanged | ✓ |
| `StreamPacer` | Renderer-internal | value/MDL | streaming path | transient | n/a | none | — | unchanged | ✓ |
| `LanguageDetection` (enum) | Pure-value | translator | n/a (static) | stateless | n/a | none | — | unchanged | ✓ |
| `ANSIAttributedBuilder` (enum) | View-scope-state | translator | n/a (static) | stateless | n/a | none | — | PR-D15 (move out of `Models/` — it is a view concern, not "plain data"; P15) | ✗ layering-nit: view-layer concern filed under `Models/` (CLAUDE.md defines `Models/` = plain data) |
| `SyntaxTheme` (enum) | View-scope-state | value/MDL | n/a (static) | stateless | n/a | none | — | PR-D15 (move out of `Models/`; P15) | ✗ layering-nit: view (color) concern under `Models/` |
| `PermissionMode+Color` (ext) | View-scope-state | value/MDL | n/a (ext) | stateless | n/a | none | — | PR-D15 (move out of `Models/`; P15) | ✗ layering-nit: view (color) concern under `Models/` |
| `Effort+Display` (ext) | View-scope-state | value/MDL | n/a (ext on `AgentSDK.Effort`) | stateless | n/a | none | — | PR-D15 (move out of `Models/`; P15) | ✗ layering-nit: view (display) concern under `Models/` |

> `AgentSDK.Effort` / `Message2` themselves are in the AgentSDK package (out of scope; not tabulated).

---

## Markdown IR (`Components/Markdown/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `MarkdownDocument` (public, Sendable) | Pure-value | value/MDL | `MarkdownConvert` | consumed by `MessageEntryBlockBuilder` | n/a | none | — | unchanged | ✓ (pure, off-main-safe IR — load-bearing clean seam, §5 PRESERVE) |
| `MarkdownConvert` (`nonisolated enum`) | Pure-value | translator | n/a (static, nonisolated) | stateless | n/a | none | — | unchanged | ✓ |
| `MarkdownTypes` (`MarkdownSegment`/`Block`/`List`/`ListItem`/`Inline`/`CodeBlock`/`Table`, all public Sendable) | Pure-value | value/MDL | parser | inside `MarkdownDocument` | n/a | none | — | unchanged | ✓ |
| `MarkdownAutolink` (enum) | Pure-value | translator | n/a (static) | stateless | n/a | none | — | unchanged | ✓ |
| `MarkdownMath` (enum) | Pure-value | translator | n/a (static) | stateless | n/a | none | — | unchanged | ✓ |

---

## Non-conformant / design defects (✗ rows, summarized)

These are the types that do **not** place cleanly today (the defects the user wants
surfaced). Each is either fixed by a named PR or is a deliberate retain.

1. **`SessionRuntime+Tasks` / `markTaskStoppedLocally`** — reached *past* the
   `Session` façade by `BackgroundTaskButton` (the single production unidirectional
   violation, P4). Defect = the missing forwarder, not the tracker. **Fix: PR-A4**
   `Session.stopBackgroundTask(taskId:)` (`Void`, phase-aware `guard let runtime`,
   `.draft` no-op) + **PR-C12** relocates the storage into `TaskTracker`.

2. **`SyntaxHighlightEngine`** — correct type, **wrong channel name**: threaded as
   `searchEngine` across 5 VCs and re-exposed as `\.syntaxEngine` (P10b). A reader
   expects transcript *search* machinery. **Fix: PR-A2** pure rename.

3. **`NotificationService`** — dead `.environment(notifications)` injection at every
   detail-VC host (0 SwiftUI reader, P1); it reaches consumers only via the AppKit
   `onActivateSession` push. The injection implies a dependency edge that does not
   exist. **Fix: PR-A1** delete the dead injection (no-op); the service then places
   cleanly as a push-only app-scope service.

4. **`ClaudeCodeStats`** — ~460 lines, fully tested, **zero production consumer**
   (P13). Placeable only as "delete." **Fix: PR-A3** delete (with its tests).

5. **`FileCompletionStore.invalidate*`** — dead methods (0 caller; slow FSEvent
   stream leak, P13). **Fix: PR-A3** delete the methods (keep the store).

6. **Ownership inconsistency `.shared` singletons** — `ModelStore` /
   `EffortDefaultStore` / `NewSessionDefaultsStore` / `SlashCommandStore` /
   `FileCompletionStore` are app-scope state reached as `.shared` from inside
   views/closures rather than injected like the 8 AppState services (P11/E). A
   *judgment* defect: `ModelStore` is deliberately retained as `.shared` (spawns a
   CLI subprocess; §11). The two UserDefaults wrappers *may* fold onto AppState as a
   cheap low-risk move; the completion stores stay `.shared` (per-process caches).
   Not a blocker — flagged as inconsistency, mostly a *retain + reconcile-the-doc*.

7. **Layering nits under `Models/`** — `ANSIAttributedBuilder` / `SyntaxTheme` /
   `PermissionMode+Color` / `Effort+Display` are **view-layer** concerns filed in
   `Models/` (defined as "plain data", P15). **Fix: PR-D15** file-move (synced-group
   project, no pbxproj edit).

8. **`GitProbe`** — `@Observable` **without `@MainActor`** while every peer view-scope
   service carries it (P15). **Fix: PR-D15** add `@MainActor`.

> **Not a defect, explicitly clean (per §11 / PRESERVE):** the wide `Session` façade
> (~40 phase forwarders, P9) is mechanical boilerplate, **not** tangled flow — the
> draft/runtime read-surfaces genuinely diverge, so a unifying protocol would
> fabricate runtime-only fields on the draft. It places cleanly as "Session-core
> façade, unchanged." Likewise `TurnUsageMeter` is **deliberately not extracted**
> (rides the imperative `publishTurnUsage` sink + `turnStartedAt` ordering; would
> violate the "don't touch fire/ordering" rule — stays in `SessionRuntime`).
