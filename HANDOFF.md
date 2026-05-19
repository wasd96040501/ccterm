# Handoff — sidebar history switch flicker

Branch: `worktree-splendid-marinating-music`
PR: <https://github.com/wasd96040501/ccterm/pull/135>
Base commit on entry: `6a9db75 docs: handoff notes — sidebar flicker investigation, open work`

## Commits on this branch (oldest → newest)

| SHA | Subject |
|---|---|
| `ea670c2` | feat(sidebar): bake outgoing detail into overlay during history session switch |
| `4bd5d8b` | test(transcript): repro .id swap flicker + frame-by-frame bake capture |
| `493f621` | test(transcript): expand JSONL fixture to all child kinds + add Phase B capture |
| `6a9db75` | docs: handoff notes (now superseded by this file) |

## Production changes made this session (uncommitted)

| File | Change |
|---|---|
| [macos/ccterm/Content/Chat/NativeTranscript2/AppKit/Transcript2ScrollView.swift](macos/ccterm/Content/Chat/NativeTranscript2/AppKit/Transcript2ScrollView.swift) | `Transcript2ClipView.constrainBoundsRect` overridden. `docH` derived from `tableView.rect(ofRow: numberOfRows-1).maxY` (NSScrollView's `contentInsets` extends `documentView.frame` to fill the inset-adjusted area, so `frame.height` masks the short-content state). When `maxY < minY` (real row extent < visible content area), `bounds.origin.y` is pinned to `maxY` so the table sticks to the visible content area's bottom. |
| [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift) | `scrollRowToBottom` no longer clamps `target` at `-contentInsets.top`. The clamp made `NSClipView.scroll(to:)` short-circuit (proposed == current bounds.origin.y) before `constrainBoundsRect` could land the negative target. |

## Test changes made this session (uncommitted)

| File | Purpose |
|---|---|
| [macos/cctermTests/Helpers/RowAnchorTracker.swift](macos/cctermTests/Helpers/RowAnchorTracker.swift) | Per-tick probe of the live `NSTableView`: top/bottom visible blockId, document-space minY/maxY, scrollY, viewport-relative y, fillRatio, pairwise drift. |
| [macos/cctermTests/HistoryPhaseBAnchorDriftTests.swift](macos/cctermTests/HistoryPhaseBAnchorDriftTests.swift) | Two scenarios driving `Transcript2Controller` + `NativeTranscript2View` end-to-end (not through `SessionRuntime.loadHistory`): `testFilledTailAnchorStableAcrossPhaseBPrepend` (tail=30 + prefix=30) and `testShortTailAnchorStableAcrossPhaseBPrepend` (tail=1 + prefix=80). Asserts (a) the bottommost visible block is `tail.last`; (b) its `viewportMaxY` equals `clipH − bottomInset` (i.e. 420 at the 600×600 test fixture); (c) `viewportShift` between Phase A and Phase B ≤ 2pt. |

## Test status

- `make test-unit` → 250 cases pass.
- `HistoryPhaseBAnchorDriftTests/testShortTailAnchorStableAcrossPhaseBPrepend` is the regression net for the two production changes above: stashing **either** of the two changes makes that test fail with `bot.vpY ≈ 72.5` (expected 420).
- Snapshot tests (`HistorySwitchFlickerSnapshotTests`, `HistorySwitchBakeOverlayTests`, `HistoryPhaseBFlickerSnapshotTests`, `BulkHistoryFixtureSnapshotTests`) all pass; PNGs unchanged from the base commit.

## What the new tests measure

`HistoryPhaseBAnchorDriftTests` drives the **controller** directly:

```swift
controller.setHistory(tail, anchor: .bottom)         // Phase A
controller.coordinator.applyInBackground(
    [.insert(after: nil, prefix)],
    scroll: .saveVisible(.visualTop))                // Phase B (same call shape as bridge.applyPrepend)
```

It does **not** drive the production `.id(sid)` SwiftUI swap (the case `HistorySwitchFlickerSnapshotTests` covers) nor `SessionRuntime.loadHistory` (the case `HistoryPhaseBFlickerSnapshotTests` covers). It exercises only the Controller / Coordinator / ClipView geometry pipeline.

## What the user reports is still broken

> "切换 sidebar，一瞬间看到了 transcript 开头的内容，然后才切到了最末尾。"

After launching the post-fix Debug build (`make build` + `open …/ccterm.app`), switching the sidebar to a history session produces a visible frame showing the **beginning** of that session's transcript before the view scrolls to the tail. The bake overlay introduced in `ea670c2` is intended to mask exactly this window, but it does not in the user's interactive run.

The PNG sequences captured offscreen by `HistorySwitchBakeOverlayTests` show the bake covering ticks 1–N with the outgoing session's content until `controllerB.isAnchorSettled = true`. Whether those captured frames match what the user perceives in the live app has not been independently verified.

## Code references for the next investigation

| Concern | File:line |
|---|---|
| `RootView2.sidebarSelectionBinding` — snapshot + flip selectedSessionId | [macos/ccterm/App/RootView2.swift:118-137](macos/ccterm/App/RootView2.swift:118) |
| `.overlay { if let img = bakedImage { ... } }` | [macos/ccterm/App/RootView2.swift:159-173](macos/ccterm/App/RootView2.swift:159) |
| `.onChange(of: currentSessionController?.isAnchorSettled ?? true, initial: true)` clearing `bakedImage` | [macos/ccterm/App/RootView2.swift:180-189](macos/ccterm/App/RootView2.swift:180) |
| `DetailBakeSnapshotter.snapshot()` (registers `probeView`, calls `cacheDisplay`) | [macos/ccterm/App/DetailBakeProbe.swift](macos/ccterm/App/DetailBakeProbe.swift) |
| `currentSessionController` getter | [macos/ccterm/App/RootView2.swift:99-104](macos/ccterm/App/RootView2.swift:99) |
| `setAnchorSettled` flip site | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:116](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:116) |
| `consumeDesiredAnchor` (deferred scroll after first 0→positive frame) | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:1038](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:1038) |
| `tableView.didSet` — `setAnchorSettled(false)`, `lastLayoutWidth = -1`, `reloadData` | [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67-90](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67) |

## Open work

1. Determine why the bake overlay is not visible in the interactive Debug build during the sidebar switch the user described. The offscreen-rendered PNGs from `HistorySwitchBakeOverlayTests` show the bake masking ticks 1–N; the live app evidently does not.
2. If the bake is rendered but the underlying tableView paints through it for a frame, identify the AppKit / SwiftUI compositing path that allows that and remove the gap.
3. The current automated coverage does not include the live `.id(sid)` swap composed with the bake overlay binding in `RootView2`. `HistorySwitchBakeOverlayTests` exercises the bake mechanism in isolation (synthetic harness with two pre-loaded controllers); it does not mount `RootView2` or assert on the on-screen pixel sequence.

## How to run

```bash
make build      # Debug build of ccterm.app
make test-unit  # all 250 cases (parallel)
make test-unit FILTER=HistoryPhaseBAnchorDriftTests
make test-unit FILTER=HistorySwitchBakeOverlayTests
```

PNG output (snapshot tests): `/tmp/ccterm-screenshots/` (override via `CCTERM_SCREENSHOT_DIR`).
