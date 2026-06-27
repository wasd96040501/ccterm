# Survey: Session infrastructure (manager, repository, config, CLI client, worktree, history, titles)

Scope: `Services/Session/` infra layer — the registry, persistence boundary, value snapshots,
CLI-client seam, worktree provisioning, history I/O, and title generation. This node deliberately
treats `SessionRuntime` / `Session` / `SessionDraft` as the *consumers* of this infra (the runtime
state machine itself is a sibling survey); here we map who constructs/owns the infra, how config
flows draft → runtime → DB, and where infra leaks into UI or carries dead surface.

All paths are absolute. FACT = read directly in code; INFERENCE = my read of intent/consequence.

---

## 1. Component / type inventory

Registry / orchestration
- **`SessionManager`** — `@Observable @MainActor final class`. The session registry: get-or-create
  one `Session` façade per `sessionId`, owns the `SessionRepository`, holds observable record lists
  (`records` / `archivedRecords` / `archivedFolderOptions`), and is the single owner of archive /
  unarchive + worktree teardown/restore side-effects. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/SessionManager.swift:15`
  - nested `SessionManager.LaunchFailure` (Identifiable struct) `:74`
  - nested `SessionManager.ArchivedFolder` (Identifiable/Hashable struct, archive folder filter row) `:84`
  - `typealias WorktreeSideEffect = @Sendable (SessionRecord) -> Void` `:23`
  - statics `defaultWorktreeArchive` / `defaultWorktreeRestore` / `invokeWorktreeArchiveSync` / `invokeWorktreeRestoreSync` `:516,526,547,576`

Persistence boundary
- **`SessionRepository`** — `protocol : AnyObject`. DAO contract for `SessionRecord`. Query + create/delete + ~10 granular update methods. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/SessionRepository.swift:27`
- **`CoreDataSessionRepository`** — `final class : SessionRepository`. Production impl over `CDSessionRecord` / `CoreDataStack.shared`; maps entity↔`SessionRecord`, JSON-encodes `SessionExtra`. Has async archived fetch. `SessionRepository.swift:93`
- **`InMemorySessionRepository`** — `#if DEBUG final class : SessionRepository`. Dictionary-backed test double; behavior-contract-matched to CoreData. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/SessionRepository+InMemoryMock.swift:17`
- **`SessionExtraUpdate`** — partial-update struct (nil = "no change") for `SessionRecord.extra`. `SessionRepository.swift:8`

Data models (plain structs)
- **`SessionRecord`** — `struct : Identifiable`. The persisted row mirror; identity + cwd + status + timestamps + worktree fields + `extra`. Also carries CLI-slug derivation (`slug` / `sanitizePath` / `djb2HashAbs`) and grouping helpers. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/SessionRecord.swift:40`
- **`SessionStatus`** — `enum : String` (`draft` / `pending` / `created` / `archived`). The durable lifecycle marker — drives resume-vs-fresh and draft-routing. `SessionRecord.swift:4`
- **`SessionExtra`** — `Codable struct` (pluginDirs / permissionMode / addDirs / model / effort). The JSON blob persisted in `CDSessionRecord.extraJSON`. `SessionRecord.swift:19`
- **`SessionConfig`** — `Equatable struct`. The user-facing config snapshot carried across the draft→runtime split. Hydrates from `SessionRecord`, maps to `SessionExtra` / `SessionRecord` / `AgentSDK.SessionConfiguration`. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/SessionConfig.swift:16`

CLI client seam
- **`CLIClient`** — `protocol : AnyObject`. Thin 1:1 abstraction over `AgentSDK.Session` (callback props + lifecycle + control RPCs + messaging + config RPCs). `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/CLIClient/CLIClient.swift:19`
- **`CLIClientFactory`** — `typealias @MainActor (SessionConfiguration) -> any CLIClient`. The injection seam. `CLIClient.swift:101`
- **`AgentSDKCLIClient`** — `final class : CLIClient`. Production forwarding adapter; wraps one `AgentSDK.Session`. Carries `static let defaultFactory`. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/CLIClient/AgentSDKCLIClient.swift:7`
- **`FakeCLIClient`** — `#if DEBUG final class : CLIClient`. Records outgoing calls + exposes imperative pushers (`pushMessage` / `simulateProcessExit` / `completeInitialize` / …). `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/CLIClient/CLIClient+Fake.swift:17`

Worktree
- **`Worktree`** — `Equatable/Hashable struct`. Immutable identity of a git worktree (path / name / baseRepo / sourceBranch) + nested `Worktree.Error`. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Worktree/Worktree.swift:16`
- **`Worktree+Lifecycle`** — `create` / `remove` / `restore` / `renameBranch` (git invocations). `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Worktree/Worktree+Lifecycle.swift:23`
- **`Worktree+Internals`** — `enum GitQuery` + extension helpers (`generateName` / `resolveBaseRepo` / `runGit` / `copyGitignoredClaudeFiles` / fast-forward / start-point resolution …). The git CLI surface. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Worktree/Worktree+Internals.swift:88`
- **`WorktreeProvisioner`** — stateless `enum`. Runs `Worktree.create` off-main on `DispatchQueue.global`, wraps the outcome as `Result`. Injectable `Creator` seam. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Worktree/WorktreeProvisioner.swift:18`

History + title
- **`HistoryLoader`** — stateless `enum`, all `nonisolated static`. JSONL path resolution (`locate` with root-injected overload + scan fallback) + `parseLines` per-page decode. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/HistoryLoader.swift:13`
- **`TitleGenerator`** — stateless `enum`. One-shot LLM call (`Prompt.runTitleAndBranch`) in a scratch tmp dir; injectable `Runner`. Returns nil on any failure. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/TitleGenerator.swift:14`

Consumers (surveyed only at the boundary)
- **`Session`** (`@Observable @MainActor`) — façade; owns `SessionRepository` ref + `cliClientFactory` + render-side state, wraps draft/runtime. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Session/Session.swift:46`
- **`SessionDraft`** (`@Observable @MainActor`) — compose-card config carrier; holds a `SessionConfig` + a `repository` ref (currently only forwarded, see smells). `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Session/SessionDraft.swift:27`
- **`SessionRuntime`** (`@Observable @MainActor`) — CLI-bound engine; owns `repository` + `cliClientFactory` + `cliClient`, performs every DB write through `repository`. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/Services/Session/Session/SessionRuntime.swift:18`
- **`AppState`** (`@Observable @MainActor`) — process-scope container that constructs the single production `SessionManager()` and wires its notice sinks. `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm/App/AppState.swift:6`

---

## 2. Component tree (this area)

No AppKit/SwiftUI views live in this layer — it is all plain Swift / `@Observable` services. There are
**no `NSHostingView`/`NSHostingController` boundaries here**; the AppKit↔SwiftUI seam is one level up
(`ChatSessionViewController` etc. consume `session.controller`). The "tree" is an ownership graph:

```
AppState                                   [@Observable service, owned by AppDelegate]
└─ SessionManager()                        [@Observable @MainActor — the registry]
   ├─ repository: any SessionRepository    [CoreDataSessionRepository (prod) | InMemory (test)]
   │     └─ CoreDataStack.shared           [shared w/ legacy stack; viewContext + bg context]
   ├─ cliClientFactory: CLIClientFactory   [AgentSDKCLIClient.defaultFactory (prod) | {FakeCLIClient} (test)]
   ├─ worktreeArchive / worktreeRestore    [WorktreeSideEffect closures; default = git-on-bg-queue]
   ├─ records / archivedRecords / archivedFolderOptions   [observable value snapshots]
   └─ sessions: [String: Session]          [the per-id cache — Session façades]
        └─ Session (one per sessionId)     [@Observable façade]
           ├─ repository  (same instance, passed down by ref)
           ├─ cliClientFactory (same closure, passed down)
           ├─ controller / bridge          [render-side; out of this survey's scope]
           └─ phase:
              ├─ .draft(SessionDraft)       [holds SessionConfig + repository ref (unused)]
              └─ .active(SessionRuntime)    [holds SessionConfig + repository + cliClientFactory]
                    ├─ config: SessionConfig (value)
                    ├─ cliClient: any CLIClient?   [built per-bootstrap via cliClientFactory]
                    │     └─ AgentSDKCLIClient → AgentSDK.Session (the subprocess wrapper)
                    └─ frameTicker / streamingAssembler / … (runtime-only, out of scope)

Stateless infra (no instances — called as static/enum):
   HistoryLoader   WorktreeProvisioner   TitleGenerator   Worktree(+Lifecycle/+Internals)/GitQuery
```

Marks: every node above is plain Swift (no AppKit). The single production `SessionManager` is
constructed in `AppState.init` (`App/AppState.swift:17`) and handed to the AppKit window/detail/chat
VCs by reference (`MainWindowController` / `DetailRouterViewController` / `ChatSessionViewController`
each hold a `let sessionManager`).

---

## 3. Data flow

### 3a. Config snapshot: draft → runtime → DB → SDK (the spine)
Direction is cleanly **one-way** along the happy path:

1. **Into the area.** A draft's `SessionConfig` accumulates via `SessionDraft.setXxx` (unconditional
   writes to `config`, no DB, no RPC) `SessionDraft.swift:53-95`. Seeding from a source session in
   `SessionManager.createSidebarDraft` copies field-by-field through the façade's phase-agnostic reads
   `SessionManager.swift:280-291`.
2. **Promotion (the one-time flip).** `Session.promoteOrForward` → `SessionRuntime.fromDraft` copies
   `draft.config` **verbatim** into the new runtime (`runtime.config = draft.config`)
   `SessionRuntime+Start.swift:234`. The draft is then discarded (phase = `.active`).
3. **Persist.** First `ensureStarted()` → `persistConfiguration()` calls `config.toSessionRecord(...)`
   → `repository.save(record)` `SessionRuntime+Start.swift:514-524`. (Hydrate is the inverse:
   `SessionRuntime.init` → `apply(record)` → `config = SessionConfig(from: record)` `SessionRuntime.swift:444-463`.)
4. **To the SDK.** `makeAgentConfig` → `config.toAgentSDKConfig(...)` `SessionRuntime+Start.swift:556` →
   `cliClientFactory(configuration)` builds the client `:595`.

`SessionConfig` is the single value carrier across all four hops — the same struct hydrates from a
record, snapshots to a record, and derives the SDK config. (FACT.)

### 3b. Incremental config writes (runtime → DB → CLI) — fan-out, not bidirectional
Runtime-mutable setters write **three places in one call**: memory, DB (if persisted), and CLI RPC (if
attached): `SessionRuntime+Configuration.swift:35-109` (`setModel` / `setEffort` / `setPermissionMode`
/ `setAdditionalDirectories`). This is an **optimistic-write** fan-out — memory first for instant UI,
RPC concurrently, "CLI reply is authoritative." (FACT, documented `SessionRuntime.swift:493-519`.)

### 3c. CLI reply → DB (the one inbound mutation back into config)
The receive path has a **back-channel** from the CLI into persisted config:
`adoptPermissionMode` (`SessionRuntime+Receive.swift:561-571`) writes `permissionMode` + a
`repository.updateExtra` when the CLI's `system.status` reports a different mode. It deliberately does
**not** call `setPermissionMode` (would loop back as another RPC) — a documented, contained inbound
mutation. (FACT.) This is the only "CLI is authoritative, overwrite local" write that touches the repo
from the receive side.

### 3d. Records observation (DB → UI), pull model
`SessionManager.records` / `archivedRecords` / `archivedFolderOptions` are `@Observable` value
snapshots. The sidebar/archive observe them directly; they are refreshed by **explicit** calls to
`refreshRecords()` / `refreshArchivedRecords()` after a mutation (`SessionManager.swift:357,366`).
There is no live CoreData→observable binding — every refresh is a full `repository.findAll()` re-read.
Triggers: NewSession launch, `/new`-`/clear` persist, every promotion (via the `onPromoted` closure
`SessionManager.swift:177`), and the async `onRecordPersisted` patch from worktree collision-recovery
`SessionRuntime+Start.swift:382`. (FACT.)

### 3e. Notice fan-out (runtime → manager → AppState → NotificationService)
A clean unidirectional event chain that keeps `SessionRuntime` UI-agnostic:
`runtime.onTurnEnded` / `onPermissionPrompt` / `onLaunchFailure` / `onRecordPersisted`
→ forwarded by `Session` (didSet + `wireRuntimeMessagesSink`) `Session.swift:103-149,250-264`
→ `SessionManager.wireSessionCallbacks` re-forwards to manager-level `onTurnEndedNotice` /
  `onPermissionPromptNotice` / `onLaunchFailure` `SessionManager.swift:330-348`
→ `AppState` wires the notice sinks to `NotificationService` `AppState.swift:28-38`;
  `DetailRouterViewController` owns `onLaunchFailure` for the alert `DetailRouterViewController.swift:168`.
All closure-based, all `[weak self]`/owned-lifetime captures. (FACT.)

### 3f. Worktree provisioning (async, fresh + isWorktree only)
`ensureStarted` eager-persists a *proposed* worktree row (precomputed name/path/branch) so the sidebar
gets a complete row within a frame, then dispatches `WorktreeProvisioner.provision` off-main
`SessionRuntime+Start.swift:336-407`. On success it `continueStartup()`; on name-collision it patches
cwd/branch via `repository.updateCwd/updateWorktreeBranch` + fires `onRecordPersisted` `:378-382`; on
failure it funnels through `failLaunch`. Teardown/restore live on the **manager**
(`SessionManager.archive/unarchive` → injected `worktreeArchive/worktreeRestore` closures →
`Worktree.remove`/`Worktree.restore`), gated by a records-table reference count
(`liveWorktreeReferenceExists` `SessionManager.swift:460`). (FACT.)

### 3g. History + title (pure I/O, off to the side)
`HistoryLoader.locate` resolves a JSONL URL from `(sessionId, slug)`; the runtime forwards via
`historyJSONLURL` (`SessionRuntime+History.swift:21`); `Session.loadHistory` drives the backfill
pipeline. `TitleGenerator.generate` is fired-and-forgotten from `promoteOrForward`; its result lands
through `applyGeneratedTitle` → `repository.updateTitle` + `onRecordPersisted` (`SessionRuntime+Start.swift:189-200`).
Both are stateless, injectable, and have no back-edges into config. (FACT.)

**Direction summary.** The infra layer is overwhelmingly unidirectional: config flows draft→runtime→DB→SDK;
records flow DB→manager-snapshot→UI on explicit refresh; events flow runtime→manager→AppState. The only
inbound mutations are (a) `adoptPermissionMode` (CLI→DB, contained) and (b) hydrate-from-record at init
(DB→runtime, one-time). No infra type reads UI state.

---

## 4. Ownership & lifetime

- **`SessionManager`** — constructed once in `AppState.init` (`AppState.swift:17`), retained by
  `AppState` (owned by `AppDelegate`), lives for the whole process. Handed by reference (`let
  sessionManager`) to the AppKit VCs; none of them own it. `nonisolated deinit {}` (macOS-26 SDK
  workaround, never actually runs in production). (FACT.)
- **`SessionRepository` (the instance)** — constructed inside `SessionManager.init`'s default arg
  (`CoreDataSessionRepository()` `SessionManager.swift:105`), held by the manager, and **passed by
  reference down into every `Session` / `SessionDraft` / `SessionRuntime`** the manager builds
  (`makeSession` → `Session.init(... repository:)` → `SessionRuntime.init(repository:)`). One repo
  instance shared by the whole tree; `CoreDataStack.shared` underneath is process-global. (FACT.)
- **`cliClientFactory`** — captured at `SessionManager.init` (`:106`), forwarded into every `Session`
  and on into each `SessionRuntime` (`SessionRuntime.cliClientFactory` `SessionRuntime.swift:381`).
  The actual `CLIClient` instance is created **per-bootstrap** inside `bootstrap`
  (`cliClientFactory(configuration)` `SessionRuntime+Start.swift:595`), assigned to `cliClient` only
  after `start()` succeeds (`:614`), and cleared to nil on process exit / `failLaunch` / stop
  (`:703,837`). So a `CLIClient`'s lifetime = one CLI subprocess session, not the `Session`'s lifetime. (FACT.)
- **`Session` façades** — created lazily by `SessionManager.session(_:)` / `prepareDraftSession(_:)`,
  cached in `sessions[sessionId]`, removed on `archive`/`unarchive` (`SessionManager.swift:431,493`).
  Never explicitly torn down otherwise — they live until evicted from the cache or the manager dies.
  (FACT.) Note: a session whose CLI exits is **not** removed from the cache; it stays as a stopped runtime.
- **`SessionConfig`** — value type; no ownership. Copied at every boundary (draft→runtime, →record, →SDK).
- **Worktree side-effect closures** — `defaultWorktreeArchive/Restore` are `nonisolated static let`
  (module-load init, no MainActor hop), captured by the manager. The real git work runs on
  `DispatchQueue.global(qos:.userInitiated)`. Tests inject synchronous recorders. (FACT.)
- **Stateless infra** (`HistoryLoader` / `WorktreeProvisioner` / `TitleGenerator` / `Worktree`+`GitQuery`) —
  no instances, no lifetime; called as static/enum functions. Their injectable seams (`Creator` /
  `Runner` / root-overload of `locate`) are passed per-call. (FACT.)

---

## 5. Smells / debt

### HIGH

**S1. Dead repository protocol surface (4 methods, 0 callers).** `pinSession` / `unpinSession` /
`touch` / `updateIsWorktree` are declared on `SessionRepository` and implemented in **both**
`CoreDataSessionRepository` and `InMemorySessionRepository`, but have **zero callers anywhere** in the
repo (verified by grep across all `.swift`). `SessionRepository.swift:77,79,82,86`. Why high: the
protocol is the contract the whole tree depends on; every dead method is triple-maintained
(protocol + 2 impls) and misleads a reader into thinking pinning/touch are live features. A refactor
should delete all three copies of each. (FACT.)

**S2. `isTempDir` field is write-never / read-dead, and its one reader emits a hardcoded
non-localized Chinese string.** `SessionRecord.isTempDir` is persisted and round-tripped but **never
set to `true`** by any production path (only the default `false`). Its sole reader,
`groupingFolderName`, returns the literal `"临时会话"` — bypassing `Localizable.xcstrings` entirely,
violating the project's i18n rule. `SessionRecord.swift:56,142`. Why high: it is both dead state and a
latent localization bug that would ship the moment `isTempDir` is ever wired. (FACT.)

### MEDIUM

**S3. `SessionDraft` holds a `repository` it does not use for any DB work.** The draft's documented
contract is "no DB writes, no RPCs" (`SessionDraft.swift:18-24`), yet it stores `internal let
repository` (`:30`) purely so `SessionRuntime.fromDraft` can read it back out (`draft.repository`
`SessionRuntime+Start.swift:232`) and `Session.init(runtime:)` can read `runtime.repository`. This is
a courier dependency: the draft carries the repo only to hand it to the runtime at promotion. Cleaner
would be for the promotion call site (which already has `cliClientFactory` and the repo via `Session`)
to pass the repo into `fromDraft` directly, dropping the field from `SessionDraft`. Why medium: harmless
today but blurs the "draft = pure config carrier" boundary. (INFERENCE.)

**S4. Repository-write logic is scattered across runtime extensions with duplicated persistence rules.**
DB writes happen in at least 6 sites across `SessionRuntime+Start.swift` (`persistConfiguration`,
`ensureStarted` draft→pending flip, worktree collision patch, `applyGeneratedTitle`, `failLaunch`,
`handleProcessExit`) and `SessionRuntime+Configuration.swift` (4 setters) plus `adoptPermissionMode`.
The "should this write?" predicate is expressed two different ways: `hasRecord` (in-memory bool,
`persistConfiguration` `:515`) vs `repository.find(sessionId) != nil` (live query, `isPersisted`
`SessionRuntime+Configuration.swift:20` and `adoptPermissionMode` `:567`). Two sources of truth for the
same "is this persisted?" question is a drift risk. Why medium: the comment at `SessionRuntime.swift:404`
calls this the "master rule," but the rule is enforced by convention across many sites, not one gate. (FACT.)

**S5. `Worktree.renameBranch` is dead production code.** It has a full retry/conflict implementation
(`Worktree+Lifecycle.swift:219`) and is described in `Worktree.swift:13`'s "typical flow" doc as the
LLM-rename step — but `applyGeneratedTitle` **explicitly discards** the LLM branch suggestion
(`SessionRuntime+Start.swift:185` "`Prompt.TitleAndBranch.branch` is discarded"). No production caller.
Why medium: the doc comment actively describes a flow that does not exist, and the unused git path is a
maintenance liability. (FACT.)

**S6. Worktree teardown identity is reconstructed from the DB row instead of from `Worktree.locate`.**
`invokeWorktreeArchiveSync` rebuilds a `Worktree` value from `record.cwd.lastPathComponent` +
`resolveBaseRepo(origin)` (`SessionManager.swift:557-559`) rather than locating the real worktree, and
the reference-count gate matches on `worktreeBranch` **or** `cwd` (`liveWorktreeReferenceExists`
`:460-468`) precisely because the name-derivation is lossy. This couples the manager to the worktree's
on-disk naming convention (it has to know `cwd.lastPathComponent == worktree name`). Why medium: works,
but the manager reaching into path-component semantics is leaky; a single "resolve worktree identity
from a record" helper on `Worktree` would localize that knowledge. (INFERENCE + FACT on the code shape.)

**S7. `SessionManager` is large and mixes three concerns.** ~595 lines spanning: (a) the registry /
get-or-create cache, (b) the records/archive observable-snapshot store + folder-options derivation, and
(c) the worktree archive/restore + reference-count policy + git side-effect statics
(`SessionManager.swift:503-594`). Concern (c) in particular is git/filesystem policy that has little to
do with "registry of sessions." Why medium: the type is the natural seam for the area but currently owns
the worktree-lifecycle policy that could live nearer `Worktree`. (INFERENCE.)

### LOW

**S8. `SessionExtraUpdate` and `SessionExtra` are near-duplicate shapes.** `SessionExtraUpdate`
(`SessionRepository.swift:8`) is `SessionExtra` (`SessionRecord.swift:19`) with every field optional to
mean "no change." The merge logic is hand-written twice (CoreData `updateExtra` `:245-265`, InMemory
`:113-121`). A single `apply(_ update:)` on `SessionExtra` would remove the duplication. (FACT.)

**S9. `CoreDataSessionRepository` has an async fetch only for `findArchived`.** `findArchivedAsync`
(`SessionRepository.swift:145`) exists but `findAll` has no async sibling, and `SessionManager`
type-checks `repository as? CoreDataSessionRepository` to decide whether to use it
(`SessionManager.swift:382`). That downcast is a small abstraction leak — the manager knows the concrete
repo type for one method. Why low: contained, documented, and the in-memory path is instant anyway. (FACT.)

**S10. `Session` has five initializers** (`record:` / `draftSessionId:` / `draftRecord:` / `runtime:` +
the promotion path) each re-doing the `controller`/`bridge` construction boilerplate
(`Session.swift:156-241`). Some of this is test-affordance (`init(runtime:)`). Borderline; a shared
private designated init would cut the repetition. (INFERENCE.)

**S11. `SessionRecord.title` default and CoreData fallback diverge.** `SessionRecord.init` defaults
title to `"[unknown session]"` (`SessionRecord.swift:151`), CoreData maps a nil entity title to the same
literal (`SessionRepository.swift:325`), and `createSidebarDraft` saves an empty title rendered as
"Untitled" elsewhere. Three different "no title" representations float around. Low impact but
inconsistent. (FACT.)

---

## 6. Load-bearing invariants (a refactor MUST preserve)

1. **`cliClientFactory` injection seam is the test boundary for the entire CLI path.** Production wires
   `AgentSDKCLIClient.defaultFactory`; tests pass `{ _ in FakeCLIClient() }` once at the manager (or
   runtime) and every session inherits it (`SessionManager.swift:106`, `SessionRuntime.swift:433`). The
   factory is invoked **per-bootstrap inside `bootstrap`** (`SessionRuntime+Start.swift:595`) — not at
   init — so a fresh `CLIClient` exists per subprocess. Do not move client construction to init or
   collapse the factory; 146+ test references depend on this seam. (Engineering-principles rule: no
   `forceXxxForTest`; drive the public surface.)

2. **`InMemorySessionRepository` must remain behavior-identical to `CoreDataSessionRepository`** so
   swapping requires no branching in `SessionManager`/`Session`/`SessionRuntime`
   (`SessionRepository+InMemoryMock.swift:12`). The one allowed downcast is `findArchivedAsync`
   (S9). Any new repo method must land in both impls with matching semantics.

3. **`SessionConfig` flows verbatim across promotion.** `fromDraft` copies the entire config
   (`runtime.config = draft.config` `SessionRuntime+Start.swift:234`); `toSessionRecord` /
   `SessionConfig(from:)` are exact inverses for persisted fields. Adding a config field requires the
   full 4-step ritual (`Services/Session/CLAUDE.md` "Adding new draft-time config"): field on
   `SessionConfig` (with default) → `SessionDraft` setter → optional `SessionRuntime` setter → phase-aware
   `Session` forwarder. `sourceBranch` and `fastModeEnabled` are intentionally **not persisted**
   (`SessionConfig.swift:79,84`) — preserve that.

4. **Resume-vs-fresh is derived from durable `record.status`, never threaded as a parameter.**
   `shouldResumeBootstrap(for:) == (record?.status == .created)` (`SessionRuntime+Start.swift:578`) is
   the single source of truth. The header comment (`:570-577`) documents a real past bug where a
   `fresh: Bool` flowing through `continueStartup`/`makeAgentConfig` flipped the CLI to `--resume` on a
   first launch ("No conversation found"). Do **not** reintroduce a `fresh` parameter.

5. **`SessionRecord.sanitizePath` must match Claude CLI's slug byte-for-byte.** It is a 1:1 port of the
   CLI's `sessionStoragePortable.ts` (UTF-16 walk, djb2 over UTF-16 with Int32 wrap, 200-char cap,
   base-36 suffix) `SessionRecord.swift:92-130`. Drift breaks `HistoryLoader.locate`'s slug-based file
   discovery (the documented worktree double-dash bug). Treat as frozen; do not "clean up" the
   character-range loop or hash math.

6. **Worktree teardown is gated by a records-table reference count, durable across restart.**
   `archive` only calls `worktreeArchive` when `!liveWorktreeReferenceExists(...)`
   (`SessionManager.swift:444`); the gate evaluates **after** the repo mutation so the self-row is
   already excluded, and matches on `worktreeBranch` OR `cwd` to handle nil-branch shared-cwd adopters
   (`:460-468`). `/new`-`/clear` adopters share a worktree by carrying its `worktreeBranch` + `cwd`.
   Preserve both the after-mutation ordering and the OR-match, or `/new`/`/clear` will delete a worktree
   another live session is using.

7. **Worktree provisioning + git work runs off-main via GCD `DispatchQueue.global`, not `Task.detached`.**
   Documented at `SessionRuntime+Start.swift:325-330` and `WorktreeProvisioner.swift:13-17`:
   `Task.detached` empirically still pinned the main actor for the full git shell-out duration (actor
   isolation inheritance), freezing the UI. The eager-persist-then-provision ordering
   (`SessionRuntime+Start.swift:356-407`) is what gives the sidebar a complete row within a frame.
   Keep the GCD dispatch and the eager-row-then-patch flow.

8. **Draft-status flip on first send must be durable before the worktree block is skipped.** A `.draft`
   row is flipped to `.pending` at `ensureStarted` (`SessionRuntime+Start.swift:312-314`); because the
   record now exists, `fresh` is false and the worktree provisioning block is skipped → the CLI launches
   in the **seeded/adopted** worktree dir rather than re-forking (`:307-311` comment). This is the
   mechanism that makes `/new`/`/clear` reuse a worktree.

9. **The sink-wiring order at promotion is load-bearing.** `promoteOrForward` wires **all** runtime
   sinks (`wireRuntimeMessagesSink`) **before** firing the queued-entry event and **before**
   `ensureStarted()` (`Session.swift:610-623`), because `ensureStarted`/`persistConfiguration` fires
   `onRecordPersisted` synchronously and `failLaunch` fires `onLaunchFailure` synchronously; wiring after
   would race those events into the void (`fromDraft` doc `SessionRuntime+Start.swift:213-223`). Any
   refactor of the promotion path must keep "wire sinks → fire queued entry → flip phase → ensureStarted."

10. **`adoptPermissionMode` must not call `setPermissionMode`.** The CLI→DB sync writes the field +
    `repository.updateExtra` directly and deliberately skips the RPC-issuing setter to avoid a
    `set_permission_mode` → `system.status` → adopt loop (`SessionRuntime+Receive.swift:558-571`).
    Preserve the "inbound adopt writes locally, never RPCs back" rule for any new CLI-authoritative field.

11. **`nonisolated deinit {}` on every `@MainActor` class here is a macOS-26 SDK crash workaround**, not
    style. `SessionManager` / `CoreDataSessionRepository` / `InMemorySessionRepository` / `SessionRuntime`
    / `SessionDraft` / `Session` / `AgentSDKCLIClient` / `FakeCLIClient` all carry it
    (`SessionManager.swift:129`, etc.). A default deinit routes through `swift_task_deinitOnExecutorImpl`
    and aborts libmalloc on CI's macos-26 runner. Do not remove these when refactoring class bodies.
