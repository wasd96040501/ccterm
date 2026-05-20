# Handoff — sidebar history switch flicker (RESOLVED, pending live verification)

Branch: `worktree-splendid-marinating-music`
PR: <https://github.com/wasd96040501/ccterm/pull/135>
Latest commits:
- `952a5d0` docs: handoff resolution
- `e659f4b` fix(transcript): reset isAnchorSettled on dismount so re-entry == first entry
- `7346624` test(transcript): repro re-entry stale isAnchorSettled bug

## Status

| Item | State |
|---|---|
| Root-cause identified | ✅ |
| Failing unit test demonstrating bug | ✅ committed at `7346624` |
| Architectural fix landed | ✅ committed at `e659f4b` |
| Unit test passes after fix | ✅ `Transcript2AnchorSettledTests.testDismountResetsIsAnchorSettled` 0.002s |
| `make fmt-check` clean | ✅ |
| `make build` clean | ✅ |
| Live-app re-entry visual verification | ⏳ pending user click-through |
| CI green on PR | ⏳ pending push-to-CI cycle |

## Resolution summary

The re-entry-into-history-session flicker is fixed by making the
dismount path SYMMETRIC with the attach path on
`Transcript2Coordinator`. The bridge's `dismantleNSView` now
explicitly nils the coordinator's `tableView` (with an identity
guard), which fires the same `didSet` that the attach path relies on
and resets `isAnchorSettled` to `false`. Re-entry now starts from the
same `isAnchorSettled = false` state as first-entry — the two paths
are identical.

No hidden logic. No special-case "if re-entry then …" branches. The
flag's documented contract is honored end-to-end: "first-screen
anchor has landed for the **currently-attached** NSTableView."

## The root cause

`Transcript2Coordinator.tableView` is declared `weak`. Swift's
`willSet`/`didSet` observers do **not** fire when a `weak`
reference auto-nils via the referent's dealloc — only when the
reference is **explicitly** assigned. The previous `dismantleNSView`
implementation only removed the notification observer; it never
assigned `coordinator.tableView = nil`. So the matched
`tableView.didSet` reset (`setAnchorSettled(false)`,
`lastLayoutWidth = -1`) only ran on attach, never on detach.

`isAnchorSettled` therefore carried the previous visit's `true`
across the un-mounted window of a sidebar swap. On re-entry the
SwiftUI `.onChange(of:
currentController?.isAnchorSettled, initial: true)` observer saw
`true → true` (no transition), so the bake-clear branch raced the
new NSTableView's attach + tile + `consumeDesiredAnchor` sequence,
opening a sub-frame window where the user-reported "瞬间看到
transcript 开头的内容" symptom appeared.

## Session progress log (oldest → newest)

1. **Read the existing handoff at `7bc6034`.** Four hypotheses
   listed, ranked. Hypothesis 1 was "`weak var tableView` auto-nil
   on dealloc does not fire `didSet`". Picked it as the leading
   candidate because it most cleanly explains "first-entry works,
   re-entry doesn't" — only re-entry hits a code path where a flag
   set on a previous mount could carry into the next mount.

2. **Designed an integration test for the user's symptom.** Added
   `testReEntryFromAReproducesSidebarFlicker` to
   `SidebarFlickerRealHistoryIntegrationTests` that drives
   A → B → A through the real `SessionRuntime.loadHistory` pipeline
   plus a SwiftUI harness mirroring `RootView2`'s detail-pane
   modifier chain (bake probe + bake overlay + `.onChange`-driven
   bake-clear). First run **passed** — the geometric check at
   `bake-clear` moment showed the table at the tail.

3. **Realized the integration test wasn't catching the contract
   violation directly.** The `PRE-REENTRY` log line showed
   `A.settled=true A.tableView=false` — the stale-flag bug WAS
   active — yet the bake-clear geometry was still correct because
   SwiftUI's `makeNSView` lifecycle happened to run before the
   `.onChange` evaluation in this harness. The end-to-end test
   passed despite the bug being live; the contract assertion
   needed a more focused vehicle.

4. **Tried to inline `XCTAssertFalse(preReentryASettled)` directly
   in the integration test.** Caused the test process to hang for
   30+ minutes — assertion-failure capture path interacts badly
   with the offscreen hosted-window environment under XCTest
   parallel workers. Backed out the inline assertion.

5. **Switched to a focused unit test:
   `testDismountResetsIsAnchorSettled`** in
   `Transcript2AnchorSettledTests`. Attaches a fresh `NSTableView`
   to a `Transcript2Coordinator`, marks the anchor settled (mimics
   post-Phase-1 state), runs production
   `Transcript2NSViewBridge.dismantleNSView`, asserts
   (a) `coordinator.tableView` is nil afterwards
   (b) `controller.isAnchorSettled` is false afterwards.
   Required widening `private struct Transcript2NSViewBridge` →
   `struct Transcript2NSViewBridge` (visibility-only; no behavior
   change). Test **fails** on the pre-fix code at the (a) check —
   demonstrates the bug cleanly in ~0.07s.

6. **Committed the failing test as `7346624` and pushed.** The
   user's instruction "复现之后 commit push" — preserve the test
   work before risking breakage during the fix.

7. **Applied the architectural fix as `e659f4b`.** In
   `Transcript2NSViewBridge.dismantleNSView`, added:
   ```swift
   if coordinator.tableView === (nsView.documentView as? NSTableView) {
       coordinator.tableView = nil
   }
   ```
   The identity guard handles the rare case where a sibling
   `makeNSView` of the same coordinator already reassigned
   (preserves the new bind). Pushed.

8. **Verified the unit test passes on the fix.** 0.002s, clean.

9. **Updated the handoff doc as `952a5d0`.**

## What I did NOT do (and why)

- **Did not remove the b94e42b display-flush hardening.** Those
  flushes (`window.viewsNeedDisplay = true; window.displayIfNeeded()`
  in `markAnchorSettled` and `consumeDesiredAnchor`) address a
  different concern: ensuring the cell layer composite is committed
  at the settle moment, independent of how `isAnchorSettled` got
  flipped. Removing them would re-open the cold-load flicker the
  user already reported as fixed.

- **Did not touch the Phase A/B `loadHistory` architecture.** The
  fix is in the SwiftUI lifecycle bridge, not in the runtime's
  history loader. Re-entry continues to be O(1) on the renderer
  side (no re-read, no re-parse) — same contract as documented in
  [Services/Session/CLAUDE.md](macos/ccterm/Services/Session/CLAUDE.md).

- **Did not add a special-case "if re-entry" branch.** The flag
  contract is now uniformly enforced: when no `NSTableView` is
  attached, `isAnchorSettled == false`. Re-entry and first-entry
  take the exact same code path.

## Live-app verification (the one open item)

The unit test proves the architectural contract is now satisfied.
The user-visible symptom should be gone, but final confirmation
requires running the freshly-built Debug app and clicking through
the A → B → A scenario.

```bash
make build
open /Users/luoyangze/Library/Developer/Xcode/DerivedData/ccterm-hcbjalhtrfuaqpcnfqbsuqipvsre/Build/Products/Debug/ccterm.app
```

Click any history session in the sidebar, click away to another
sidebar row (New Session / a different session / Archive), then
click the **same** history session again. The bake overlay should
mask the gap; no "transcript 开头的内容" should appear in any
frame.

If you still see the flicker, the next-most-likely candidates from
the prior handoff to investigate are:
- **Bake snapshot integrity on re-entry.** `DetailBakeSnapshotter`
  walks up from `probeView` looking for matching width. Inspect
  whether the snapshot taken at the binding-setter call moment
  actually captured useful pixels (write to disk, eyeball).
- **`displayIfNeeded` not flushing newly-tiled cells.** The
  b94e42b flush operates on the window; if NSTableView's tile pass
  hasn't yet instantiated the newly-visible rows after
  `scrollRowToBottom`, there's nothing to draw. Try
  `tableView.tile()` + `setNeedsDisplay(true)` before `displayIfNeeded`.

## Architectural notes

- The integration test
  `SidebarFlickerRealHistoryIntegrationTests.testReEntryFromAReproducesSidebarFlicker`
  is environment-flaky in some local sandboxes (offscreen window
  key-status interactions when multiple ccterm.app instances are
  alive concurrently). The unit-test
  `Transcript2AnchorSettledTests.testDismountResetsIsAnchorSettled`
  is the load-bearing regression guard.

- The visibility widening `private` → internal on
  `Transcript2NSViewBridge` is the only production-code touch
  besides the dismount fix itself. The struct still has the same
  members and methods — the test imports `@testable import ccterm`
  to reach it via the `testable` module map; the modifier change
  just makes it accessible.

## Code references

| Concern | File:line |
|---|---|
| Fix landing | [Transcript2NSViewBridge.dismantleNSView](macos/ccterm/Content/Chat/NativeTranscript2/NativeTranscript2View.swift:164) |
| Coordinator attach-side reset path | [Transcript2Coordinator.tableView.didSet](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67) |
| RootView2 bake-clear watcher | [RootView2.swift:180](macos/ccterm/App/RootView2.swift:180) |
| Unit-test contract guard | [Transcript2AnchorSettledTests.testDismountResetsIsAnchorSettled](macos/cctermTests/Transcript2AnchorSettledTests.swift:138) |
| Integration test (env-flaky, kept as coverage) | [SidebarFlickerRealHistoryIntegrationTests.testReEntryFromAReproducesSidebarFlicker](macos/cctermTests/SidebarFlickerRealHistoryIntegrationTests.swift:454) |
