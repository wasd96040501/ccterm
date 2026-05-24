# Refactor handoff — transcript load & scroll

> Scratch handoff for resuming `REFACTOR-PLAN.md` in a fresh session. Delete
> with the plan before the PR lands (that's Task 8).

## Where things stand

- **Branch / PR**: `docs/transcript-load-scroll-consensus` → PR #230 (reusing it).
- **Working tree**: clean, in sync with `origin`.
- **Build/tests**: green — full `make test-unit` passes (347 cases) at the last commit.
- The original plan was **8 tasks**; **#1–#6 are done, committed, pushed**.
  **Remaining: #5b (off-main typeset), #7 (Tier-2 probes), #8 (finalize).**
- **User's chosen order for the rest: do 5b FIRST, then 7, then 8.**

## Task ledger

| # | Task | Status | Commit |
|---|---|---|---|
| 1 | Extract pure reverse-streaming entry builder (`ReverseEntryBuilder`) + Group A tests | ✅ | `b0489fa` |
| 2 | First-class `.prepend` / `.append` / `.replace` vocabulary + Group C tests | ✅ | `22d7fc4` |
| 3 | deposit→drain `TranscriptBackfillPipeline` + Group B tests | ✅ | `8fa6038` |
| 4 | Wire pipeline into load path; collapse bridge; delete legacy load | ✅ | `8fa2863` |
| — | **Resolve `mutationCounter`** (insertRows-vs-noteHeightOfRows asymmetry) → REFACTOR-PLAN §5.1 | ✅ | `a4d7345` |
| 5 | In-tick refill anchor (`layoutSubtreeIfNeeded` in refill hop); **delete `mutationCounter`** | ✅ | `403d552` |
| 6a | Delete scroller-hidden refcount (§8) — the original crash class | ✅ | `f8976cc` |
| 6b | Delete `setHistory` + `sliceForViewport`; migrate 10 callers to `.append` | ✅ | `d618040` |
| 6c | Delete now-dead `applyInBackground` + its docs | ✅ | `de4eb29` |
| 6d | Internalize `.insert(after:)` → private `insertBlocks`; vocabulary is intrinsic-position only | ✅ | `862fcfa` |
| **5b** | **Off-main typeset in the backfill pipeline** | ⏳ **next** | — |
| 7 | Tier-2 offscreen-UI measurement probes U1–U8 (§12.2) | ⏳ | — |
| 8 | Finalize: confirm derived `isLoading` (§8a), `make fmt`, delete `REFACTOR-PLAN.md` + this file | ⏳ | — |

## The `mutationCounter` question is RESOLVED — don't relitigate

It was the big open problem in the prior handoff. **Resolution lives in
REFACTOR-PLAN §5.1.** One-paragraph version:

- `insertRows` settles geometry **synchronously** in `endUpdates` (this table
  has no estimated heights, §2.1), so the `.prepend` / `.append` backfill path's
  `.saveVisible` anchor already reads real `rect(ofRow:)` — **no forced tile**.
- `noteHeightOfRows` **defers** its re-tile. `refillLayoutCache` is the only
  `.saveVisible` path built on it, which is why it (alone) needed the counter.
- Fix shipped in `403d552`: force `table.layoutSubtreeIfNeeded()` inside
  `refillLayoutCache`'s `withScrollAdjustment(.saveVisible)` body (after
  `noteHeightOfRows`, before `applyAnchor`). Compensation is now in-tick →
  a concurrent `apply` can't corrupt a deferred compensation → counter deleted.
- §2.7 of `NativeTranscript2/CLAUDE.md` documents the in-tick refill now.

## Task 5b — off-main typeset (do this first)

### The gap
`TranscriptBackfillPipeline` (`NativeTranscript2Bridge/TranscriptBackfillPipeline.swift`)
parses **markdown off-main** in its producer, but **per-row CTLine typesetting
still lands lazily on the main thread** via `heightOfRow` during the drain's
`.prepend`/`.append`. See the class doc comment (`:28–31`) and
`NativeTranscript2/CLAUDE.md §2.6` ("moving it off-main into the producer is
tracked separately"). Plan target: §4.3 (off-main layout + width contract) and
§4.4 (resize / `retarget`).

### Why it matters
Backfill prepends **above** the viewport; `NSTableView` calls `heightOfRow` for
those off-screen rows (it needs heights for document height + anchor). Lazy
on-main layout therefore typesets rows the user can't see, on the main thread —
the freeze the old `applyInBackground` avoided and that §4.3 wants gone.

### The shape to build (per plan §4.3/§4.5)
1. **Thread width into the pipeline.** `start()` currently takes no width. Add a
   `trigger(width)` (the ONE call that passes width, after TICK-1 settle) and a
   `retarget(width)` for resize. **Do NOT `retarget` during live resize** (§4.4)
   — fire once at `viewDidEndLiveResize` with the final width.
2. **Build `RowLayout`s off-main in the producer.** `Transcript2Coordinator.makeLayout(for:width:highlights:folds:statuses:)`
   is `nonisolated static` (§2.5) — callable off-main. At load time the
   highlights/folds/statuses snapshots are mostly empty/default. Deposit
   `(entries, blocks, layouts)` instead of `(entries, blocks)`.
3. **Install precomputed layouts on the drain, before the structural change**,
   so `heightOfRow` is a **cache hit**. `cacheLayouts(_:width:)` already exists
   (the §2.14 anti-poison check applies). Likely add a coordinator entry like
   `apply(_:scroll:precomputed:)` or call `cacheLayouts` immediately before
   `apply(.prepend)` — keep it going through the single `apply` (don't add a
   second mutation channel; §3.1 "one mutation entry point").
4. **Width is self-healing, not a guard** (§4.3/§4.4): off-main layouts tagged
   with the width they used; `layout(for:id,width:)` hits only on match,
   recomputes on miss. A stale-width batch installs as-is and re-typesets lazily
   — no validation gate, no generation counter. The clamp band
   `clampedLayoutWidth = min(780, max(460, rowWidth))` makes mid-load resize rare.

### Test seams (no test-only hacks — §12.3)
- Injectable `ReversePageSource` already exists (Group B fakes it).
- `onLayoutCacheWriteForDebug(id, width)` write-trace already exists — use it to
  assert single-width typeset (U1).
- `TranscriptBackfillPipeline` exposes `onDepositForDebug` / `onDrainTickForDebug`.
- `historyLoadState` is `@Observable`; await it, never `Task.sleep` (suite rule #6).

## Task 7 — Tier-2 offscreen-UI probes (§12.2)

Merge-gate property tests (NO `Snapshot` filename suffix, or `scripts/test-unit.sh`
skips them). Reuse the `TranscriptReentryLayoutCacheTests` /
`TranscriptHostReentryLayoutCacheTests` scaffold: offscreen `alphaValue=0.01`
window, `onLayoutCacheWriteForDebug` trace, `drainMainLoop`, the
`Write{id,width,stage}` grouping helper. Probes U1–U8 (plus optional U9/U10) are
fully specified in REFACTOR-PLAN §12.2 with suggested class names. The two §11
questions — **anchor invariant** and **single-width typeset contract** — are
U1/U2/U3.

Note: U1 (single-width contract) only becomes a *strong* gate once 5b lands
(off-main precompute means a prepend tick should be cache-hits / zero new
typeset). That's the main reason the user ordered 5b before 7.

## Task 8 — finalize
- Confirm `isLoading` stays **derived** from `SessionRuntime.historyLoadState`
  (no stored flag on controller/coordinator — §8a). Likely already true; assert
  via a Group C test (C7) if not already covered.
- `make fmt`.
- Delete `REFACTOR-PLAN.md` + this `HANDOFF.md`.

## Carried-over accepted boundary (from Task 4, plan §7)
History is rendered straight into the controller and is **not** put into
`runtime.messages`, so a *live* `tool_result` targeting a *history* `tool_use`
(resume-mid-tool) won't merge. The plan accepts this and defers the narrow fix.

## Workflow reminders
- Each task + its tests: `make build` → `make test-unit` → `make fmt` → commit →
  push, reusing PR #230. Commit the doc-only changes separately from code.
- Read `NativeTranscript2/CLAUDE.md` (esp. §2.6 / §2.7 / §3.1 — all updated this
  session) and `REFACTOR-PLAN.md` (esp. §4.3/§4.4/§5.1/§12) before touching code.
- `make test-unit` is the merge gate; snapshot tests (`*SnapshotTests.swift`) are
  opt-in and were migrated off `setHistory` to `.append` this session.
