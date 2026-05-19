# Handoff — sidebar history switch flicker (re-entry case)

Branch: `worktree-splendid-marinating-music`
PR: <https://github.com/wasd96040501/ccterm/pull/135>
Latest commit: `b94e42b fix(transcript): flush display before settle to mask sidebar flicker`

## Where this stands now (live-app verification by user)

After the latest fix:

- **First-time open of a history session — OK.** Click a never-yet-visited session in the sidebar (or open the app and click any session). The bake overlay covers cleanly and the transcript lands at the tail with no visible "row 0 at top" frame.
- **Switch away and switch BACK to the SAME history session — STILL BROKEN.** Click session A, then click anything else (session B, new-session tab, archive), then click A again. A's transcript briefly shows its **beginning** before scrolling to the tail. The bake overlay does not mask this gap.

The remaining bug is **re-entry only**, not cold-load. That narrows the surface area considerably.

## What changed this session — recap of commit b94e42b

1. **Redacted real-world JSONL fixtures** at [macos/cctermTests/Fixtures/real-history-session-{A,B}.jsonl](macos/cctermTests/Fixtures/) — copies of two production transcripts (`b9198f4d` "研究 tool group 组件的高性能实现方案" and `a221ad1f` "Optimize NativeTranscript2 rebuild performance for large chats") with `/Users/luoyangze` / username / email replaced by `testuser` placeholders.

2. **Integration test** at [SidebarFlickerRealHistoryIntegrationTests](macos/cctermTests/SidebarFlickerRealHistoryIntegrationTests.swift). Loads each fixture through the real `SessionRuntime.loadHistory(overrideURL:)` pipeline, mounts a SwiftUI harness that mirrors `RootView2`'s detail-pane modifier chain (DetailBakeProbe background + bakedImage overlay + onChange-driven bake-clear), then drives `state.switchTo("B")` exactly the way the production binding setter does. The test hooks the bake-clear onChange callback and records the table's bounds.origin + visible rows at the **exact moment** `bakedImage = nil` is set. Primary assertion: `docHeight - scrollY == clipHeight - bottomInset` (table at tail).

3. **Production fix** at [Transcript2Coordinator.swift:145-160, :1041-1093](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:145):

   ```swift
   // markAnchorSettled (cold-load Phase 1 path) and
   // consumeDesiredAnchor (re-attach deferred path) both gained:
   if let table = tableView, let window = table.window {
       window.viewsNeedDisplay = true
       window.displayIfNeeded()
   }
   setAnchorSettled(true)
   ```

   Reasoning: cell layer policy is `wantsLayer + .onSetNeedsDisplay`. After `scrollRowToBottom` mutates `clipView.bounds.origin`, the cached layer composite still holds pre-scroll pixels until AppKit's next display pass. The `setAnchorSettled(true)` flip fires the bake-clear observer synchronously and a 180 ms opacity fade starts; without the display flush, the fade reveals row-0 pixels through the fading bake.

## Why the fix landed cold-load but not re-entry

This is the **objective fact** as of writing:

- The fix in `markAnchorSettled` is on the path **Phase A's `controller.setHistory` → Phase 1 scroll → `markAnchorSettled`**. That path is taken on FIRST visit (because `loadHistory()` runs Phase A only on `.notLoaded`).
- The fix in `consumeDesiredAnchor` is on the path **`tableFrameDidChange` 0→positive width → `scheduleDesiredAnchorConsumption` → `consumeDesiredAnchor`**. That path is taken when a fresh `NSTableView` attaches to an already-populated coordinator (i.e. re-entry).
- The user-confirmed live behaviour says cold-load works after the fix but re-entry doesn't. So **`displayIfNeeded()` inside `consumeDesiredAnchor` is NOT sufficient to flush the right pixels on re-entry**, even though the geometric state at bake-clear is correct (the test asserts and passes).

The integration test in `SidebarFlickerRealHistoryIntegrationTests` does NOT specifically isolate the re-entry path. Its scenario is "mount A, switch to B" — i.e. a single forward swap, equivalent to first-open into B. The test happens to pass under that scenario, but the user-visible bug lives on the re-entry path that the test doesn't cover.

## Hypotheses for the next session

Ranked by what the next session should rule in / out first.

1. **`weak var tableView` auto-nil on dealloc does not fire `didSet`.**
   When the user switches AWAY from A, A's `NSTableView` is dismounted by SwiftUI and eventually deallocated. The coordinator's `weak var tableView` becomes nil **silently** — Swift's `willSet` / `didSet` do not fire for weak references that go to nil via dealloc, only for explicit assignment. So `setAnchorSettled(false)` is NOT called on the away-leg. `isAnchorSettled` stays at `true` from the previous visit.
   
   On re-entry, when the new `NSTableView` is assigned, didSet DOES fire (`oldValue = nil, newValue = newTable`, so the `oldValue !== tableView` guard passes). It calls `setAnchorSettled(false)`. Body re-evals; onChange sees `true → false → ... → true` and clears the bake.
   
   BUT — there may be a body re-eval window between the sid flip and the new `NSTableView`'s `didSet` where:
   - `currentSessionController?.isAnchorSettled` evaluates to `true` (stale from previous visit)
   - The previous value tracked by `.onChange` was `B.isAnchorSettled = true` (B was settled when the user clicked away)
   - **No transition is detected** → onChange doesn't fire — **but** the `initial: true` first-evaluation case for the NEW `.onChange` instance (if SwiftUI tears the modifier down with the rest of the tree) may behave differently.
   - Or, more likely, **after the new tableView's didSet flips `isAnchorSettled` to false**, the eventual `consumeDesiredAnchor` flip back to true triggers onChange with the bake-clear logic — but the bake might have already been compromised by an earlier evaluation cycle.

2. **`displayIfNeeded()` may not actually re-render cells with `.onSetNeedsDisplay` policy when they haven't had `setNeedsDisplay = true` called on them.**
   After `scrollRowToBottom` shifts `bounds.origin`, AppKit needs to re-tile the visible range — but it does so lazily on the next display tick. `displayIfNeeded()` synchronously runs `display` on views that have `needsDisplay = true`; if the newly-visible rows' cells haven't been instantiated via `viewFor` yet, there's nothing to display. The fix may be a no-op in this exact path, leaving the layer cache holding the OLD (row-0) bitmap.
   
   Check: `tableView.tile()` BEFORE `displayIfNeeded()`. Or call `tableView.setNeedsDisplay(true)` + `displayIfNeeded()`.

3. **The bake CAPTURE may be stale or wrong in the re-entry case.**
   `DetailBakeSnapshotter.snapshot()` walks up from `probeView` to the largest matching-width ancestor. The probe is mounted via `.background(DetailBakeProbe(...))` on `detailContent`. If SwiftUI tears down and re-mounts the probe across some boundary (e.g. an unexpected `.id` propagation), `snapshotter.probeView` could go nil temporarily, or the captured pixels could reflect a transient state.
   
   On switch from B → A, the snapshot is supposed to capture B's pixels. Inspect with a debug print of the snapshot's average colour / write to disk to verify.

4. **Possible race between `consumeDesiredAnchor`'s async hop and SwiftUI's onChange firing.**
   `scheduleDesiredAnchorConsumption` uses `DispatchQueue.main.async`. The hop fires "soon". If between the new tableView attach and the hop, SwiftUI re-evaluates and onChange fires with stale state, the bake could clear before the scroll lands.

## What the next session should do

1. **Write a re-entry-specific test.** Extend [SidebarFlickerRealHistoryIntegrationTests](macos/cctermTests/SidebarFlickerRealHistoryIntegrationTests.swift) (or add a sibling) that exercises the EXACT user reproduction:
   - Mount harness with sid="A" (real fixture loaded).
   - `await settle` — A is on-screen and settled.
   - `state.switchTo("B")` — switch to B.
   - `await settle` — B settles, bake clears.
   - `state.switchTo("A")` — RE-ENTRY: switch back to A.
   - During the next 30 ticks (33 ms each), assert at every tick that **either** the bake overlay is non-nil **or** the NSTableView's topmost visible row is NOT `A.controller.blockIds.first`. The geometric bottom-pinned check at the bake-clear moment must also still hold for the re-entry leg.

2. **Verify hypothesis 1 (weak ref nil-out does not flip `setAnchorSettled(false)`).** Add an `appLog` (or an `@Observable` counter) inside `coordinator.tableView.didSet` and a separate one inside `setAnchorSettled`. Reproduce by clicking A → B → A in the live app and dumping the log. If `setAnchorSettled(false)` fires only when the NEW table attaches (not when the old one dies), hypothesis is confirmed.

3. **Fix candidates to evaluate (in this order):**
   1. In `coordinator.tableView.didSet`, ALSO call `setAnchorSettled(false)` when the new value is nil (e.g. extra branch handling explicit-nil case, paired with a `dismantleNSView`-driven explicit nil from `NativeTranscript2View`).
   2. In `NativeTranscript2View.dismantleNSView`, explicitly clear `controller.coordinator.tableView` so the weak ref auto-nil isn't relied on.
   3. Inside `consumeDesiredAnchor`, before `displayIfNeeded`, call `tableView.tile()` to force re-tiling so newly-visible rows are instantiated before the display pass.
   4. Replace `displayIfNeeded()` with `tableView.window?.display()` (unconditional display) or with a `CATransaction.flush()` after the scroll.
   5. As a last resort, defer `setAnchorSettled(true)` by one runloop tick (`DispatchQueue.main.async`) so any pending display work completes first.

4. **Visual ground-truth.** When iterating, use Quartz Debug (`/Applications/Xcode.app/Contents/Applications/Quartz Debug.app`) or set `Defaults: defaults write com.apple.CoreGraphics CGDebug -bool YES` to step through display passes frame-by-frame. The bug is sub-frame, so a static debugger run won't catch it without slowdown.

## Code references (load-bearing locations)

| Concern | File:line |
|---|---|
| `RootView2.sidebarSelectionBinding` — snapshot + flip selectedSessionId | [macos/ccterm/App/RootView2.swift:118-137](macos/ccterm/App/RootView2.swift:118) |
| `.overlay { if let img = bakedImage { ... } }` | [macos/ccterm/App/RootView2.swift:159-173](macos/ccterm/App/RootView2.swift:159) |
| `.onChange(of: currentSessionController?.isAnchorSettled ?? true, initial: true)` clearing `bakedImage` | [macos/ccterm/App/RootView2.swift:180-189](macos/ccterm/App/RootView2.swift:180) |
| `currentSessionController` getter | [macos/ccterm/App/RootView2.swift:99-104](macos/ccterm/App/RootView2.swift:99) |
| `DetailBakeSnapshotter.snapshot()` (registers `probeView`, calls `cacheDisplay`) | [macos/ccterm/App/DetailBakeProbe.swift](macos/ccterm/App/DetailBakeProbe.swift) |
| `setAnchorSettled` flip site | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:116](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:116) |
| `markAnchorSettled` — Phase 1 cold-load settle (display-flush added in `b94e42b`) | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:145-160](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:145) |
| `consumeDesiredAnchor` — deferred re-attach settle (display-flush added in `b94e42b`) | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:1041-1093](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:1041) |
| `tableView.didSet` — `setAnchorSettled(false)`, `lastLayoutWidth = -1`, `reloadData` | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67-90](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67) |
| Integration test (forward-swap coverage; **does not yet cover re-entry**) | [macos/cctermTests/SidebarFlickerRealHistoryIntegrationTests.swift](macos/cctermTests/SidebarFlickerRealHistoryIntegrationTests.swift) |
| Real-world fixtures | [macos/cctermTests/Fixtures/real-history-session-{A,B}.jsonl](macos/cctermTests/Fixtures/) |

## How to run

```bash
make build      # Debug build of ccterm.app
open /Users/luoyangze/Library/Developer/Xcode/DerivedData/ccterm-hcbjalhtrfuaqpcnfqbsuqipvsre/Build/Products/Debug/ccterm.app
make test-unit  # all 251 cases (parallel)
make test-unit FILTER=SidebarFlickerRealHistoryIntegrationTests
make test-unit FILTER=HistoryPhaseBAnchorDriftTests
```

PNG output (snapshot tests): `/tmp/ccterm-screenshots/` (override via `CCTERM_SCREENSHOT_DIR`).
