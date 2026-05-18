# Handoff — transcript scroll-anchor fix (`claude/elegant-wilbur-9036e6`)

Branch: `claude/elegant-wilbur-9036e6` → PR [ccterm#120](https://github.com/wasd96040501/ccterm/pull/120)
Worktree: `/Users/luoyangze/code/ccterm/.claude/worktrees/elegant-wilbur-9036e6`

## What this PR is trying to fix

Original bug: on re-entry to a previously-viewed session, the transcript landed **near the top instead of where the user left off (or the bottom)**. Cold-load (first-ever open) anchored to bottom correctly; re-entry did not.

Root cause analysis (full write-up earlier in the conversation):
- Cold-load and re-entry walked **two different anchor paths**. Cold-load went through `loadInitial`'s `pendingInitial`/`onLayoutReady` mechanism; re-entry only had `controller.scrollToBottom()` called from `ChatHistoryView.task`, which fired **before** the new `NSTableView` attached — its scroll intent was silently dropped by `coordinator.apply`'s no-table branch, then `tableView.didSet`'s automatic `reloadData()` landed the document at the top.
- The `onLayoutReady` callback gates on `prevWidth <= 0 && width > 0`, but `lastLayoutWidth` was sticky across detach/reattach, so the 0→positive edge never re-fired on re-mount.
- There was no per-session scroll-position memory.

## What was implemented

Architectural unification — one anchor channel for both cold-load and re-entry, plus per-session memory:

1. **`Transcript2Coordinator.tableView.didSet`** ([Transcript2Coordinator.swift:67-96](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift:67)) resets `lastLayoutWidth = -1` on every fresh table attach, so `tableFrameDidChange` re-fires `onLayoutReady` on every view re-mount.
2. **`Transcript2Controller.requestAnchor(_:)`** ([Transcript2Controller.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Controller.swift)) is the new uniform entry point. `pendingInitial` was renamed to `pendingAnchor` and now stores any `InitialAnchor`. A new case `InitialAnchor.preserved(CapturedAnchor)` carries a (blockId, sub-row y-offset) for resume-where-you-left-off.
3. **Capture/restore APIs** on coordinator: `captureVisibleAnchor() -> CapturedAnchor?` (topmost visible row + offset from clip's top), `scrollToCapturedAnchor(_:)`.
4. **Detach hook**: `coordinator.onWillDetach` closure ([Transcript2Coordinator.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift)), fired from `NativeTranscript2View.dismantleNSView` ([NativeTranscript2View.swift](macos/ccterm/Content/Chat/NativeTranscript2/NativeTranscript2View.swift)) before the observer is removed.
5. **`Session.lastVisibleAnchor`** ([Session.swift](macos/ccterm/Services/Session/Session/Session.swift)) — `@ObservationIgnored` field, populated by `wireScrollAnchorPersistence()` (called in all three Session init paths).
6. **`ChatHistoryView.task`** ([ChatHistoryView.swift:117-147](macos/ccterm/Content/Chat/ChatHistoryView.swift:117)): replaces `controller.scrollToBottom()` with `requestAnchor(s.lastVisibleAnchor.map { .preserved($0) } ?? .bottom)`.

Logging instrumentation is currently in place at every node in the anchor pipeline (all tagged `[anchor]`, see "Logging" below).

## Outstanding issues (this is what the next session needs to fix)

**Both issues stem from the same root cause** — `consumePendingAnchor` runs at the **FIRST** `onLayoutReady` fire, which happens at an **intermediate** table width, not the final settled width. The scroll target is computed against the wrong layout, then the table re-tiles to the final width and the position is off.

Evidence (from `/tmp/ccterm-anchor.log`, captured during reproduction):

```
01:05:20.395 tableFrameDidChange prev=-1.0 → 460.0; firing onLayoutReady (blocks=42)
01:05:20.395 consumePendingAnchor=.bottom blocks=42 layoutWidth=460.0    ← consumed at width=460
01:05:20.395 scrollToInitialAnchor → .bottom(A537200D)
01:05:20.405 tableFrameDidChange prev=-1.0 → 780.0; firing onLayoutReady (blocks=42)   ← table tiles to 780 ten ms later
01:05:20.405 consumePendingAnchor=nil (onLayoutReady fired with no pending)   ← anchor already consumed, can't re-snap
```

(Note: the second `prev=-1.0` is suspicious — looks like `lastLayoutWidth` was reset between the two fires; likely a second `tableView.didSet` we didn't log, or OS log ordering noise. Worth verifying.)

### Issue 1 — first open of a session doesn't scroll to bottom as expected

User report: "app 打开首次加载 session，没有按预期 scroll bottom"

Cold-load goes through `loadInitial`'s Phase 1 (`apply([.insert(viewportBatch)], scroll: .bottom)`), which historically worked. But during the recent log capture, the cold-load case at `01:05:18.269` showed:
```
scrollRowToBottom row=16/17 rect=(0.0, 947.890625, 1692.0, 28.48828125)
  docHeight=976.37890625 clipH=965.0 insetsBottom=180.0
  visibleBottomInClip=785.0 raw=191.37890625 target=191.37890625
  clip.y -44.0→191.37890625
```
- `target = 191.38`, `max valid scroll = docHeight - clipH + insets.bottom = 191.38`. **Numerically at max**, so the log shows "at bottom".
- But user reports it visually lands above the bottom. So either:
  - There's a SECOND scroll after this one that moves it away (e.g. another frame change causes a layout reshuffle, position invariant breaks).
  - OR the document re-tiles after this scroll (different width), changing `docHeight`, and clip.y stays at 191.38 which is no longer the bottom for the new layout.

### Issue 2 — `.preserved` lands slightly above where user was

User report: "如果切走前我在 bottom，切回来会在 bottom 上一点"

`scrollToCapturedAnchor` works by setting `clip.y = rect(row).origin.y - offsetFromClipTop`. Symmetric with capture, so should be exact.

In `/tmp/ccterm-anchor.log`:
```
captureVisibleAnchor → row=86/99 id=D70246CA rect.y=4531.91 clip.y=4559.92 offset=-28.00
... session switch ...
scrollToCapturedAnchor row=86/99 rect.y=4531.91 offset=-28.00 target=4559.92 clip.y 0.0→4559.92
  clipBounds=(1692.0, 965.0) docBounds=(1692.0, 5344.91796875)
```
- Capture: `rect.y=4531.91`, `clip.y=4559.92`, offset = -28.00.
- Restore: `rect.y=4531.91` (same — row hasn't moved), `target=4559.92`. ✓
- Max valid scroll = docHeight - clipH + insets.bottom = 5344.92 - 965 + 180 = **4559.92** — exactly at the bottom.

So numerically this restoration is correct. **But user says it's "slightly above".** That means **the document state at restore time isn't the same as at capture time**. Specifically:
- At capture: docBounds=??, but offset=-28 against rect.y=4531.91 → fine.
- At restore: docBounds=(1692.0, 5344.92). target=4559.92, which is the max.
- **After restore**: the table re-tiles (second frame change), document height changes. The clip.y stays at 4559.92 but the new "max valid" is different. Result: clip.y is no longer at the bottom of the resized doc.

### The root-cause hypothesis (one fix for both)

`consumePendingAnchor` runs at the FIRST `onLayoutReady` (intermediate width). The table then re-tiles to final width, but `pendingAnchor` is already cleared so no re-snap. Two reproducible problems:

1. The `target` we set was correct for the intermediate-width layout; at the final width, the document end is at a slightly different y. Clip.y stays where we put it. Visual gap.
2. The `enclosingScrollView` may be nil at the FIRST frame change in some cases (table not yet in scrollView), causing `scrollRowToBottom` to silently early-return. Logged this case at [Transcript2Coordinator.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift) — verify by reproducing and reading log.

## Candidate fixes (next session: pick one, verify with logs)

**A. Re-snap on every positive frame change while anchor still alive (recommended)**
- Change `tableFrameDidChange`: fire `onLayoutReady` on any `width > 0 && width != prevWidth`, not just on `0→positive`.
- Change `consumePendingAnchor`: don't clear `pendingAnchor` immediately. Re-apply on every fire.
- Clear `pendingAnchor` via a debounce (e.g. 200ms Task) so subsequent user-driven resizes don't re-snap forever.
- This pattern handles both intermediate-width transient and any post-mount layout settling.

**B. Defer the consume to the next runloop (simpler but less robust)**
- In `consumePendingAnchor`, dispatch the actual scroll via `Task { await Task.yield(); ... }` or `DispatchQueue.main.async`. By the time the deferred block runs, frame changes during the current SwiftUI commit have settled.
- Risk: a 10ms-apart-second-frame-change may still happen after the deferred block runs.

**C. Cancellable debounce inside `consumePendingAnchor`**
- Schedule the scroll for ~50ms in the future via a `Task`. Each new `onLayoutReady` fire cancels and re-schedules. The latest one wins, running after the layout has been stable for 50ms.
- Combine with re-firing `onLayoutReady` on every positive frame change.

**Whichever you pick**, also confirm the `enclosingScrollView == nil` early-return doesn't fire silently. The log at scrollRowToBottom's two new guards will catch it.

## Files touched on this branch

| File | What changed |
|---|---|
| [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Controller.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Controller.swift) | `pendingInitial` → `pendingAnchor`; `InitialAnchor.preserved` case; `requestAnchor(_:)` / `captureVisibleAnchor()` APIs; `scrollToInitialAnchor` handles `.preserved`; removed obsolete `scrollToBottom()` |
| [macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift](macos/ccterm/Content/Chat/NativeTranscript2/Transcript2Coordinator.swift) | `tableView.didSet` resets `lastLayoutWidth = -1`; new `CapturedAnchor` struct; `captureVisibleAnchor()` / `scrollToCapturedAnchor(_:)`; `onWillDetach` closure |
| [macos/ccterm/Content/Chat/NativeTranscript2/NativeTranscript2View.swift](macos/ccterm/Content/Chat/NativeTranscript2/NativeTranscript2View.swift) | `dismantleNSView` captures anchor and fires `onWillDetach` |
| [macos/ccterm/Content/Chat/ChatHistoryView.swift](macos/ccterm/Content/Chat/ChatHistoryView.swift) | `.task` replaced `scrollToBottom()` with `requestAnchor(saved-or-.bottom)` |
| [macos/ccterm/Services/Session/Session/Session.swift](macos/ccterm/Services/Session/Session/Session.swift) | `lastVisibleAnchor` field; `wireScrollAnchorPersistence()` called in all three inits |
| [macos/ccterm/Content/Chat/CLAUDE.md](macos/ccterm/Content/Chat/CLAUDE.md) | Updated to describe the new uniform anchor flow |

Commits on this branch:
- `5643c06` fix(transcript): restore scroll position on session re-entry (the actual fix)
- `c2410ee` chore(transcript): trace anchor lifecycle for diagnostics (instrumentation)
- `2ac5107` chore(transcript): log scrollRowToBottom + its early-return cases (more diagnostics)

## Logging — `[anchor]` trace points

Every step is logged with the `[anchor]` prefix. Capture with:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.ccterm.app" AND eventMessage CONTAINS "[anchor]"' \
  --level info --style compact > /tmp/ccterm-anchor.log
```

Categories and messages:

- `ChatHistoryView`: `[anchor] task-mount sid=… saved=… → requestAnchor`
- `Transcript2Controller`: `[anchor] requestAnchor=…`, `[anchor] consumePendingAnchor=…`, `[anchor] scrollToInitialAnchor → …`
- `Transcript2Coordinator`: `[anchor] tableView.didSet attach …`, `[anchor] tableFrameDidChange prev=… → …`, `[anchor] captureVisibleAnchor → …`, `[anchor] scrollToCapturedAnchor …`, `[anchor] scrollRowToBottom …` (+ two `EARLY` guard branches), `[anchor] apply with no table — scroll intent dropped`
- `Session`: `[anchor] onWillDetach received sid=… captured=…`
- `NativeTranscript2View`: `[anchor] dismantleNSView begin wired=…`

**Strip the logs before final merge** — they're verbose and noisy. The PR description should not promise them as a feature.

## How to reproduce

App is built at `/Users/luoyangze/Library/Developer/Xcode/DerivedData/ccterm-cadfzfnsfmjvwmbazyvmahqypjzw/Build/Products/Debug/ccterm.app`. To kill all stale instances and relaunch:

```bash
pkill -9 -f "ccterm.app/Contents/MacOS/ccterm" 2>/dev/null; sleep 1
open /Users/luoyangze/Library/Developer/Xcode/DerivedData/ccterm-cadfzfnsfmjvwmbazyvmahqypjzw/Build/Products/Debug/ccterm.app
```

There can be a stale instance from a different DerivedData path running — verify with `ps -A -o pid,command | grep "ccterm.app/Contents/MacOS/ccterm" | grep -v grep` (we hit this once mid-debug; user ran the reproduction on the old build for one cycle).

For Issue 1 (first-open at bottom): launch app, click a session that has long history. Should land at the very bottom.

For Issue 2 (re-entry at bottom): open session A, confirm at bottom (don't scroll). Click session B in sidebar. Click A again. Should land at bottom; user reports it's slightly above.

## Don't regress

- Bridge wiring (`Transcript2EntryBridge` subscribes to `runtime.onMessagesChange`) was intentionally untouched. The continuous feed must keep flowing even when no view is mounted — this is a load-bearing perf contract per [Services/Session/CLAUDE.md](macos/ccterm/Services/Session/CLAUDE.md) and [Content/Chat/NativeTranscript2/CLAUDE.md](macos/ccterm/Content/Chat/NativeTranscript2/CLAUDE.md).
- `cctermTests` is the merge gate (CI runs `make test-unit`). Last successful run had 111 cases pass; rerun with `make test-unit` before pushing further.
- `make fmt-check` must pass.
- The "load-bearing performance contract" listed in [NativeTranscript2/CLAUDE.md § 2](macos/ccterm/Content/Chat/NativeTranscript2/CLAUDE.md) — anything that touches the structural-change pipeline needs to be sanity-checked against those items.
