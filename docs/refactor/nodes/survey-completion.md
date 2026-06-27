# Survey: Completion subsystem (slash commands, file paths, triggers)

Scope: `Content/Chat/Completion/` + `Services/Completion/` +
`Content/Chat/BuiltinSlashCommandHandler.swift`, plus the call sites in
`InputBarView2`, `InputBarChrome`, `DraftSessionLandingViewController`.

This is the `@`-file-mention / `/`-slash-command completion popup that floats
above the chat input pill. It is **entirely SwiftUI** — there is no AppKit
surface in this subsystem (the only AppKit is `NSImage`/`NSWorkspace` for
icons, `FSEventStream` in the directory monitor, and `Process` for spawning
`git ls-files` / `fzf` / the temp CLI). The popup hosts inside the SwiftUI
`InputBarView2` body, which is itself hosted in AppKit via `NSHostingView`
(see §2).

---

## 1. Component / type inventory

### `Content/Chat/Completion/`

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `CompletionViewModel` | `@Observable final class` (`nonisolated deinit`) | The popup's state machine: trigger detection, debounced query refresh, item list, selection index, loading/empty reason, confirm. The ONLY ViewModel in the chat area. | `CompletionViewModel.swift:7` |
| `CompletionViewModel.EmptyReason` | nested enum | `.loading` / `.noMatches` / `.noDirectory` — drives the empty-row variant. | `CompletionViewModel.swift:23` |
| `CompletionViewModel.CompletionSession` | nested struct (8 stored closures/values) | An active trigger's full behavior bundle: `anchorLocation`, `provider`, `makeReplacement`, `onItemConfirmed`, `validateAndConfirmFromInput`, `customWordRange`, `transformQuery`, `headerText`, `emptyReasonOverride`. Constructed by a trigger rule. | `CompletionViewModel.swift:68` |
| `CompletionListView` | SwiftUI `View` | Renders the popup: header row, empty row, item rows (icon + badge + text + inline 2-line description for the selected row + recent-dir delete affordance). Sizes itself via `listHeight`. | `CompletionListView.swift:4` |
| `CompletionTriggerRule` | protocol | `match(text:cursorLocation:context:) -> CompletionSession?` — one rule = one trigger type. | `CompletionTriggerRule.swift:8` |
| `CompletionTriggerContext` | struct (value bag) | Per-`checkTrigger` snapshot of config: `directory`, `additionalDirs`, `pluginDirs`, `knownSlashCommands`, `onBuiltinCommand`. Built fresh each call. | `CompletionTriggerRule.swift:19` |
| `SlashCommandTriggerRule` | struct : `CompletionTriggerRule` | Detects `/` at offset 0. Builds the slash session: merges builtins (`/new`,`/clear`) + CLI commands from `SlashCommandStore`, dedup, replacement splicing. | `CompletionTriggerRule.swift:69` |
| `FileMentionTriggerRule` | struct : `CompletionTriggerRule` | Detects `@` preceded by whitespace/SOT. Builds the file session via `FileCompletionStore`; quote-aware word range + quote stripping. | `CompletionTriggerRule.swift:155` |
| `CompletionItem` | protocol | `displayText` / `displayIcon` / `displayDetail` / `displayBadge`. Default `displayBadge == nil`. | `CompletionItem.swift:3` |
| `DirectoryCompletionItem` | struct : `CompletionItem` | A folder pick with `isRecent` flag + home-relative `~` display. **Never constructed anywhere** (see Smell #1). | `DirectoryCompletionItem.swift:4` |

### `Services/Completion/`

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `CompletionPrewarmer` | `enum` (namespace, static fns only) | Single fan-out prewarm entry: `prewarm(Key)` warms `FileCompletionStore` + `SlashCommandStore`. | `CompletionPrewarmer.swift:17` |
| `CompletionPrewarmer.Key` | nested `Equatable` struct | `(directory, additionalDirs, pluginDirs)` cache key; stable for SwiftUI `.task(id:)`. | `CompletionPrewarmer.swift:21` |
| `FileCompletionStore` | `final class` singleton (`.shared`) | Per-cwd file-index cache (`git ls-files` → fallback `find`), FSEvents-incremental, fzf fuzzy match (single + multi-dir tagged). Serial `DispatchQueue`. | `FileCompletionStore.swift:6` |
| `FileCompletionStore.Match` | nested struct : `CompletionItem` | One file/dir match: `path` / `rank` / `sourceDir` badge; derives display icon from UTType. | `FileCompletionStore.swift:10` |
| `FileCompletionStore.Entry` | fileprivate struct | Cached `(files, monitor, fzfInputFile)` per directory. | `FileCompletionStore.swift:409` |
| `SlashCommandStore` | `final class` singleton (`.shared`) | Per-`(path, pluginDirs)` slash-command cache. Chat mode: synchronous filter of CLI-supplied `knownCommands`. Compose mode: spins a temp `AgentSDK.Session`, `initialize(promptSuggestions:)`, caches, stops. FSEvents invalidation on `.claude/{skills,commands}`. | `SlashCommandStore.swift:15` |
| `SlashCommandStore.Match` | nested struct : `CompletionItem` | One slash command: `name` / `description` / `rank`; `displayText = "/name"`, text-only (no icon). | `SlashCommandStore.swift:19` |
| `SlashCommandStore.CacheKey` / `.CacheEntry` | fileprivate structs | `(path, Set<pluginDirs>)` key; `(commands, monitors)` entry. | `SlashCommandStore.swift:227`,`:232` |
| `BuiltinSlashCommand` | `enum String, CaseIterable` | `.new` / `.clear` CCTerm-native commands; `displayText`, localized `detail`. | `BuiltinSlashCommand.swift:13` |
| `BuiltinCompletionItem` | struct : `CompletionItem` | Wraps a `BuiltinSlashCommand` so it rides the same popup; detected by `item is BuiltinCompletionItem`. | `BuiltinSlashCommand.swift:37` |
| `DirectoryCompletionProvider` | `enum` (namespace) | `loadRecentFolders()` / `removeFromRecent(_:)` over `UserDefaults["folderPickerRecent"]`. Producer side **never wired** (see Smell #1). | `DirectoryCompletionProvider.swift:3` |
| `DirectoryTreeMonitor` | `final class` | FSEventStream wrapper → `[Event]` callbacks on a utility queue. Used by both stores. | `DirectoryTreeMonitor.swift:3` |

### Handler (lives outside `Completion/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `runBuiltinSlashCommand(_:currentSessionId:sessionManager:model:)` | free `@MainActor func` | Dispatches `/new` / `/clear`: create seeded draft, (`/clear`) archive source, `model.select(.session(draftId))`. Mirrors `submitSessionInput`. | `BuiltinSlashCommandHandler.swift:15` |

---

## 2. Component tree (this area)

AppKit / SwiftUI / hosting boundaries marked. The completion popup is a
SwiftUI subtree nested inside `InputBarView2`'s `pill`; `InputBarView2`
itself is hosted in AppKit two different ways depending on the parent VC.

```
ChatSessionViewController (AppKit NSViewController)                       [chat mode]
└─ NSHostingView<ChatRestingBar>   ── sizingOptions = [.intrinsicContentSize]  (bottom-anchored bar)
   └─ ChatRestingBar (SwiftUI)
      └─ InputBarChrome (SwiftUI)        ── owns .task(id: prewarmKey) → CompletionPrewarmer.prewarm
         └─ InputBarView2 (SwiftUI)      ── @State completion = CompletionViewModel()   ← state lives HERE
            └─ pill (SwiftUI VStack)
               ├─ if completion.isActive:
               │    CompletionListView (SwiftUI)            ── @Bindable viewModel: CompletionViewModel
               │       └─ ScrollViewReader → ScrollView → LazyVStack
               │            ├─ header row (folder.badge.questionmark)
               │            ├─ emptyRow  (loading / noMatches / noDirectory)
               │            └─ ForEach items → completionRow → commandLine
               │                 ├─ Image(nsImage: item.displayIcon)
               │                 ├─ badge / displayText / inline 2-line detail
               │                 └─ (DirectoryCompletionItem only) "recent" pill + delete X   ← dead path
               ├─ thumbnailStrip (attachments)
               └─ HStack(textArea, sendOrStopButton)
                    └─ textArea → TextInputView (NSViewRepresentable, wraps NSTextView)
                         · onTextChanged → completion.checkTrigger(...)
                         · onCommandReturn / onEscape / keyInterceptor → completion nav+confirm

DraftSessionLandingViewController (AppKit NSViewController)               [/new /clear landing]
└─ NSHostingController<AnyView(DraftSessionLandingView)>  ── sizingOptions = []  (fill-the-pane)
   └─ DraftSessionLandingView (SwiftUI)
      └─ InputBarChrome → InputBarView2 → (same subtree as above)

ComposeSessionViewController (AppKit, .newSession tab)                    [compose card]
└─ NSHostingController<ComposeSessionView>  ── sizingOptions = []
   └─ … → InputBarChrome (onBuiltinCommand = nil) → InputBarView2 → (same subtree)
```

Key boundary facts:
- The completion popup never crosses the AppKit↔SwiftUI boundary on its own.
  It is pure SwiftUI inside `InputBarView2`. The only AppKit it touches
  directly is `TextInputView` (the `NSTextView` wrapper), which is itself
  an `NSViewRepresentable` sibling inside the same SwiftUI body.
- `CompletionViewModel` is created `@State` in `InputBarView2`
  (`InputBarView2.swift:167`) — one per `InputBarView2` instance, i.e. one
  per session's input bar. `CompletionListView` receives it as `@Bindable`
  (`CompletionListView.swift:5`).
- The stores (`FileCompletionStore.shared` / `SlashCommandStore.shared`) are
  process-wide singletons reached directly from inside the trigger rules'
  `provider` closures — they are NOT injected and NOT in `AppState`.

---

## 3. Data flow

### Inbound (config → popup)

Direction is **downward and re-snapshotted every render** — there is no
subscription. Config lives on `Session` (`@Observable`); `InputBarChrome`
reads `session.cwd` / `session.additionalDirectories` /
`session.pluginDirectories` / `session.slashCommands` each render and passes
them as plain values into `InputBarView2` (`InputBarChrome.swift:59-71`).
`InputBarView2.triggerContext` (`InputBarView2.swift:482`) rebuilds a fresh
`CompletionTriggerContext` value bag on every access. So when the user
switches folders or the CLI's `initialize` lands, the next keystroke's
`checkTrigger` sees current config with **no stateful resubscription** — this
is called out as deliberate in `CompletionTriggerRule.swift:17-18` ("Built
fresh per `checkTrigger` call … without any stateful subscription dance").

### Trigger → query → items (the core loop)

1. `NSTextView` edit → `TextInputView.onTextChanged(newText, cursor)` →
   `completion.checkTrigger(text:cursorLocation:hasMarkedText:context:)`
   (`InputBarView2.swift:380-387`).
2. `checkTrigger` (`CompletionViewModel.swift:155`) stores `text` +
   `cursorLocation`, runs `detectTrigger` (iterates `rules`, first match wins
   — `CompletionViewModel.swift:196`). Session lifecycle:
   - new anchor differs from active → `dismiss()` then `startSession`
   - anchor char deleted → `dismiss()` (+ restart if a new trigger appeared)
   - same anchor → `refreshQuery()`
3. `refreshQuery` (`CompletionViewModel.swift:225`) extracts the word, dedups
   against `lastQuery`, bumps `generation`, cancels `debounceTask`. Empty
   query → immediate provider call; non-empty → 150ms debounce + a nested
   50ms "show loading spinner" task, then provider call.
4. `session.provider(query) { results in ... }` runs async (store hops to its
   serial queue, then `DispatchQueue.main.async` back). The completion
   handler **guards on `generation == currentGen`** before writing `items` /
   `selectedIndex` / `isLoading` / `emptyReason` (`CompletionViewModel.swift:247`,
   `:269`) — this is the staleness guard against out-of-order async results.
5. `items` is `@Observable` → `InputBarView2.pill` re-evaluates →
   `completion.isActive` flips → `CompletionListView` appears.

`isActive` (`CompletionViewModel.swift:40`) is a **computed property** off
`activeSession` + `cursorLocation` + `wordRange`, not a stored flag — the
popup's visibility is derived state.

### Confirm / navigation → text mutation (outbound)

This is the **bidirectional back-channel** — the popup writes back into the
input's text:

- Up/Down/Tab/Return while open → `TextInputView.keyInterceptor`
  (`handleCompletionKey`, `InputBarView2.swift:495`) → `completion.moveSelection*`
  or `completion.confirmSelection()`.
- `confirmSelection()` (`CompletionViewModel.swift:284`) computes
  `session.makeReplacement(item, text, wordEnd)`, fires
  `session.onItemConfirmed?(item)` (the builtin dispatch side effect), then
  `dismiss()`, and **returns `(range, replacement)`** to the view.
- `InputBarView2.applyReplacement` (`InputBarView2.swift:530`) splices the
  replacement into `@State text` and sets `desiredCursorPosition` →
  `TextInputView` moves the `NSTextView` caret. **The mutation flows VM →
  View → NSTextView**, not VM → store.
- Tap on a row → `CompletionListView.onTapGesture` sets
  `viewModel.selectedIndex = index` then calls `onConfirm(item)` →
  `confirmCompletion` → same `confirmSelection()` path
  (`CompletionListView.swift:146-149`, `InputBarView2.swift:521`).
- Builtin confirm: `onItemConfirmed` → `onBuiltinCommand(builtin)` →
  (`InputBarChrome` had threaded the VC's closure) →
  `runBuiltinSlashCommand` → `SessionManager.createSidebarDraft` +
  `model.select(...)`. This is the one path where a completion confirm
  reaches all the way out to **app-level navigation**, not just text.

### Prewarm (side path, fire-and-forget)

`InputBarChrome.task(id: prewarmKey)` (`InputBarChrome.swift:78`) →
`CompletionPrewarmer.prewarm(key)` → `FileCompletionStore.warm(directories:)`
+ `SlashCommandStore.warm(path:pluginDirs:)`. Each `warm` enqueues
`ensureLoaded` / `launchTempCLI` on the store's serial queue so a later
`complete(...)` lands behind the warm and hits a hot cache. No result flows
back to the VM — the only observable effect is that the first real
`provider` call returns fast.

### Store internals (FACT)

- `FileCompletionStore`: `complete` hops to the serial queue,
  `ensureLoaded(directory)` lazily runs `git ls-files` (fallback `find`) +
  extracts intermediate dirs + starts a `DirectoryTreeMonitor`, caches the
  `Entry`. fzf is spawned per non-empty query (`runFzf` / `runFzfTagged`),
  reading from a cached temp input file (`ensureFzfInputFile`,
  `FileCompletionStore.swift:301`) invalidated on FS events
  (`handleFSEvents` sets `entry.fzfInputFile = nil`, `:205`). Result hops
  back via `DispatchQueue.main.async`.
- `SlashCommandStore`: `complete` with `knownCommands != nil` →
  synchronous substring `matchCommands` (no fzf, no subprocess —
  `SlashCommandStore.swift:80`,`:209`). With `nil` →
  `resolveCommands` coalesces concurrent callers on `pendingCallbacks[key]`
  and `launchTempCLI` spins an `AgentSDK.Session`, `initialize`s, caches +
  drains callbacks (`didFinishLoad`, `:163`). `onProcessExit` is a safety
  drain if the CLI dies before answering (`:127`).

---

## 4. Ownership & lifetime

| Object | Constructed by | Retained by | Torn down |
|---|---|---|---|
| `CompletionViewModel` | `InputBarView2` `@State` initializer (`InputBarView2.swift:167`) | SwiftUI `@State` storage of the `InputBarView2` instance (one per session input bar) | When `InputBarView2`'s identity is destroyed (session switch tears down the hosting tree). The `nonisolated deinit {}` (`CompletionViewModel.swift:9-19`) exists specifically because that teardown can run from a Task continuation under the Xcode 26 concurrency runtime — same posture as `Session.deinit` / `SessionRuntime.deinit`. |
| `CompletionViewModel.CompletionSession` | a `CompletionTriggerRule.match` (`CompletionTriggerRule.swift:72`,`:170`) | `CompletionViewModel.activeSession` (private) | Replaced/cleared by `dismiss()` or a new `startSession` |
| `CompletionTriggerContext` | `InputBarView2.triggerContext` computed prop (`InputBarView2.swift:482`) | Nobody — transient value, lives only for the `checkTrigger` call | n/a (value type) |
| `rules: [CompletionTriggerRule]` | `CompletionViewModel` stored property (`CompletionViewModel.swift:61`) | The VM, for its lifetime | with the VM |
| `FileCompletionStore.shared` / `SlashCommandStore.shared` | static `let` lazy singleton (`FileCompletionStore.swift:39`, `SlashCommandStore.swift:31`) | Process-global; never released | never |
| `FileCompletionStore.Entry.monitor` (`DirectoryTreeMonitor`) | `ensureLoaded` (`FileCompletionStore.swift:166`) | the store's `entries` dict | `invalidate(directory:)` / `invalidateAll()` drop the entry → monitor `deinit` → `stop()`. NOTE: there is no caller of `invalidate*` (see Smell #5) — monitors persist for the process lifetime once a dir is touched. |
| `SlashCommandStore.CacheEntry.monitors` | `buildMonitors` (`SlashCommandStore.swift:174`) | the store's `cache` dict | dropped on FS event (the monitor's own callback removes its key, `:196`) or `invalidateAll()`. |
| temp `AgentSDK.Session` (slash compose fetch) | `launchTempCLI` (`SlashCommandStore.swift:125`) | local to the closure / Task | `session.stop()` after `initialize` responds (`:147`) or `onProcessExit` |
| `debounceTask` / nested `loadingTask` | `refreshQuery` (`CompletionViewModel.swift:255`,`:259`) | the VM (`debounceTask`) | cancelled on next `refreshQuery` / `dismiss` |
| `CompletionPrewarmer.Key` | `InputBarChrome.prewarmKey` (`InputBarChrome.swift:41`) | transient (SwiftUI `.task(id:)` holds it for comparison) | n/a |

Construction rule compliance: `CompletionViewModel` is created as view
`@State`, which technically violates the project rule "Views never construct
services themselves" — but it is a **ViewModel**, not a service, and it is
genuinely view-private UI state (popup selection/visibility). The stores
(the actual services) are reached as singletons, not constructed by views.

---

## 5. Smells / debt

### Smell #1 — Dead "directory completion" path (HIGH)
`DirectoryCompletionItem`, `DirectoryCompletionProvider`, and the VM's
`validateAndConfirmFromInput` / `tryConfirmFromInput()` / `hasInputValidation`
/ `emptyReasonOverride: .noDirectory`-for-folder-pick machinery are
**vestigial**. Grep proves it:
- `DirectoryCompletionItem(` is **never constructed** anywhere in the repo.
- `tryConfirmFromInput()` (`CompletionViewModel.swift:298`) has **zero
  callers**.
- `hasInputValidation` (`CompletionViewModel.swift:51`) has **zero callers**.
- `validateAndConfirmFromInput` is only read by those two unused members.
- `DirectoryCompletionProvider.loadRecentFolders()` has **zero callers**
  (only `removeFromRecent` is called, from the dead `onDeleteRecent` branch).
- The `onDeleteRecent` closure (`InputBarView2.swift:254-260`) and the
  "recent" pill + delete-X in `CompletionListView.swift:185-201` only fire
  for `DirectoryCompletionItem`, which never enters the list.

Evidence: `git log` shows these files untouched since the original PR #155
("file/folder mention completion"); a later refactor (PR #243 "Simplify
completion interaction") kept the now-orphaned folder-pick scaffolding. Why
it matters: it inflates the `CompletionSession` surface from "what slash + @
need" to "what slash + @ + a folder-picker-that-no-longer-exists need,"
making the VM look far more general than its two real callers require.
Location: `DirectoryCompletionItem.swift:1-26`,
`DirectoryCompletionProvider.swift:1-26`, `CompletionViewModel.swift:51`,`:85`,
`:298-310`, `CompletionListView.swift:185-201`, `InputBarView2.swift:254-260`.

### Smell #2 — `CompletionSession` is a 7-closure config bag (MEDIUM)
`CompletionSession` (`CompletionViewModel.swift:68-115`) carries 7
optional/required closures (`provider`, `makeReplacement`, `onItemConfirmed`,
`validateAndConfirmFromInput`, `customWordRange`, `transformQuery`) plus 3
data fields. This is "strategy object via closures" — flexible, but the
behavior of a trigger is scattered across closure literals inside
`match(...)`. With only 2 live rules (slash, @-file), and 3 of the 7 closures
dead (#1), this is over-parameterized for its actual use. A refactor could
collapse it once the dead members are removed. Severity medium because it's
not wrong, just heavier than the two real cases need.
Location: `CompletionViewModel.swift:68-115`.

### Smell #3 — Inconsistency: "no ViewModel" everywhere else, but a ViewModel here (MEDIUM — but JUSTIFIED)
`Content/Chat/CLAUDE.md:3` states the chat area has **no ViewModel** by
design, and `:61` says "Don't introduce a new ViewModel layer." Yet this
subsystem's central type is literally `CompletionViewModel`. This is the most
visible pattern inconsistency in the area. **Assessment (INFERENCE): the
exception is justified, and the rule is about a different axis.** The chat
"no ViewModel" rule is about **session/transcript state** — that data lives
on `Session`/`SessionRuntime` and views read `@Observable` fields directly,
never a mirror. The completion popup is **genuinely view-private interaction
state** (which item is highlighted, is the popup open, the debounce timer,
the transient query) that has no home on `Session` and no business being
there. SwiftUI's own idiom for "stateful interaction logic too big for
`@State` scattered in a body" is exactly an `@Observable` object. So this is
not the kind of ViewModel the rule forbids (a coordinating mirror of model
state); it's a self-contained input-method state machine. The naming is what
creates the friction — calling it `…ViewModel` reads as a violation at a
glance. Severity medium for the *confusion*, low for the *actual design*.
Location: `CompletionViewModel.swift:7` vs `Content/Chat/CLAUDE.md:3`,`:61`.

### Smell #4 — Two stores are singletons; everything else is injected (MEDIUM)
`FileCompletionStore.shared` and `SlashCommandStore.shared` are
process-global singletons reached directly from inside trigger-rule closures
(`CompletionTriggerRule.swift:132`,`:175`,`:179`). The rest of the app
injects services through `AppState` + `.environment()`
(`SessionManager`, `SyntaxHighlightEngine`, `RecentProjectsStore`,
`InputDraftStore`, etc. — root `CLAUDE.md`). These two stores are the
exception. Consequence: untestable in isolation without touching the real
filesystem / spawning real subprocesses (the `BuiltinSlashCommandTests` only
exercises the synchronous builtin path precisely because the store path
"spawns a subprocess" — `BuiltinSlashCommandTests.swift:18-19`). A refactor
toward unidirectional/clean deps would inject these like the other services.
Severity medium — it's a real coupling/testability gap, balanced by the fact
that a per-directory cache genuinely wants a single process-wide instance.
Location: `FileCompletionStore.swift:39`, `SlashCommandStore.swift:31`,
`CompletionTriggerRule.swift:132`,`:175`,`:179`.

### Smell #5 — `FileCompletionStore` cache + FS monitors are never invalidated/bounded (MEDIUM)
`invalidate(directory:)` / `invalidateAll()` (`FileCompletionStore.swift:145`,
`:152`) have **zero callers** (grep). Once a directory is touched, its file
index AND its `DirectoryTreeMonitor` (an `FSEventStream`) live for the whole
process lifetime. There is no LRU / no cap. For a user who opens many
projects in one session this is an unbounded set of live FSEvent streams +
file lists. Not a correctness bug (each is self-updating), but a slow leak.
`SlashCommandStore` is better off — its monitors self-invalidate the cache
key on FS events. Severity medium.
Location: `FileCompletionStore.swift:44`,`:145-156`.

### Smell #6 — Hand-rolled generation guard + manual debounce + nested loading task (MEDIUM)
`refreshQuery` (`CompletionViewModel.swift:225-278`) manually manages:
`generation: Int` staleness counter, `lastQuery` dedup, a `debounceTask` with
`Task.sleep(150ms)`, AND a *nested* `loadingTask` with `Task.sleep(50ms)` to
delay the spinner. Two of the four async result-application sites
(`:245`-empty vs `:266`-nonempty) duplicate the same
`generation == currentGen` guard + `items/selectedIndex/isLoading/emptyReason`
write block (`:247-252` vs `:269-274`). This is correct but intricate and
duplicated; the `DispatchQueue.main.async` inside an already-`@MainActor`
`Task` (`:246`,`:267`) is a belt-and-suspenders hop. A refactor could unify
the two completion blocks and lift the debounce into one path. Severity
medium (correctness is fine; it's duplication + complexity).
Location: `CompletionViewModel.swift:225-278`.

### Smell #7 — `confirmCompletion(item:)` ignores its `item` parameter (LOW)
`InputBarView2.confirmCompletion(item:)` (`InputBarView2.swift:521`) takes an
`item` but never uses it — it re-reads `completion.confirmSelection()` which
goes off `selectedIndex`. The comment explains taps pre-set `selectedIndex`,
so the param is redundant. Minor API smell. Location: `InputBarView2.swift:521-528`.

### Smell #8 — `CompletionListView` recomputes `selectedDetail`/`displayCount`/`listHeight` in body (LOW)
`listHeight` (`CompletionListView.swift:241`) reads `selectedDetail` which
indexes `viewModel.items[selectedIndex]` and re-cleans the detail string on
every layout pass (`cleanedDetail` does a `split`+`joined`,
`CompletionListView.swift:219`). Cheap (lists ≤ 20) but it's whitespace
re-folding work in the layout path. Severity low.
Location: `CompletionListView.swift:219-246`.

### Smell #9 — `ForEach(... id: \.offset)` over enumerated items (LOW)
`CompletionListView.swift:48` keys rows by array offset, not item identity.
For a popup whose list is fully replaced per query this is fine (no stable
identity needed, no animation), and `.animation(nil, …)` is set
(`:63-64`), so it's intentional — but it's the kind of thing the
"`ForEach` ids must be stable" rule (root `CLAUDE.md` SwiftUI rules) flags.
Acceptable here; noting for completeness. Location: `CompletionListView.swift:48`.

### Smell #10 — Comments in mixed languages (LOW)
`FileCompletionStore.swift` has Chinese doc comments (`:4`,`:75`,`:144`, etc.)
while the rest of the subsystem (and the codebase convention) is English.
Cosmetic / consistency only. Location: `FileCompletionStore.swift` throughout.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

1. **Generation guard on async provider results.** Every write of
   `items`/`selectedIndex`/`isLoading`/`emptyReason` from a provider callback
   is gated on `generation == currentGen` (`CompletionViewModel.swift:247`,
   `:261`,`:269`). `dismiss()` and every `refreshQuery` bump `generation`
   (`:240`,`:342`). This is what prevents a slow fzf/temp-CLI result from a
   stale query overwriting the current popup. Any rewrite of the async path
   must keep equivalent staleness rejection.

2. **`isActive` is derived, not stored.** Popup visibility is computed from
   `activeSession` + `cursorLocation` + `wordRange` every read
   (`CompletionViewModel.swift:40-45`). The `pill` shows the popup iff
   `completion.isActive` (`InputBarView2.swift:250`). Do not convert this to
   a stored `Bool` that the view toggles — that reintroduces the show/hide
   drift the computed form avoids.

3. **`CompletionTriggerContext` is rebuilt fresh per `checkTrigger`, never
   subscribed.** (`CompletionTriggerRule.swift:17-18`,
   `InputBarView2.swift:482`.) This is the mechanism by which a folder switch
   or a late `initialize` response reaches the next keystroke with no
   resubscription. A refactor must keep config flowing in as a per-call
   value snapshot, not a stored/observed reference.

4. **`knownSlashCommands` live-list shortcut bypasses the temp-CLI fetch.**
   When `session.slashCommands` is non-empty, `InputBarChrome` passes it
   (`InputBarChrome.swift:71`) and `SlashCommandStore.complete` takes the
   synchronous path (`SlashCommandStore.swift:80`). Callers MUST collapse an
   empty live list to `nil` (documented at `CompletionTriggerRule.swift:38-42`)
   or the rule renders an empty popup instead of falling back to the cache.
   Preserve both the shortcut and the empty→nil collapse.

5. **Builtins lead and shadow same-named CLI commands.** In
   `SlashCommandTriggerRule`, builtin items prepend and CLI matches with a
   colliding name are filtered out (`CompletionTriggerRule.swift:140-144`),
   guarded by `BuiltinSlashCommandTests.test_builtins_shadowSameNamedCLICommand`.
   Builtins fire an action + clear input on confirm (replacement = empty
   range delete); CLI commands splice `"/name "` (`CompletionTriggerRule.swift:91-100`).
   These two confirm behaviors and the dedup are test-locked.

6. **`runBuiltinSlashCommand` step order is load-bearing.** Create the seeded
   draft FIRST (while the source session is still live), THEN archive (for
   `/clear`), THEN `select` (`BuiltinSlashCommandHandler.swift:22-37`). The
   inline comment spells out the teardown race it avoids. A refactor must not
   reorder these.

7. **Confirm side effect order.** `confirmSelection()` fires
   `onItemConfirmed?(item)` BEFORE `dismiss()` and BEFORE returning the
   replacement (`CompletionViewModel.swift:293-295`). The builtin dispatch
   (which may select a new session and tear down this very view) must run
   while the session is still active; the returned replacement is then
   applied by the (possibly-about-to-be-torn-down) view. Preserve this
   ordering.

8. **Pipe read-before-`waitUntilExit` in subprocess paths.** Both
   `gitLsFiles` (`FileCompletionStore.swift:259`) and `findFiles` (`:291`)
   read the pipe to EOF before `waitUntilExit()` to avoid deadlock when
   output exceeds the pipe buffer. This is an explicit comment'd invariant;
   any subprocess refactor must keep read-before-wait.

9. **Prewarm `.task(id:)` keys on the exact `CompletionPrewarmer.Key` shape.**
   `Key` is `Equatable` over `(directory, additionalDirs, pluginDirs)`
   (`CompletionPrewarmer.swift:21-25`) so SwiftUI re-fires the prewarm once
   per config combination — both on initial entry and folder switch
   (`InputBarChrome.swift:38-47`,`:78-80`). Prewarm is `directory == nil`-safe
   (early return, `CompletionPrewarmer.swift:28`). Keep the key minimal and
   stable so the prewarm doesn't thrash per render.

10. **Stores are queue-serialized; results return on main.** Both stores do
    all cache mutation on their own serial `DispatchQueue` and hop results
    back via `DispatchQueue.main.async` (`FileCompletionStore.swift:94`,
    `SlashCommandStore.swift:82`,`:89`). `warm` enqueues on the same queue so
    a subsequent `complete` naturally lands behind it
    (`FileCompletionStore.swift:63-67`, `SlashCommandStore.swift:54-61`). The
    serial-queue-for-state / main-for-callback split is the thread-safety
    contract — preserve it (the VM assumes provider callbacks arrive on main).

---

## Refactor-direction notes (for the consuming agent)

- The single biggest unidirectional-cleanliness win here is **deleting the
  dead directory-completion path (Smell #1)**. That alone removes 3 of 7
  `CompletionSession` closures, the `DirectoryCompletionItem` /
  `DirectoryCompletionProvider` types, the `onDeleteRecent` branch, and the
  "recent" pill UI — shrinking the VM/session surface to exactly what slash +
  @ need. No functional change (nothing constructs those items).
- `CompletionViewModel` is a legitimate, well-contained state machine; the
  "no ViewModel" rule does NOT really apply to it (Smell #3). If anything,
  consider renaming to something like `CompletionController` /
  `CompletionState` to stop it reading as a rule violation — but that's
  cosmetic and optional.
- Injecting the two stores (Smell #4) would align deps with the rest of the
  app and unlock isolated tests, but trades away the "one cache per process"
  simplicity. Weigh against the no-over-engineering goal.
- The data flow is already cleanly unidirectional in the inbound direction
  (config → context → rule → session → provider → items). The one true
  back-channel (confirm → text mutation, invariant #7) is intrinsic to a
  completion UI and should stay.
