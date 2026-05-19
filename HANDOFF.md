# Handoff — sidebar history switch flicker

Branch: `worktree-splendid-marinating-music`
PR: <https://github.com/wasd96040501/ccterm/pull/135>

## Commits

| SHA | Subject |
|---|---|
| `ea670c2` | feat(sidebar): bake outgoing detail into overlay during history session switch |
| `4bd5d8b` | test(transcript): repro .id swap flicker + frame-by-frame bake capture |
| `493f621` | test(transcript): expand JSONL fixture to all child kinds + add Phase B capture |

## Files added / changed

Production:
- `macos/ccterm/App/DetailBakeProbe.swift` — `DetailBakeSnapshotter` + `DetailBakeProbe` NSViewRepresentable. Walks up to largest same-width ancestor, `cacheDisplay(in:to:)`.
- `macos/ccterm/App/RootView2.swift` — wraps `SidebarView2(selection:)` with a binding setter that snapshots + pre-creates target session before flipping `selectedSessionId`. `.overlay` reads `bakedImage`. `.onChange` clears on `currentSessionController?.isAnchorSettled` → true.

Tests:
- `macos/cctermTests/Helpers/Message2Fixtures.swift` — added `assistantToolUseJSONL`, `userTypedToolResultJSONL`, markdown statics (`assistantHeadingMarkdown` / `assistantCodeBlockMarkdown` / `assistantListMarkdown` / `assistantTableMarkdown` / `assistantBlockquoteMarkdown`). Rewrote `bulkAssortedJSONL` to rotate through paragraph / markdown variant / tool family (Read, Edit, Bash, Grep, Glob, WebFetch, WebSearch, Agent, AskUserQuestion).
- `macos/cctermTests/BulkHistoryFixtureSnapshotTests.swift` — 50 lines, `tailTarget=30`. Asserts `historyLoadState == .loaded`, `isAnchorSettled == true`, last row visible. Writes PNG.
- `macos/cctermTests/DetailBakeSnapshotterTests.swift` — probe + snapshotter against a coloured fixture. Asserts bitmap non-uniform, captured width matches detail-fixture frame.
- `macos/cctermTests/HistorySwitchFlickerSnapshotTests.swift` — two-controller `.id(sid)` swap harness with NO bake. 20ms × 20 ticks of PNGs after the swap.
- `macos/cctermTests/HistorySwitchBakeOverlayTests.swift` — same harness with `DetailBakeProbe` + overlay + bake state machine wired in.
- `macos/cctermTests/HistoryPhaseBFlickerSnapshotTests.swift` — real `SessionRuntime.loadHistory(overrideURL:)` against the bulk fixture (120 lines, `tailTarget=40`). 100 ticks × 20ms = 2s window. PNGs annotated with `historyLoadState` + `blockCount` + `isAnchorSettled`.

## How to run

```bash
make test-unit FILTER=BulkHistoryFixtureSnapshotTests
make test-unit FILTER=DetailBakeSnapshotterTests
make test-unit FILTER=HistorySwitchFlickerSnapshotTests
make test-unit FILTER=HistorySwitchBakeOverlayTests
make test-unit FILTER=HistoryPhaseBFlickerSnapshotTests
```

PNG output: `/tmp/ccterm-screenshots/` (override via `CCTERM_SCREENSHOT_DIR`).

## Observations from the captured PNGs

### `HistorySwitchFlickerSnapshotTests` (.id swap, no bake)
- tick 00 (A settled): `AAA line 45-59` anchored at viewport bottom
- tick 01-06 (settled=N): `BBB line 0-20` at viewport top
- tick 07 (settled=Y): `BBB line 45-59` anchored at viewport bottom

### `HistorySwitchBakeOverlayTests` (.id swap, bake wired)
- tick 00 (A settled): `AAA line 45-59` at bottom
- tick 01-03 (bake=Y, settled=N): `AAA line 45-59` (bake overlay)
- tick 04+ (bake=N, settled=Y): `BBB line 45-59` at bottom

### `HistoryPhaseBFlickerSnapshotTests` (real loadHistory, 120 lines / tailTarget=40)
- tick 001: `loadingTail`, blocks=0, settled=N — empty
- tick 002: `tailLoaded`, blocks=11, settled=Y — single block (`Turn 55 reply`) anchored at viewport bottom, large empty band above
- tick 003: `loaded`, blocks=37, settled=Y — visually identical to tick 002
- tick 004: `loaded`, blocks=110, settled=Y — `Turn 52-55` packed at the bottom, content filled into the previously-empty band
- tick 005-100: stable at the tick-004 state

`isAnchorSettled` stays `true` from tick 002 through tick 100. The visible content between tick 002 and tick 004 is non-identical pixel-wise but `Turn 55 reply` occupies the same viewport bottom region in both frames.

## Code references for the next investigation

| Concern | File:line |
|---|---|
| `Transcript2Controller.setHistory` (Phase 1 + Phase 2 entry) | `macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Controller.swift:341` |
| `sliceForViewport` (Phase 1 batch sizing) | `…/Transcript2Controller.swift:492` |
| `markAnchorSettled()` call site (Phase 1 sync settle) | `…/Transcript2Controller.swift:427` |
| `applyInBackground` (Phase B prepend, off-main precompute + main hop) | `…/Transcript2Coordinator.swift:366` |
| `withScrollAdjustment` dispatch | `…/Transcript2Coordinator.swift:544` |
| `captureAnchor` (reads `tableView.rows(in: visibleRect)`) | `…/Transcript2Coordinator.swift:583` |
| `applyAnchor` (finds `blockId` post-prepend, scrolls by `delta`) | `…/Transcript2Coordinator.swift:610` |
| `setAnchorSettled` (flip site for `isAnchorSettled`) | `…/Transcript2Coordinator.swift:116` |
| Bridge `.prepended` → `applyInBackground(scroll: .saveVisible(.visualTop))` | `macos/ccterm/Content/Chat/NativeTranscript2Bridge/Transcript2EntryBridge.swift:63, :280` |
| `SessionRuntime.loadHistory` Phase A/B orchestrator | `macos/ccterm/Services/Session/Session/SessionRuntime+History.swift:43` |
| `tailTarget` default `80` | `…/SessionRuntime+History.swift:43` |

`captureAnchor` returns `nil` when:
- `tableView.enclosingScrollView == nil`
- `tableView.rows(in: visibleRect).location == NSNotFound`
- `tableView.rows(in: visibleRect).length == 0`
- `blocks.indices.contains(anchorRow) == false`

`applyAnchor` is a no-op when:
- `tableView.enclosingScrollView == nil`
- `blocks.firstIndex(where: { $0.id == anchor.blockId }) == nil`
- `abs(delta) <= 0.5`

The fallback `apply(changes, scroll: .none)` paths inside `applyInBackground` fire when:
- `tableView == nil` (`Transcript2Coordinator.swift:371`)
- `layoutWidth <= 0` (`Transcript2Coordinator.swift:386`)

## Open work

1. **Quantify anchor stability** — replace eyeballing PNGs with a `RowAnchorTracker` helper that records per tick:
   - `tableView.rect(ofRow: lastVisibleRow)` in `documentVisibleRect` coordinates → `(blockId, maxY)`
   - Whether the *same* `blockId`'s `maxY` shifts between consecutive ticks (anchor drift)
   - `tableView.rows(in: documentVisibleRect)`'s total accumulated row height vs `viewportHeight` (Phase A fill ratio)

2. **Phase B `saveVisible` verification** — add diagnostic logs on the Phase B main hop in `applyInBackground` so the next test run reports, per call:
   - whether `captureAnchor` returned non-nil
   - the captured `blockId` + `oldRefY`
   - whether `applyAnchor` found the row after prepend
   - the computed `delta`
   - whether the early-out `apply(scroll: .none)` fallback fired

   Targets the three nil/fallback cases listed above.

3. **Phase A viewport fill** — `sliceForViewport` slices the *available* `[Block]`. Phase A's `[Block]` count is whatever `tailTarget = 80` JSONL lines produced. There is no current check that the produced slice's accumulated height ≥ viewportHeight before `markAnchorSettled()` is called.

4. **`HistoryPhaseBFlickerSnapshotTests` does not drive the `.id(sid)` re-mount** — it runs `loadHistory` against a single fresh-mount controller. The real flicker scenario combines `.id(sid)` swap + Phase A + Phase B in the same window. A combined harness test would cover the production path end-to-end.

5. **Image diff helper** — listed as pending in TaskList but not implemented; current intent is to compute per-tick row-geometry deltas rather than pixel diff (less false-positive prone for text changes).

## Open tasks at handoff time

```
#11 [pending]    Add image-diff helper for automated flicker detection
                 — see "Open work" item 5; consider row-geometry tracking instead
#12 [in_progress] Investigate Phase B anchor-stable mechanism in real flow
                 — see "Open work" items 1-2
```
