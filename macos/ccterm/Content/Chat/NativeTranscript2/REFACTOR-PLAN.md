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

### 3.1 Division of responsibility — who owns what

The point of the refactor is that **no piece reaches into another's job**, and
most of the hard parts are owned by machinery that **already exists** and is
left unchanged. Read this table as the contract; the rest of the doc elaborates.

| Concern | Owner | New or existing | Notes |
|---|---|---|---|
| **Source of truth (block list)** | `Transcript2Coordinator.blocks` | existing | The only authority. |
| **Single write entry** | `apply(change)` | existing | Atomic data + structural notify, one tick. The *only* mutator. |
| **Layout correctness across width** | **layout cache (width-keyed) + pure `makeLayout`** | **existing** | A cache entry carries its width; `layout(for:id,width:)` hits only on match, recomputes on miss. A wrong-width entry is self-healing — never a guard to maintain. |
| **Off-main typesetting** | the reverse streaming iterator | **new** | Builds blocks **and** their layouts off-main, at the current row width. Withholds incomplete tool pairs (§4.2). |
| **Telling the iterator the width** | view lifecycle → `iterator.retarget(width)` | new (one call) | The *entire* job on resize-mid-load. Even this is a perf optimization, not correctness (§4.4). |
| **Visible-row relayout on resize** | **live-resize path (`refillLayoutCache` equiv.)** | **existing** | `viewWillStartLiveResize` / `viewDidEndLiveResize` rebuild what's on screen. Untouched. |
| **Per-tick prepend + anchor** | controller, in-tick (§5 recipe) | new | Force tile → read real rects → scroll-compensate → commit, all one tick. No deferred compensation, so no `mutationCounter`-style guard. |
| **Scroll-anchor intent** | rides with the change (`.prepend` ⇒ preserve viewport) | new vocabulary | A semantic property of the change, not a side effect a producer fires. |
| **Scroller visibility** | derived `f(pipeline.isLoading, view.inLiveResize)` | new | Session-lifetime, recomputed on input change, applied to current scroll view. No counter, no push/pop. |
| **Live/load merge** | pending queue, flushed at iterator exhaustion (§7) | new | Defined end condition; no race patches. |

The recurring theme: **layout-vs-width and visible-resize are already solved by
existing machinery**; the new code only adds the off-main builder, the in-tick
prepend recipe, the derived scroller, and a one-call `retarget`.

---

## 4. The content pipeline: a reverse streaming iterator

`setHistory(blocks: [Block])` is replaced by a pull from a **reverse streaming
iterator**. The controller drains pre-built blocks from the top of the
not-yet-loaded region and prepends them.

### 4.1 What the iterator is

A stateful streaming builder, running **off-main**:

```
JSONL bytes  →  Message2  →  grouped / tool-paired entries  →  Block (+ RowLayout)
   (reverse, paged)            (withholds incomplete pairs)        (typeset at current row width)
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

Off-main layout is sound **by construction** because two existing facts compose:
**layout is a pure function of `(block, width, state)`** (`nonisolated static
makeLayout`), and **the layout cache is width-keyed** — `CachedLayout` carries
the width it was built at, and `layout(for: id, width:)` returns the cached
value *only* when the width matches, recomputing on mismatch.

`width` is the one input owned by main-thread view geometry. But it needs **no
snapshot/validate/generation apparatus**, because a wrong-width cache entry is
**self-healing**: it is consulted only through the width-matching read, so it
can never corrupt anything — at worst it becomes a cache miss that recomputes at
the current width. Concretely:

- The iterator builds at **the current row width**, fed once at start (after
  TICK 1's settle) and updated by `retarget(width)` whenever it changes.
- On the install hop the off-main layouts go into the cache tagged with the
  width they used, through the **existing** write path (the §2.14 anti-poison
  check still applies). No validation gate.
- `heightOfRow` reads `layout(for: id, width: currentWidth)`: a match is a
  cache hit (zero main-thread CTLine — the common case, since the window is
  rarely resized mid-load and on a wide window the width is pinned at
  `maxLayoutWidth`); a mismatch recomputes on main for that row (correct,
  degraded), exactly as today.

**Resize mid-load is therefore almost nothing to do** (see §4.4 and the
responsibility table in §3.1). The width is *not* a guard you maintain; it is
just an honest field on the cache entry that already exists.

### 4.4 Resize during backfill — the minimal action

When the row width changes while the iterator is still backfilling, the work
splits cleanly by owner, and the new pipeline's only job is one method call:

| What | Who handles it | Cost |
|---|---|---|
| Already-applied **visible** rows | existing live-resize path (`viewWillStartLiveResize` / `viewDidEndLiveResize` → `refillLayoutCache` equiv.) | normal resize relayout |
| Already-applied **off-screen** rows (above) | width-keyed cache → `heightOfRow` recomputes lazily when scrolled into view | deferred, on demand |
| In-flight / buffered pages built at the **old** width | install as-is → `heightOfRow` miss → recompute at new width on insert tile | self-healing; only the off-main typeset was wasted |
| **Future** pages | `iterator.retarget(newWidth)` so they build at the new width | one call |

So the pipeline does exactly **one thing** on resize: `retarget(newWidth)`. And
even that is a *performance* choice — skipping it stays correct (every batch
self-heals through the width-keyed cache), it would just waste off-main typeset
on pages that then recompute. There is **no generation, no validate gate, no
discard bookkeeping** required for correctness.

Note the clamp band makes this rare to begin with:
`clampedLayoutWidth = min(780, max(460, rowWidth))`, so resizing only changes
the layout width while the detail pane is within `[460, 780]`; on a wide window
it is pinned at `780` and mid-load resize changes nothing.

**During a *live* resize, do not `retarget` at all.** The width changes every
frame and every intermediate value is meaningless (instantly stale). The
iterator keeps building at the pre-resize width throughout `inLiveResize`;
`retarget` fires **once**, at `viewDidEndLiveResize`, with the final width.
Pages built during the drag at the old width self-heal. This is the same
"minimum during the drag, real work at the end" rhythm as the existing
visible-row path (§2.8).

### 4.5 Lifecycle: trigger, off-main produce, main-owned buffer, drain

Decided model (resolves the push/pull question): **off-main produces and
*deposits*; the main thread *drains*. There is no main-thread polling and no
shared mutable buffer.**

```
trigger(width)                         ← the ONE call that passes width; starts the off-main task
   │
off-main task (runs until file top):
   read page (reverse, paged)
   → parse + group + tool-pair + typeset      (all heavy work here)
   → produce one immutable Sendable page = [Block] + their RowLayouts
   → hop to main: append page to the MAIN-OWNED pending buffer, wake a drain
   → continue reading the next page off-main
   │
main drain (woken by a deposit; self-reschedules while buffer non-empty):
   take ≤ budget pre-built blocks from the buffer
   → apply(.prepend, batch)   (§5 in-tick recipe)
```

- **Concurrency: no lock.** The pending buffer is **owned by the main actor**.
  The off-main task touches it only inside its main hop, and the drain runs on
  main too — both are serialized by the runloop, so the "off-main writes while
  main drains" race **cannot occur**. The cross-thread boundary carries an
  *immutable* `Sendable` page, never a buffer two threads mutate. (A shared
  mutable buffer + lock held during drain would also work, but it is the worse
  design — the main-owned buffer removes the need for the lock entirely.)
- **The deposit *is* the wake.** Main never polls an empty buffer; the first
  drain happens only after the first page is deposited. No wasted empty tick on
  the consumer side.
- **First tick on a cold open is empty.** When a never-loaded session is
  attached, the off-main task has produced nothing yet, so TICK 1 renders no
  content and applies nothing — the transcript is genuinely empty for the gap
  between attach and the first deposit (a small tail page, tens of ms). Warm
  sessions have no gap (blocks already present from the continuous bridge).
- **Covering the cold gap: blank, or a baked image of the pre-switch frame —
  never a loading affordance.** No spinner / placeholder UI. The two acceptable
  options (to pick later) are an empty surface or a one-frame snapshot of the
  outgoing session composited until the first deposit lands.

### 4.6 The `apply` change vocabulary

`setHistory` is **deleted**; all content mutation is `apply(change)`. Promoting
`.prepend` to first-class is not cosmetic — it **folds the scroll intent into
the case** (the §3.1 "intent rides with the change" principle), shrinking the
free-form `scroll:` parameter away.

| case | position | intrinsic scroll intent | drives |
|---|---|---|---|
| `.prepend(blocks)` | top (index 0) | preserve viewport (save visual-top row) | backfill batches |
| `.append(blocks)` | tail | stick to bottom if user is at bottom | live tail entries, loading pill |
| `.replace(oldIds: [UUID], with: [Block])` | **in place** (where `oldIds` sit) | preserve viewport | structure-changed update — the segment swap (see note) |
| `.remove(ids)` | — | preserve viewport | entry/segment removal, pill removal |
| `.update(id, kind)` | — | preserve viewport (`noteHeightOfRows`, anchor fixed) | same-id per-block update — the ~95% tool_result merge |

- **No anchored `.insert(after: id)`.** Position is intrinsic to each case — top
  (`prepend`), tail (`append`), or in place (`replace`). The old generic
  `.insert(after: arbitraryId)` was exactly the seam that *hid* a segment swap
  inside a generic insert (paired loosely with a separate `.remove`); it is gone.
- **The mid-list operation is `.replace`, made explicit** (verified caller:
  `Transcript2EntryBridge.applyUpdate`'s *structure-changed* branch — an entry
  whose block sequence changed, e.g. a `tool_result` landing on an entry that is
  no longer the tail). `.replace(oldIds:with:)` finds the contiguous range of
  `oldIds`, swaps in `newBlocks` at that same start index, atomically — the
  remove+insert can't be split or misordered, and the complexity is named, not
  buried. (Degenerate `oldIds == []` — an out-of-order sink for an unregistered
  entry — routes to `.append`, not `.replace`.)
- **Initial "anchor to tail" is NOT a change** — it is the one-time view-lifecycle
  `scrollToTail` (TICK 1 / first content), per §3.1: view lifecycle owns *where to
  land*; changes only carry *"don't disturb what's visible"*. So `.append` never
  has to encode "should I scroll to tail" — the empty-table first landing is the
  controller's job.
- **The `scroll:` parameter shrinks to two intrinsic intents** — preserve-viewport
  (everything except append) and stick-bottom (append). Whether a thin explicit
  override survives for an edge case is a coding-time call; the default is per-case.
- **The bridge's load path collapses.** The iterator owns Message2→block for
  history and feeds `.prepend` / `.append` directly, so the bridge's `.reset` /
  `.prepended` handlers + the `didLoadInitial` two-path split are **deleted**. The
  bridge keeps only the live path (`.append` / `.update` / `.remove`).
  → **load path = iterator → apply; live path = bridge → apply**, both converging
  on the one `apply`.

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

Because layouts are precomputed off-main at the current width, step 2 is
normally a tile of **cache hits** — cheap and synchronous. Crucially, even on a
cache **miss** (width drifted) the tile recomputes real heights *in-tick*, so
step 3 still reads true rects. The anchor is therefore **never computed against
deferred/stale geometry**.

**This is why the old `mutationCounter` guard disappears.** That counter existed
only because `applyInBackground` / `refillLayoutCache` deferred the anchor
compensation across an async hop, where AppKit's heights could be mid-flight and
`saveVisible` would compensate against stale values. Here the compensation is
computed synchronously after a forced tile in the same tick (hit or miss both
yield real heights), so there is no window for the world to change underneath
it — nothing to guard, nothing to discard.

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
        make shell → addSubview → layoutSubtreeIfNeeded (settle width)
        → bindData → render current blocks (warm = full / COLD = EMPTY) → scrollToTail
        → trigger(width): start the iterator off-main
        → scrollerHidden = true (pipeline loading)
        [beforeWaiting] single tile @ settled width, draw, commit
        ── cold: this tick shows NO content; the gap (attach → first deposit) is
           covered by blank or a baked image of the pre-switch frame — never a
           loading affordance. warm: full content already present, no gap. ──

TICK k  [source]  CONTENT: first deposit drained (cold first screen)
        off-main deposited the tail page → drain woken
        → apply(.insert / .prepend, tail)   (anchored to tail)
        [beforeWaiting] insert, tile, draw — first content appears

TICK k+1..N  [source]  CONTENT: backfill drain — one apply per tick
        drain ≤ budget pre-built blocks from the main-owned buffer
        → apply(.prepend, batch)   (anchor-preserving; §5 recipe)
        [beforeWaiting] insert above; viewport fixed; off-screen rows realize no cells

TICK last  iterator exhausted (file top reached, orphans flushed) + buffer drained
        → flush pending live events (§7)
        → pipeline idle → scrollerHidden recomputed false → fade in
```

Warm re-entry collapses to TICK 1 alone — content is already in the coordinator
from the continuous bridge, and `loadHistory` is an idempotent no-op, so there
are no CONTENT ticks. The multi-tick CONTENT sequence is the cold-open path.

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
- `setHistory` entirely (four-concern fusion + two-phase split) + the bridge's
  two reset paths (`.reset` / `.prepended` handlers, `didLoadInitial` branch) +
  `applyAppend`'s `setHistory(seed)` race patch + the zero-width branch — §4.6.
- The free-form `apply(scroll:)` parameter — intent is per-case now — §4.6.
- `scrollerHiddenCount` + `pushScrollerHidden`/`popScrollerHidden` + the
  `precondition` + `didPushForLiveResize` + the `flashScrollers` override — §8.
- `applyInBackground`'s "completion fires exactly once" contract — its only job
  was balancing push/pop across the hop — §8.
- The `mutationCounter` anchor guard — it only existed to police a *deferred*
  anchor compensation; the new in-tick recipe never defers, so there is nothing
  to guard — §5.
- The scattered `layoutWidth == width` validate gates — not "collapsed into one
  guard" but **removed**: width correctness falls out of the width-keyed cache
  by construction, so no validate gate remains. The width survives only as the
  cache entry's existing tag plus a one-call `iterator.retarget(width)` — §4.3/§4.4.

---

## 11. Open questions (to settle before coding)

**Resolved**
- ~~Iterator API surface: pull vs push.~~ → §4.5: **off-main produces and
  deposits into a main-owned buffer; main drains.** No polling, no shared
  mutable buffer, no lock. Cold first tick is empty by design; the gap is
  covered by blank / pre-switch image bake, never a loading affordance.
- ~~Width snapshot/validate/generation.~~ → §4.3/§4.4: removed; width self-heals
  through the width-keyed cache. Only action is `retarget`, and not during live
  resize (§4.4).
- ~~`apply` change vocabulary; is `.prepend` first-class; delete `setHistory`?~~ →
  §4.6: `setHistory` deleted; vocabulary = `.prepend` / `.append` / `.replace` /
  `.remove` / `.update`, each with intrinsic scroll intent and intrinsic position;
  no anchored `.insert(after:)` (the segment swap is the explicit `.replace`);
  `scroll:` shrinks to per-case intent; bridge load path collapses.

**Still open**
- Where the pipeline `isLoading` flag and the derived `scrollerHidden` live
  (controller vs coordinator).
- Cold-gap cover: blank vs pre-switch frame image bake — pick one (UX).
- Test net: which merge-gate tests assert the anchor invariant and the
  single-width typeset contract under the new pipeline.
