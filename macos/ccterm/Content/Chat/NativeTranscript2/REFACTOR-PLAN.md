# Transcript load & scroll — refactor plan

> ⚠️ **DO NOT MERGE INTO `main`. Delete this file before the PR lands.**
> Working scratch for the upcoming refactor. Pairs with
> `REFACTOR-CONSENSUS.md` (the *why* / conclusions); this file is the
> *how* / technical plan. Remove both before squash-merge.

---

## 1. Background

A session switch can hard-crash on `Transcript2ScrollView.popScrollerHidden()`'s
release `precondition`. Root cause (see consensus §1–2): the scroller-hidden
state is a manual push/pop refcount living on a per-switch-recreated scroll-view
instance, late-resolved through a mutable pointer, written by three
uncoordinated async producers — so push and pop can land on different
instances and the count underflows.

That crash is the symptom. The disease is that history load (`Phase A/B`),
viewport rendering (`setHistory` `Phase 1/2`), scroll anchoring, and scroller
visibility are tangled into channels that fire side effects across async hops.
This plan replaces the whole load+scroll path with one shape.

---

## 2. Goals / non-goals

**Goals**
- One source of truth, one ordered write entry, no cross-instance bookkeeping.
- History load that shows the tail instantly and backfills upward without ever
  producing an intermediate wrong frame (no anchor jitter).
- Off-main typesetting; the main thread never blocks on parse or CTLine.
- Delete `ToolResultReresolver`, the shadow `SessionRuntime`, the scroller
  refcount, and the `setHistory` two-path split.

**Non-goals (this pass)**
- Tool-group rendering, selection, search, syntax highlight back-fill — unchanged.
- The live CLI streaming path stays; only its *merge* with load is redefined.

---

## 3. Architecture in one picture

```
                    coordinator.blocks            ← single source of truth
                          ▲
                          │ apply(change)         ← single ordered entry, @MainActor
              ┌───────────┴────────────┐
        content pipeline           view lifecycle
   (history iterator + live CLI)   (attach / resize / dismantle)
   emits block changes only        owns geometry + scroll + anchor
   never touches scroll/scroller   reads blocks, never writes

   scrollerHidden = f(pipeline.isLoading, view.inLiveResize)   ← derived; recomputed on change; applied to the currently-bound scroll view. No counter, no push/pop.
```

`apply(change)` = **data mutation + table structural notify, atomic, in one
source phase**. `blocks` changes ⟺ `insertRows`/`removeRows`/`noteHeightOfRows`
in the *same* tick. Pixels are **pulled** by NSTableView in `beforeWaiting`
(`heightOfRow`/`viewFor` ← layout cache). `apply` draws nothing.

---

## 4. The content pipeline: a reverse streaming iterator

`setHistory(blocks: [Block])` is replaced by a pull from a **reverse streaming
iterator**. The controller drains pre-built blocks from the top of the
not-yet-loaded region and prepends them.

### 4.1 What the iterator is

A stateful streaming builder, running **off-main**:

```
JSONL bytes  →  Message2  →  grouped / tool-paired entries  →  Block (+ RowLayout)
   (reverse, paged)            (withholds incomplete pairs)        (typeset at snapshotted width)
```

It is **not** a dumb byte pager. It owns the grouping + tool-pairing rules that
today live inside `SessionRuntime.receive` — extracted into a **pure,
reusable builder**. That extraction is the proper death of `buildEntries`'
throwaway in-memory `SessionRuntime`.

### 4.2 Tool pairing is free under reverse reading

In document order a `tool_use` is always *earlier* (higher) than its
`tool_result` — you cannot have a result before the call. Reading **bottom-up**
therefore always hits the `tool_result` first and reaches its `tool_use`
later (above). So:

- An orphan `tool_result` is **withheld** in an internal map keyed by
  `tool_use_id` — not emitted.
- When its `tool_use` is reached, the pair is built into one complete tool
  block and emitted **at the tool_use's position** (above the entries that sat
  between them — document order comes out correct).
- The controller therefore **only ever receives complete blocks**. No orphan
  reaches the UI.

This deletes `ToolResultReresolver`, the byte-offset arithmetic, and the
`.updated`-on-load re-fan-out. Paging becomes a pure I/O detail, fully
decoupled from block emission (the withhold-buffer spans page boundaries).

**True-orphan flush.** The only unresolvable case is a `tool_use` absent from
the entire file (truncation / compaction). On reaching the file top, any still
held orphan is emitted best-effort (result-only / unknown-tool card). This is
the irreducible residue of "show before fully read" — a real data condition,
tiny in volume.

**Load vs live split.** Load path emits blocks born complete → **no `.updated`
on load**. `.updated` survives only on the live path (a `tool_use` renders
running, its `tool_result` arrives later and updates it).

### 4.3 Off-main layout and the width contract

Layout (the CTLine / Core Text typesetting — the dominant cost) is computed
**off-main, inside the iterator**, because backfill prepends *above* the
viewport and NSTableView still calls `heightOfRow` for off-screen prepended
rows (it needs their heights for document height + anchor). Doing layout lazily
on-main would typeset rows the user cannot see, on the main thread. Off-main
precompute keeps those off the main thread; the on-main insert is then a
cache **hit** (a dict lookup), not a typeset.

Off-main layout is sound only because **layout is a pure function of
`(block, width, state)`** (existing `nonisolated static makeLayout`). `width`
is the one input owned by main-thread view geometry, so it is handled by a
**snapshot → validate** contract:

1. **Snapshot** the settled row width on main, *after* TICK 1's
   `layoutSubtreeIfNeeded`, and feed it to the iterator.
2. The iterator **tags** every built layout with the width it used.
3. On the main `apply` hop, **validate** `builtWidth == currentSettledWidth`:
   - **match** (the common case — the window is not resized mid-load) → install
     layouts into cache + insert rows → cache hit, zero main-thread CTLine.
   - **drift** (a resize happened mid-load — rare) → do not trust the prebuilt
     layout: insert the rows anyway (data is width-independent), let
     `heightOfRow` lazily recompute the affected rows at the new width
     (cache miss = CTLine on main for those rows, correct but degraded), and
     **retarget the iterator** to the new width for remaining pages. Already
     applied visible rows go through the normal resize relayout path.

This width guard is **irreducible** when layout is off-main — but it is now
**one guard in one pipeline**, replacing the three scattered copies today
(`applyInBackground`, `refillLayoutCache`, `setHistory`).

---

## 5. Tick anchor consensus

> **Within any single source-phase tick, scroll is stable iff — in that same
> tick, before computing the scroll target — every row geometry the target
> depends on is settled synchronously.**

In-tick order, all synchronous (no cross-hop, no "next tick fixes it"):

```
[one source phase]
  1. blocks change + insertRows/removeRows         (data ⟺ structure, atomic)
  2. tableView.layoutSubtreeIfNeeded()             (force tile NOW → rect(ofRow:) real)
  3. compute target / anchor-compensation from real rects
  4. clip.scroll(to:) + reflectScrolledClipView
  ── 1–4 wrapped in CATransaction.setDisableActions(true) + allowsImplicitAnimation = false ──
        ▼
[beforeWaiting] flushes exactly ONE composite: rows at true heights, clip at right origin. No intermediate frame.
```

Because layouts are precomputed off-main at the validated width, step 2 is a
tile of **cache hits** — cheap and synchronous.

**Multi-tick load stays jitter-free iff:** every tick is individually stable
(above) **and** non-first ticks only ever *prepend above with anchor
preservation* (shift the scroll origin down by the inserted batch's measured
height so visible content stays fixed). No tick ever produces a wrong frame, so
the user sees no jump.

**Block ↔ row alignment invariant.** `coordinator.blocks.count ==
tableView.numberOfRows`, index-for-index, at the terminal state of every tick.
This holds because `insertRows`/`removeRows` is the structural half of the
atomic `apply` and updates the table's row count **synchronously** in the same
source phase; only geometry is deferred to `beforeWaiting`. The single rule that
keeps it true: **never mutate `blocks` outside `apply`.**

---

## 6. Tick timeline — cold session switch

```
TICK 1  [source]  VIEW: attach — synchronous, one tick
        make shell → addSubview → layoutSubtreeIfNeeded (settle + SNAPSHOT width)
        → bindData → render current blocks (cold = empty / warm = full) → scrollToTail
        → start the iterator (off-main), fed the snapshotted width
        → scrollerHidden = true (pipeline loading)
        [beforeWaiting] single tile @ settled width, draw, commit
        ── the view line ends here; it does not know whether history is loading ──

TICK 2..N  [source]  CONTENT: backfill drain — one apply per tick
        drain ≤ budget ready blocks from the iterator buffer
        → apply(.prepend, batch)   (anchor-preserving; §5 recipe)
        [beforeWaiting] insert above; viewport fixed; off-screen rows realize no cells

TICK last  iterator exhausted (file top reached, orphans flushed)
        → flush pending live events (§7)
        → pipeline idle → scrollerHidden recomputed false → fade in
```

The tail's first screen is part of TICK 1's "render current blocks" when warm,
or arrives as the first backfill batch when cold — either way no special path.

---

## 7. Live merge (pending)

During load a `flag` marks the pipeline busy. Live CLI events are queued:

- **Simple-correct (v1):** queue *all* live events while loading; flush in
  order when the iterator exhausts, before going idle.
- **Optimization (later):** live events are *tail appends* while backfill is
  *head prepends* — opposite ends, positionally non-conflicting. Tail appends
  could pass through during load (the user is viewing the stable tail). Defer
  this until v1 is proven; the only events that truly must queue are
  updates/removes targeting an entry the iterator may still be building.

End condition is explicit: **iterator exhausted** = flag down → flush pending →
idle.

---

## 8. Scroller visibility (derived)

`scrollerHidden = f(pipeline.isLoading, view.inLiveResize)`. Owned at
session/coordinator lifetime, recomputed whenever an input changes, applied to
the currently-bound scroll view (re-applied on rebind). No counter, no
push/pop, no cross-instance hazard.

Bonus synergy: while backfilling, the document's true top and total height are
provisional (unknown until the iterator exhausts), so the scroller thumb would
otherwise jump — but `isLoading` keeps the scroller hidden through exactly that
window.

The crashing `precondition` is **deleted** with the refcount, not softened
(consensus §8).

---

## 9. Per-tick budget — fixed vs heuristic

Cost lands in **two** places; budget each where its cost lives.

### 9.1 Off-main page build — heuristic (this is where the real budget is)
CTLine / Core Text typesetting and `MarkdownDocument(parsing:)` run here.
Their cost is ∝ **text volume**, not block count — one 2000-line code block
dwarfs 50 short paragraphs. So budget by **work, not count**: build until a
per-page soft budget (wall-clock ~Xms, or accumulated text length) is hit, then
publish the page to the ready-buffer. This naturally rate-limits supply.

### 9.2 Main-thread drain — loose count cap (safety valve, not a typeset budget)
Because layouts are precomputed off-main (§4.3), the main-tick cost is **not**
CTLine: it is `insertRows` bookkeeping + documentView growth + one anchor
compensation, ≈ ∝ inserted rows, and off-screen prepends realize no cells. This
is small.

- **Start fixed / simple** (drain the ready buffer, capped at a constant K — a
  page, or ~30–50 rows). The off-main throttle (§9.1) already paces supply, so
  a fixed cap rarely matters when inserts are cache hits.
- **Go adaptive only if measured** to drop frames on a pathological transcript
  (e.g. nudge K toward a 4–6 ms main-thread target using the prior tick's
  duration). Do **not** build the adaptive controller up front.

### 9.3 Oversized-single-block exception
A block whose own layout exceeds the budget (a giant code block) still goes in
one tick — a row cannot be split across ticks. The budget caps a **batch**, it
never splits a block.

---

## 10. What gets deleted

- `ToolResultReresolver` (subsystem) — §4.2.
- `buildEntries`' throwaway in-memory `SessionRuntime` + CoreData stack — §4.1.
- `tailBaseline / newTailStart / absoluteTailEnd / tailMessagesAsArray` offset
  math — §4.2.
- `setHistory`'s four-concern fusion + the bridge's two reset paths +
  `applyAppend`'s `setHistory(seed)` race patch + the zero-width branch — §3/§4.
- `scrollerHiddenCount` + `pushScrollerHidden`/`popScrollerHidden` + the
  `precondition` + `didPushForLiveResize` + the `flashScrollers` override — §8.
- `applyInBackground`'s "completion fires exactly once" contract — its only job
  was balancing push/pop across the hop — §8.
- Two of the three `layoutWidth == width` / `mutationCounter` guard copies,
  collapsed into the one pipeline guard — §4.3.

---

## 11. Open questions (to settle before coding)

- Iterator API surface: pull (`next()` non-blocking, returns buffered) vs push
  (reader posts batches, main drains). Both keep parse/CTLine off-main; pick the
  one that makes backpressure + width-retarget cleanest.
- Where the pipeline `isLoading` flag and the derived `scrollerHidden` live
  (controller vs coordinator).
- The `apply` change-set vocabulary after the resolver removal (does `.prepend`
  become a first-class case distinct from `.insert(after: nil)`?).
- Test net: which merge-gate tests assert the anchor invariant and the
  single-width typeset contract under the new pipeline.
