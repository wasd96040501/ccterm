# Survey: NativeTranscript2Bridge — MessageEntry → Block translation + backfill pipeline

Scope: `Content/Chat/NativeTranscript2Bridge/` (the entry→block translation layer
and the cold-load backfill pipeline) plus the `Services/Session/Session/` domain
types it consumes (`MessageEntry`, `ReverseEntryBuilder`, `MessagesChange`,
`StreamingTurnAssembler`). This is the seam where **Session domain types**
(`MessageEntry` / `Message2` / `ToolUse`) cross into **transcript render types**
(`Block` / `RowLayout` / `Transcript2Controller.Change`).

This area has **two independent paths into `Transcript2Controller`**:

1. **Continuous live bridge** — `Session.wireRuntimeMessagesSink` installs a
   closure on `runtime.onMessagesChange` that calls `bridge.apply(change)` for
   every `MessagesChange`. Always wired, survives view mount/dismount.
2. **Cold backfill pipeline** — `Session.loadHistory()` builds a
   `TranscriptBackfillPipeline` that reads JSONL reverse, builds + typesets
   blocks off-main, and applies them **directly to the controller, bypassing the
   bridge**. History is never a `MessagesChange`.

Both converge on the same single mutation entry: `Transcript2Controller.apply` →
`Transcript2Coordinator.apply`.

---

## 1. Component / type inventory

### 1a. Bridge directory (`Content/Chat/NativeTranscript2Bridge/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `Transcript2EntryBridge` | `@MainActor final class` | Live channel. Translates each `MessagesChange` (`.appended`/`.updated`/`.removed`) into the **minimal** `Transcript2Controller.Change` set; owns first-user-bubble suppression + tool-status derivation. Holds `entryOrder` + `entryBlocks` reverse maps. | `Transcript2EntryBridge.swift:28` |
| `Transcript2EntryBridge.StatusMode` | nested `enum` (`.live` / `.historical`) | Picks whether a missing `tool_result` derives `.running` (live) or `.completed` (historical). | `Transcript2EntryBridge.swift:203` |
| `MessageEntryBlockBuilder` | `enum` (namespace of statics) | Pure `MessageEntry → [Block]` translation. `entryBlocks(_:)` is the single per-entry function used by **both** bridge and pipeline. | `MessageEntryBlockBuilder.swift:22` |
| `ToolUseToChild` | `enum` (namespace of statics) | `ToolUse + ToolResultPayload → ToolGroupBlock.Child`. Per-kind dispatch + uniform error-text extraction (`<tool_use_error>` stripping, cat -n stripping). | `ToolUseToChild.swift:10` |
| `MarkdownToBlocks` | `enum` (namespace of statics) | Reshapes `MarkdownDocument` IR (`MarkdownSegment`/`MarkdownInline`) into `Block.Kind`/`InlineNode`. | `MarkdownToBlocks.swift:11` |
| `StreamingMarkdownCommit` | `enum` (namespace of statics) | Pure string policy: largest leading slice of streamed text with no open code fence / unsealed table. **Consumed by `SessionRuntime+Streaming`, NOT by anything in this dir.** | `StreamingMarkdownCommit.swift:18` |
| `StableBlockID` | `enum` (namespace of statics) | `SHA256(seed)`-derived deterministic UUID v5 from `(entryId, role, idx…)`. Backs `Block.id` / `Child.id` identity. | `StableBlockID.swift:15` |
| `TranscriptBackfillPipeline` | `@MainActor final class` | Cold-load channel. Off-main producer reads reverse pages, builds + typesets blocks, pushes to `PipelineInbox`; main drain applies to controller. | `TranscriptBackfillPipeline.swift:45` |
| `TranscriptBackfillPipeline.PendingPage` | nested `struct` | One pre-built page: `entries` + `blocks` + off-main `(UUID, RowLayout)` layouts + typeset `width`. `@unchecked Sendable` payload. | `TranscriptBackfillPipeline.swift:74` |
| `ReversePageSource` | `protocol : AnyObject` | `func nextPage() async -> [Message2]?`. Injection seam — production = JSONL pager, tests = fake. | `TranscriptBackfillPipeline.swift:11` |
| `JSONLReversePageSource` | `final class … @unchecked Sendable` | Production `ReversePageSource` over the session's JSONL. Merge-aware first-page sizing (~1 screen), flat line budget after. | `JSONLReversePageSource.swift:18` |
| `JSONLReversePageSource.CountClass` | nested `enum` (`.invisible`/`.standalone`/`.toolChild`) | Classifies a raw line for merge-aware first-page entry counting. | `JSONLReversePageSource.swift:117` |
| `ReverseLineReader` | `final class` (not Sendable) | Streaming reverse line reader — chunks backward from EOF, reassembles straddling lines. Peak memory = one chunk + carry. | `ReverseLineReader.swift:19` |
| `PipelineInbox` | `final class … @unchecked Sendable` | Lock-guarded producer→drain hand-off: page buffer + typeset width + drain-coalescing flag + async (continuation) backpressure. | `PipelineInbox.swift:20` |

### 1b. Session domain types (`Services/Session/Session/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `MessageEntry` | `enum : Identifiable` (`.single`/`.group`) | Timeline entry. The unit both paths translate into blocks. | `MessageEntry.swift:11` |
| `SingleEntry` | `struct : Identifiable` | One message: `payload` (`.localUser`/`.remote`), `delivery`, `toolResults: [String: ToolResultPayload]`. | `MessageEntry.swift:39` |
| `SingleEntry.Payload` | nested `enum` | `.localUser(LocalUserInput)` (pre-echo) / `.remote(Message2)` (CLI / JSONL). | `MessageEntry.swift:52` |
| `LocalUserInput` | `struct` | Captured user send (text + images + planContent) before CLI echo. | `MessageEntry.swift:65` |
| `ToolResultPayload` | `struct` | Merged tool result: raw `ItemToolResult` + typed `ToolUseResult?`. | `MessageEntry.swift:81` |
| `GroupEntry` | `struct : Identifiable` | A run of adjacent groupable assistant singles. Computes the 3 title forms (`activeTitle`/`expandedActiveTitle`/`completedTitle`). | `MessageEntry.swift:120` |
| `DeliveryState` | `enum` (`.queued`/`.confirmed`/`.failed`) | User-entry lifecycle; drives `userBubble(isQueued:)`. | `MessageEntry.swift:191` |
| `GroupableToolName` | `enum` | Tool kind for grouping + aggregated count phrases (localized). | `MessageEntry.swift:203` |
| `ReverseEntryBuilder` | `struct` (pure, stateful) | Reverse-streaming grouping + tool-pairing: `Message2` (newest-first) → `MessageEntry` (doc order). The cold-load counterpart of `appendToTimeline`. | `ReverseEntryBuilder.swift:35` |
| `MessagesChange` | `enum` (`.appended`/`.updated`/`.removed`) | Per-mutation imperative signal from `SessionRuntime` → bridge. History is NOT one. | `MessagesChange.swift:24` |
| `StreamingTurnAssembler` | `struct` (pure) | Folds the SDK partial-message stream into in-flight text + token-usage estimate. Lives on the runtime, not the bridge; relevant only as the *producer* of the streaming text the bridge later renders. | `StreamingTurnAssembler.swift:45` |

### 1c. Render types this area emits (defined elsewhere, consumed here)

- `Block` / `Block.Kind` / `ToolGroupBlock` / `ToolGroupBlock.Child` — `NativeTranscript2/Model/Block.swift` (per renderer CLAUDE.md).
- `RowLayout` — `NativeTranscript2/Layout/RowLayout.swift`. The pipeline typesets it off-main via `Transcript2Coordinator.makeLayout` (`nonisolated static`).
- `Transcript2Controller.Change` — `Transcript2Controller.swift:49`. The only mutation vocabulary both paths speak.
- `Transcript2Controller.PrecomputedLayouts` — `Transcript2Controller.swift:73`. Carries the pipeline's off-main `(id, RowLayout)` + width.

---

## 2. Component tree (this area)

This area is **almost entirely non-UI** — there are no SwiftUI views and no
NSViews here. It is a translation + producer layer that feeds the AppKit
transcript. The "tree" is therefore an ownership/data-feed tree, not a view tree.
The only AppKit-hosting boundary (`NSHostingView`/`NSHostingController`) lives
*downstream* in `ChatSessionViewController` (out of scope — see
`survey-chat-detail-vcs.md`); nothing in this directory hosts SwiftUI.

```
Session  (@Observable @MainActor)                              [owns both paths]
│
├── controller : Transcript2Controller   (@Observable @MainActor) [render-side, session-lifetime]
│      └── coordinator : Transcript2Coordinator (NSObject)  ── single mutation sink
│            └── (binds to NSTableView only when a view is mounted)   [AppKit]
│
├── bridge : Transcript2EntryBridge  (@MainActor class)    [LIVE PATH, session-lifetime]
│      │  state: entryOrder:[UUID], entryBlocks:[UUID:[Block]], firstUserEntryId:UUID?
│      ├── uses → MessageEntryBlockBuilder.entryBlocks(_:)   (pure static)
│      │             ├── singleBlocks → MarkdownToBlocks.blocks(...)  (markdown IR → Block)
│      │             ├── assistantBlocks → ToolUseToChild.make(...)   (ToolUse → Child)
│      │             └── all ids via → StableBlockID.derive(...)
│      └── calls → controller.apply(.append/.replace/.update) + controller.setToolStatus
│
└── backfillPipeline : TranscriptBackfillPipeline?  (@MainActor class) [COLD PATH, per-load]
       │  created in Session.loadHistory(); retained for the load's duration
       ├── source : ReversePageSource (protocol)
       │      └── JSONLReversePageSource  (final, @unchecked Sendable)
       │            └── ReverseLineReader  (final, off-main file I/O)
       ├── inbox : PipelineInbox  (final, @unchecked Sendable, NSLock-guarded)
       │      └── buffer of PendingPage + typeset width + backpressure continuation
       ├── producer: Task.detached  [OFF-MAIN]
       │      ├── ReverseEntryBuilder (pure struct)  → MessageEntry (doc order)
       │      ├── MessageEntryBlockBuilder.blocks(from:)  → [Block]   (SAME builder as bridge)
       │      └── Self.typeset(_:width:) → Transcript2Coordinator.makeLayout  (nonisolated static)
       └── drain: DispatchQueue.main.async  [MAIN]
              ├── controller.apply(.append/.prepend, precomputed:)   [BYPASSES bridge]
              └── onApplied(entries) → bridge.pushHistoricalStatuses(for:)  [re-enters bridge for STATUS only]
```

Two crossings worth pinning:

- **Live path is synchronous and single-threaded (main).** Bridge → controller →
  coordinator all in the same call stack as the `messages` write.
- **Cold path is off-main-build → lock-guarded hand-off → main-drain.** The
  producer never `await`s main per page (`requestDrain` is a fire-and-forget
  `DispatchQueue.main.async`); backpressure parks the *producer task*, not a
  thread (`PipelineInbox.waitForCapacity`).

---

## 3. Data flow

### 3a. Live path (continuous bridge)

Direction: CLI → runtime → bridge → controller → coordinator. **Strictly
one-directional, synchronous, main-actor.**

1. `SessionRuntime.receive` mutates `messages` and fires
   `onMessagesChange(change)` synchronously at the mutation site
   (`SessionRuntime+Receive.swift:158` etc.).
2. `Session.wireRuntimeMessagesSink` (`Session.swift:250`) installs the closure:
   `bridge.apply(change)` **then** `onMessagesChange?(change)` (optional external
   fanout).
3. `Transcript2EntryBridge.apply` (`Transcript2EntryBridge.swift:90`) dispatches:
   - `.appended` → `applyAppend` (`:278`) + `pushStatuses(.live)`.
   - `.updated` → `applyUpdate` (`:319`) + `pushStatuses(.live)`.
   - `.removed` → `applyRemove` (`:380`).
4. Block translation: `blocks(for:)` (`:128`) → `MessageEntryBlockBuilder.entryBlocks`
   → `applyFirstUserSuppression`.
5. The bridge emits a **minimal `Change` set** by diffing the entry's new blocks
   against `entryBlocks[entry.id]` (`:319`–`:367`): identical id sequence →
   per-block `.update` only where `kind` moved; append-only prefix growth →
   `.update` changed prefix + a single anchored `.replace` of the boundary+tail;
   otherwise full `.replace`.
6. Status flows on an **independent channel**: `pushStatuses` → `controller.setToolStatus`
   (`:228`, `:233`, `:253`, `:257`). Never via `Change.update`. This matches the
   renderer's §2.13 contract (status = color-only, height-stable).

Turn-finished: `runtime.onTurnFinishedLive` → `bridge.handleTurnFinished()`
(`:117`) → `controller.clearAllRunningStatuses()`.

### 3b. Cold path (backfill pipeline)

Direction: JSONL file → off-main producer → inbox → main drain → controller.
**One-directional for content; one re-entry into the bridge for status only.**

1. `Session.loadHistory()` (`Session.swift:540`) gates on `runtime.historyLoadState`
   (`.loading`/`.loaded` are no-ops), constructs the pipeline, and calls
   `pipeline.start(width: controller.layoutWidth)` (`:565`).
2. `start(width:)` (`TranscriptBackfillPipeline.swift:119`): seeds inbox width,
   `controller.setHistoryBackfilling(true)` (suppresses the scroller during load),
   subscribes to `coordinator.onLayoutWidthDidSettle` → `retarget`, then launches
   the detached producer.
3. Producer loop (`:132`–`:169`): `source.nextPage()` (reverse) →
   `ReverseEntryBuilder.ingest` per message (newest-first) → finalized entries in
   doc order → `MessageEntryBlockBuilder.blocks(from:)` (off-main markdown parse)
   → `Self.typeset` (off-main CTLine) → `inbox.push(PendingPage)` →
   `requestDrain()` → park on `waitForCapacity` if full.
4. `requestDrain` (`:211`): coalesce via `inbox.acquireDrainSlot()`, post
   `DispatchQueue.main.async { drain() }`.
5. `drain` (`:216`): pop pages while budget allows; **cache-hit pages (width
   matches `controller.layoutWidth`) drain free; only width-mismatched pages are
   budgeted** (`:232`–`:237`). Each page → `applyPage`.
6. `applyPage` (`:251`):
   - first page, cold table (`blockCount == 0`) → `.append` + `scrollToTail`.
   - first page, live content already present → `.prepend` w/ `.saveVisible(.visualTop)`.
   - later pages → `.prepend` w/ `.saveVisible(.visualTop)`.
   - always `onApplied(page.entries)` → `bridge.pushHistoricalStatuses` (`Session.swift:556`).
7. `reportLoaded` (`:289`): `setHistoryBackfilling(false)`, `notifyFirstScreenReady`,
   `onLoaded` → `runtime.historyLoadState = .loaded`.

### 3c. Where state ENTERS / how MessagesChange maps to Controller.Change

| MessagesChange | Bridge handler | Controller.Change emitted |
|---|---|---|
| `.appended(entry)` | `applyAppend` | `.append(blocks)` (or nothing if entry empty — still takes an `entryOrder` slot) |
| `.updated(entry)` — identical ids | `applyUpdate` case 1 | `.update(id, kind)` per changed block only |
| `.updated(entry)` — append-only prefix growth | `applyUpdate` case 2 | `.update(...)` for changed prefix + one `.replace(oldIds:[boundary], with: tail)` |
| `.updated(entry)` — structural | `applyUpdate` case 3 | `.replace(oldIds: all, with: new)` |
| `.removed(entry)` | `applyRemove` | `.remove(ids)` derived from `entryBlocks[entry.id]` |
| (cold load — NOT a MessagesChange) | pipeline `applyPage` | `.append` / `.prepend` with `precomputed:` |

### 3d. Bidirectional / back-channel coupling (MARKED)

- **Pipeline → bridge re-entry (status only).** `onApplied` routes loaded entries
  back into `bridge.pushHistoricalStatuses` (`Session.swift:556`,
  `Transcript2EntryBridge.swift:110`). So the cold path is *not* perfectly
  bridge-bypassing: content bypasses the bridge, but **status derivation is
  centralized on the bridge** and the pipeline calls back into it. This is a
  deliberate "bridge owns status derivation" decision, but it is a back-channel
  the data-flow diagram must acknowledge: the bridge has two callers (runtime
  sink + pipeline), and `pushStatuses`/`pushHistoricalStatuses` mutate no bridge
  state, so the re-entry is safe — but it couples pipeline lifetime to bridge
  existence.
- **`onLayoutWidthDidSettle` write-back into the coordinator.** `start` installs a
  closure onto `coordinator.onLayoutWidthDidSettle` (`:127`). This is a
  coordinator → pipeline notification that the pipeline registers — a hidden
  edge from the AppKit coordinator up into the pipeline's `retarget`. Last writer
  wins; if two pipelines existed they'd clobber (they can't — load-state gate).
- **`controller.layoutWidth` read on the drain (main).** The drain peeks the
  controller's *current* width to decide hit vs miss (`:232`). So the cold path
  reads live render geometry; not a mutation, but a read-coupling between drain
  scheduling and the coordinator's tile state.
- **Bridge directly reaches into `controller.coordinator`.** `applyUpdate`/`applyRemove`
  call `controller.coordinator.apply(changes, scroll:)` (`:335`, `:350`, `:394`),
  bypassing the public `controller.apply(_:scroll:precomputed:)` forwarder. See
  Smell S4.

---

## 4. Ownership & lifetime

### Live bridge
- **Constructed**: in **every** `Session.init` (`Session.swift:167`, `:191`,
  `:214`, `:238`) — eagerly, for both `.draft` and `.active` phases.
- **Retained by**: `Session.bridge` (`let`, non-optional, `Session.swift:84`).
- **Lifetime**: identical to the `Session` — survives transcript view
  mount/dismount and the draft → active flip.
- **Wired to runtime**: `wireRuntimeMessagesSink` at each `.active`-producing init
  and at `promoteOrForward` (`Session.swift:615`). The closure captures `self`
  (Session) weakly to avoid a cycle (Session owns runtime owns the closure).
- **Torn down**: when `Session` deallocs. Both have `nonisolated deinit {}`
  (macOS 26 SDK TaskLocal-abort workaround — `Transcript2EntryBridge.swift:86`,
  `Session.swift:243`).

### Backfill pipeline
- **Constructed**: lazily in `Session.loadHistory()` (`Session.swift:551`), once
  per session (re-entry gated by `historyLoadState`).
- **Retained by**: `Session.backfillPipeline` (`@ObservationIgnored private var`,
  optional, `Session.swift:90`) so the detached producer task isn't torn down
  mid-flight.
- **Lifetime**: the duration of one cold load. Never reset to nil in normal
  completion — it's retained until the `Session` deallocs or another assignment.
  (Re-entry can't rebuild it because the load-state gate short-circuits before the
  `TranscriptBackfillPipeline(...)` construction.)
- **Owns**: `source` (`let`), `inbox` (`let`, `PipelineInbox`), `task` (the
  detached producer). Holds `controller` **weak** (`:48`) — the controller
  outlives the pipeline (it's session-lifetime), so weak is conservative but
  correct.
- **Torn down**: `cancel()` (`:197`) cancels the task + resumes any parked
  producer; `nonisolated deinit {}` (`:110`). No caller invokes `cancel()` in the
  surveyed files (Session never cancels on session teardown) — see Smell S6.

### Sub-objects of the pipeline
- `JSONLReversePageSource`: constructed inline in `loadHistory` (`Session.swift:552`),
  owned by the pipeline via the `ReversePageSource` `let`. Owns the
  `ReverseLineReader` lazily (created on first `nextPage`, `JSONLReversePageSource.swift:51`).
- `ReverseLineReader`: owns the `FileHandle`; closes it in `deinit` (`ReverseLineReader.swift:35`).
- `PipelineInbox`: owns the page buffer + the single `producerWaiter` continuation.

### Pure value types (no lifetime concern)
- `MessageEntryBlockBuilder`, `ToolUseToChild`, `MarkdownToBlocks`,
  `StreamingMarkdownCommit`, `StableBlockID` are caseless enums (static-only).
- `ReverseEntryBuilder` is a value struct, instantiated fresh per producer run
  (`TranscriptBackfillPipeline.swift:133`).

---

## 5. Smells / debt

### S1. Grouping + tool-pairing logic is implemented twice (HIGH)
**Location**: `ReverseEntryBuilder.swift:35` (cold) vs `SessionRuntime+Receive.swift:274`
`appendToTimeline` + `:310` `attachToolResult` (live).
**Why**: Two separate engines produce `MessageEntry`/`GroupEntry` from `Message2`:
the live `receive` path grows groups forward inspecting `messages.last`, while the
cold path reverse-folds via `ReverseEntryBuilder`. They share only the
`isGroupableAssistant` predicate (`SessionRuntime+Receive.swift:701`) and a tested
1:1 parity assertion (`TranscriptReverseBuilderTests.A6`, cited in
`ReverseEntryBuilder.swift:13`). The two must stay behaviorally identical but have
no shared implementation — a grouping-rule change must be made in two places and
the parity test is the only guard. The comments throughout `ReverseEntryBuilder`
explicitly cross-reference `receive`'s behavior ("just as they don't in
`appendToTimeline`", `:29`), which is documentation papering over duplicated
control flow. This is the single largest "non-unidirectional / duplicated state"
hazard in this area.

### S2. `StreamingMarkdownCommit` is filed in the bridge directory but consumed only by the runtime (MEDIUM)
**Location**: `StreamingMarkdownCommit.swift:18`; consumers at
`SessionRuntime+Streaming.swift:207`, `:219`, `:222`.
**Why**: Nothing in `NativeTranscript2Bridge/` references it (verified by grep).
It's a pure string policy used by the Session/runtime streaming layer to decide
what text to surface as a `MessageEntry`. Its placement implies it's part of the
entry→block bridge, but the actual dependency edge is Session → it. This is a
leaky directory boundary: the file belongs next to `StreamingTurnAssembler` under
`Services/Session/Session/`, or the bridge dir's role should be documented to
include "streaming-text policy shared with the runtime." Misfiling makes the
"Session domain vs render types" boundary (the survey focus) blurrier than it is.

### S3. The "Session domain vs render types" boundary is clean in direction but the bridge knows too much about `Message2`/`ToolUse` internals (MEDIUM)
**Location**: `Transcript2EntryBridge.swift:217`–`:259` (`pushSingleEntryStatuses` /
`pushGroupEntryStatuses`), `ToolUseToChild.swift:39`–`:220`.
**Why**: The translation direction is correctly one-way (domain → render; render
types never leak back into Session). But the bridge's **status derivation**
re-walks `Message2Assistant.message?.content`, re-extracts `ToolUse`, and
re-derives the `toolUseId`/`childId` (`:224`–`:233`) using the *same* fallback
string (`"tu|\(...)|\(idx)"`) and the *same* `StableBlockID.derive("tool", …)` as
`MessageEntryBlockBuilder.assistantBlocks` (`:221`) and
`ToolUseToChild.make` (`:28`). The id-derivation coordinate
(`("tool", toolUseId)`, `("entry", id, "tg", idx)`, `("group", id)`) is replicated
across `MessageEntryBlockBuilder`, `Transcript2EntryBridge`, and `ToolUseToChild`
with no shared helper. A change to the id scheme touches three files and the
fallback string is duplicated verbatim in four places. The block builder and the
status pusher are two passes over the same `Message2` shape that must agree on ids
by convention, not by construction.

### S4. Bridge bypasses the public controller API for `.update`/`.remove` (LOW)
**Location**: `Transcript2EntryBridge.swift:335`, `:350`, `:394` call
`controller.coordinator.apply(changes, scroll:)` directly; `:299`, `:357`, `:365`
use the public `controller.apply(...)`.
**Why**: Inconsistent. `controller.apply` takes variadic `Change...`; the bridge
needs to pass an **array** of `.update`s, which the variadic forwarder can't
express, so it reaches through to `coordinator.apply([...])`. The result is the
bridge depends on `controller.coordinator` being module-visible (it is — `let
coordinator`, `:148`) and the "controller is the host-facing surface, coordinator
is AppKit-facing" split (renderer CLAUDE.md §1.1) is violated by a non-AppKit
caller. The clean fix is an array-accepting overload on `Transcript2Controller.apply`
so the bridge never names `coordinator`. Low severity (same actor, same sink) but
it's the one place the bridge knows the controller's internals.

### S5. `Transcript2EntryBridge` carries three orthogonal responsibilities (MEDIUM)
**Location**: `Transcript2EntryBridge.swift` (whole file, ~397 lines).
**Why**: The class does (a) minimal-diff block reconciliation (`applyAppend`/
`applyUpdate`/`applyRemove` + `entryOrder`/`entryBlocks`), (b) first-user
queued-bubble suppression (`firstUserEntryId` + `applyFirstUserSuppression` +
`isUserTyped`), and (c) tool-status derivation (`pushStatuses` family + the
live/historical mode table). These are independently testable and only loosely
related — (b) is a cosmetic override on top of (a); (c) shares no mutable state
with (a)/(b) ("No mirror state", `:175`). The status-derivation block (`:166`–`:274`)
could be a free function or a `ToolStatusDeriver` namespace, leaving the bridge as
a pure block-reconciler. The first-user pin is a third concern entangled into
`applyAppend`/`applyRemove`. Not oversized by line count, but three axes of change
in one type.

### S6. `TranscriptBackfillPipeline.cancel()` is never called on session teardown (LOW)
**Location**: `TranscriptBackfillPipeline.swift:197` (`cancel`); no caller in
`Session.swift` (the `backfillPipeline` is just dropped/overwritten).
**Why**: On `Session` dealloc, the pipeline is released, but the detached
producer task holds `[weak self]` and the inbox/source by capture
(`:130`–`:132`). The task checks `Task.isCancelled`? — no, the producer loop
(`:134`) loops on `source.nextPage()` and only weakly self-references for
`requestDrain`. Without an explicit `cancel()`, a long cold load on a session the
user navigated away from (and then closed) keeps reading the file to completion
off-main. Functionally harmless (it weak-nils on drain), but it's a resource leak
window and `cancel()` exists precisely for it yet is unwired. Note: warm re-entry
never builds a pipeline, so this only bites a session torn down mid-cold-load.

### S7. `requestDrain` posts to `DispatchQueue.main.async` from a `@MainActor` class — actor/queue duality (LOW)
**Location**: `TranscriptBackfillPipeline.swift:211`–`:214` (`nonisolated func
requestDrain` → `DispatchQueue.main.async { self?.drain() }`).
**Why**: The class is `@MainActor` but `requestDrain` is `nonisolated` and uses
the raw GCD main queue rather than the actor's executor (it must, because it's
called from the off-main producer). This is correct and documented, but it means
the pipeline mixes actor isolation with manual queue hops — a reader has to track
which methods run where (`start`/`drain`/`applyPage` = main-actor; `typeset`/
`requestDrain` = nonisolated; the `Task.detached` body = off-main). The
`PipelineInbox`'s `@unchecked Sendable` + `NSLock` is the real synchronization;
the `@MainActor` annotation on the class is partly aspirational. Not a bug, but
the threading model is subtle enough that it's a maintenance hazard (it's heavily
commented for exactly this reason).

### S8. `ToolUseToChild.Agent` builds identical `progress` and `output` from the same source (LOW)
**Location**: `ToolUseToChild.swift:197`–`:202`.
**Why**: `progressTexts` and `outputTexts` are both `(obj.content ?? []).compactMap { $0.text }` —
the same array computed twice, then `output` is the join and `progress` is the raw
list. So the agent card's "progress" and "output" render the same text. Likely a
latent bug or an unfinished distinction (progress vs final output should differ),
not a structural smell, but it's duplicated computation producing duplicated
content.

### S9. Empty-entry handling is a special case threaded through two paths (LOW)
**Location**: `Transcript2EntryBridge.swift:286`–`:293` (live append of an entry
that produced no blocks still takes an `entryOrder`/`entryBlocks` slot);
`TranscriptBackfillPipeline.swift:141`, `:144` (cold path `guard !finalized.isEmpty`
/ `guard !blocks.isEmpty` simply `continue`s — no slot kept).
**Why**: The two paths treat "entry produces zero blocks" differently. The bridge
keeps a placeholder slot so a later mutate resolves anchors; the pipeline drops
the page silently. Because history never re-mutates (load is one-shot), this is
correct — but it's an asymmetry that a refactor unifying the two builders would
have to preserve, and it's invisible unless you read both.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

### I1. History never flows through the bridge (the two paths are disjoint by design)
`MessagesChange` is live-only (`MessagesChange.swift:9`–`:11`); the pipeline applies
blocks **directly** to the controller (`TranscriptBackfillPipeline.swift:257`,
`:270`, `:279`). The bridge's `firstUserEntryId` pin relies on this: it only ever
sees live `.appended` turns, so the *next live send after a resume* gets the pin,
never a replayed historical turn (`Transcript2EntryBridge.swift:59`–`:64`). A
refactor that routes history through `bridge.apply` would (a) flood the
minimal-diff reconciler with `.replace`/`.update` it isn't built for on the load
path (forbidden by §4.2 "no `.update` on load",
`ReverseEntryBuilder.swift:34`), and (b) corrupt the first-user pin.

### I2. Off-main build + off-main typeset; main only sync-applies cache hits (renderer §2.5/§2.6)
The producer runs markdown parse (`MarkdownDocument`) **and** `RowLayout` typeset
(`Transcript2Coordinator.makeLayout`) off-main (`TranscriptBackfillPipeline.swift:143`,
`:146`, `:188`). `makeLayout` **must stay `nonisolated static`** and actor-free.
The precomputed layouts install **before** the structural change via `apply(…,
precomputed:)` so the `heightOfRow` query inside `insertRows`/`endUpdates` is a
cache hit, not an on-main CTLine pass. Moving either build onto main = 100+ ms cold
freeze (renderer §2.6).

### I3. The drain budget bounds only width-mismatched (cache-miss) pages
`drain` (`TranscriptBackfillPipeline.swift:232`–`:237`): cache-hit pages (width ==
`controller.layoutWidth`) drain **free** and uncapped (first screen lands in one
tick); only width-mismatched pages count toward `budget`. The peek-before-pop
(`:220`, `peekFirstWidth`) keeps a budget-deferred miss page in the buffer for the
next tick. A refactor that budgets all pages would split the first screen across
ticks (visible cold-load jank); one that budgets nothing would let a resize-during-
load freeze main.

### I4. Typeset-width self-healing — no validate gate
A `PendingPage` typeset at a stale width is a `heightOfRow` cache **miss** that
lazy-recomputes (renderer §4.3/§4.4), never a corruption
(`TranscriptBackfillPipeline.swift:42`, `:179`). `start(width:)` seeds the width
once (post-attach-settle `controller.layoutWidth`); `retarget`/`onLayoutWidthDidSettle`
updates it at resize-end only. Do **not** add a "discard stale-width page" gate —
the self-heal is the contract.

### I5. Status is an independent, color-only channel (renderer §2.13)
The bridge pushes status via `controller.setToolStatus` (`Transcript2EntryBridge.swift:228`,
`:233`, `:253`, `:257`), **never** via `Change.update`. `setToolStatus` is
idempotent and caches statuses for ids the coordinator hasn't seen yet
(`:170`–`:172`), so status push can precede or follow the structural change. The
cold path's historical status is derived in `.historical` mode (no `.running`)
and routed back through the bridge via `onApplied` (`Session.swift:556`). A
refactor must keep status off the structural channel (else it drops selection /
highlight tokens / forces `noteHeightOfRows`).

### I6. `StableBlockID` identity is deterministic and content-independent
`Block.id`/`Child.id` are derived from `(entryId, role, idx…)` via SHA256
(`StableBlockID.swift:19`), **not** content hashes. The same entry across state
transitions (`.localUser` → `.remote.user`, tool_result back-fill, group growth)
must yield the **same** id so the coordinator's `.update` swaps kind in place and
preserves fold/selection/animation (`MessageEntryBlockBuilder.swift:5`–`:13`,
renderer §2.18). The id coordinate scheme is a cross-file contract (S3): the
block builder, the status pusher, and `ToolUseToChild` must all derive the same
ids. The user-bubble id specifically must survive `.localUser → .remote.user`
(`MessageEntryBlockBuilder.swift:178`–`:181`) or the bubble degrades to
remove+insert and loses animation/selection.

### I7. Minimal-diff emission must not re-typeset settled rows
`applyUpdate`'s three cases (`Transcript2EntryBridge.swift:333`, `:341`, `:363`)
are tuned so streaming growth never removes/reinserts settled blocks above the tail
(no `.effectFade` flicker) and never re-`.update`s a block whose `kind` didn't move
(`changedUpdates`, `:372`). The append-only case anchors the insert *inside the
entry's own range* by re-stating the boundary block via `.replace` (`:356`–`:357`)
so new blocks never land at the table tail past the loading pill. Preserving these
three cases (and the prefix check `Array(newIds.prefix(oldIds.count)) == oldIds`,
`:342`) is required for streaming-render correctness and FPS.

### I8. Reverse pairing depends on document-order-within-page + cross-page withhold buffer
`ReverseEntryBuilder` withholds an orphan `tool_result` keyed by `tool_use_id`
until its `tool_use` is reached above (`ReverseEntryBuilder.swift:71`–`:80`,
`:133`–`:146`); the buffer survives across `ingest` calls so it spans page
boundaries (`:23`). `JSONLReversePageSource` parses each page in **document order**
(`JSONLReversePageSource.swift:74`–`:75`) so the per-page resolver pairs adjacent
use/result. A refactor of the paging must keep (a) per-page doc-order parse and
(b) the cross-page withhold buffer, or tool results split across a page boundary
mispair.

### I9. Open group runs are never emitted speculatively on the load path
`ReverseEntryBuilder` finalizes a group only when an older non-groupable message
closes it (or at `finish()`) — `ReverseEntryBuilder.swift:30`–`:34`, `:104`–`:114`.
Emitting a partial group and growing it later would force a `.replace` on the load
path, which I1's "no `.update` on load" forbids. The `finish()` flush (still-open
run + true orphans, `:104`) is load-bearing for the file-top page.

### I10. `firstUserEntryId` pin semantics (cosmetic, but tested behavior)
The first **live** user-typed entry gets `isQueued` rewritten to `false`
(`Transcript2EntryBridge.swift:137`–`:145`, `:282`); set **before** the
`blocks(for:)` build so the suppression sees it (`:281`–`:285`). Released on
removal of the first message (`:390`). This depends on I1 (history never reaches
the bridge). Preserve the "set pin before build" ordering.

### I11. The bridge is wired exactly once per session and survives mount/dismount
`wireRuntimeMessagesSink` is called at each `.active`-producing init and at
promotion (`Session.swift:174`, `:240`, `:615`) — never re-wired on view attach.
Live events flow into `controller.blocks` even with no table bound
(Services/Session CLAUDE.md). A refactor must not move bridge wiring into the view
layer or gate it on a mounted table.

---

## Cross-references
- Renderer contract this area feeds: `Content/Chat/NativeTranscript2/CLAUDE.md`
  (§2.5 off-main layout, §2.6 backfill, §2.13 status channel, §2.18 stable ids,
  §3.4 Change dispatch).
- Session/runtime side: `Services/Session/CLAUDE.md` ("Talking to the renderer",
  the AppKit channel rules, `wireRuntimeMessagesSink`).
- Downstream consumer (host VC, hosting boundaries): `survey-chat-detail-vcs.md`.
- Renderer internals: `survey-transcript-renderer.md`.
