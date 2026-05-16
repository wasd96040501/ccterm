# Session runtime

`SessionHandle2` (`@Observable @MainActor`) is the runtime handle for one chat session. Source lives in `SessionHandle2/` and is sharded across several files.

| File | Responsibility |
|---|---|
| `SessionHandle2.swift` | Class definition, `@Observable` properties, init |
| `SessionHandle2+Start.swift` | `activate` / `stop` / `send` / bootstrap |
| `SessionHandle2+Messaging.swift` | `interrupt` and other commands |
| `SessionHandle2+Configuration.swift` | Local config: `setCwd`, `setWorktree`, `setModel`, ... |
| `SessionHandle2+History.swift` | `loadHistory`, JSONL replay |
| `SessionHandle2+Receive.swift` | Incoming-message path from the CLI |
| `SessionHandle2+Types.swift` | `PendingPermission`, `SlashCommand`, ... |
| `MessageEntry.swift` | Render-ready entries (`SingleEntry` / `GroupEntry`) |
| `MessagesChange.swift` | Timeline change events that the bridge consumes |
| `SessionManager2.swift` | Registry of `SessionHandle2`s, lazily created and cached by `sessionId` |

## Talking to the renderer

The notification channel depends on whether the renderer is AppKit or SwiftUI. Pick one per piece of state; never mix.

| Renderer | Channel | Notes |
|---|---|---|
| **AppKit-native** (e.g. `NativeTranscript2`, anything driving an `NSTableView`) | Synchronous closure callback → direct imperative controller call | The handle mutates `messages` and fires the callback (`onMessagesChange`, ...) inside the same call stack. The bridge translates the event into `controller.apply(.insert / .remove / .update)` immediately. |
| **SwiftUI** | `@Observable` field (for continuous state) or `AsyncStream` (for discrete side effects) | The view tracks `handle.status` / `handle.isRunning` directly; one-shot effects go through `eventStream()`. |

The AppKit path deliberately skips `AsyncStream` and `@Observable`:

- `AsyncStream` adds at least one main-actor hop — one frame of latency over a synchronous callback.
- `@Observable`-driven `updateNSView` is a pull model: SwiftUI has to recompute the diff. Going imperative lets the bridge hand the controller exactly the increment it needs.

## Rules

- **AppKit channel** — declare a `@ObservationIgnored var onXxxChange: ((XxxChange) -> Void)?` on the handle. The bridge wires it up in `.task` / `init`; teardown is automatic via `weak`.
- **Adding a new notification on the AppKit path** — add the closure on the handle, fire it synchronously at the mutation site, add a dispatch arm to the bridge, then call `controller.apply(...)`.
- **Never emit a state change on both channels.** Pick one. `SessionHandle2.messages` is delivered only through `onMessagesChange`; there is no shadow snapshot.
- **Views never cache handle properties as their own state.** Read the `@Observable` field directly or expose a computed property.
- **Local actions** (`send` / `interrupt` / `setPermissionMode`) either issue a stdin request or perform a local state transition. They never write to observables behind the handle's back.
- **New change variants** — add a `case` to `MessagesChange`, fire `onMessagesChange?(...)` at the mutation site in `SessionHandle2`, add the matching arm in `Transcript2EntryBridge.apply`.

## Adding new runtime state

1. Add the `@Observable` field to `SessionHandle2`.
2. Read it directly in the view that cares (no copies, no shadow state).
3. If AppKit needs to react, add a closure field and fire it synchronously at the mutation point.

## Test infrastructure

Unit tests inject `InMemorySessionRepository` (DEBUG only) when constructing a `SessionManager2` so they don't touch the on-disk CoreData store. Do not add `forceXxxForTest()` methods on `SessionHandle2` or `SessionManager2` — drive the handle through its public surface (send / interrupt / loadHistory / receive) and assert on the observable result instead.
