# Transcript load & scroll — refactor plan

> ⚠️ **DO NOT MERGE INTO `main`. Delete this file before the PR lands.**
> Working scratch for the upcoming refactor — the single planning doc.
> It is the *how* / technical plan and has absorbed the *why* /
> conclusions that previously lived in a companion consensus note.
> Remove before squash-merge.

---

## 1. Background

A session switch can hard-crash on `Transcript2ScrollView.popScrollerHidden()`'s
release `precondition`. Root cause: the scroller-hidden
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
| **Scroller visibility** | — | **deleted** | No custom control at all; AppKit default autohide (§8). The whole refcount mechanism is removed. |
| **Loading state** | `SessionRuntime.historyLoadState` | **existing** | Derived `isLoading`, never a new flag; likely near-zero consumers after the scroller is gone (§8a). |
| **Live/load merge** | none by default — live flows straight through `apply` | (no machinery) | Head-prepend vs tail-append don't conflict; no queue (§7). |

The recurring theme: **layout-vs-width, visible-resize, and loading state are
already solved by existing machinery**; the new code only adds the off-main
builder, the in-tick prepend recipe, and a one-call `retarget`. Scroller control
and the pending-merge queue are *removed*, not rebuilt.

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
- **Covering the cold gap: blank.** The surface is simply empty until the first
  deposit lands — no spinner, no placeholder, no pre-switch image bake. (Decided.)

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
        [beforeWaiting] single tile @ settled width, draw, commit
        ── cold: this tick shows NO content; the gap (attach → first deposit) is
           simply blank — no loading affordance, no image bake.
           warm: full content already present, no gap. ──

TICK k  [source]  CONTENT: first deposit drained (cold first screen)
        off-main deposited the tail page → drain woken
        → apply(.insert / .prepend, tail)   (anchored to tail)
        [beforeWaiting] insert, tile, draw — first content appears

TICK k+1..N  [source]  CONTENT: backfill drain — one apply per tick
        drain ≤ budget pre-built blocks from the main-owned buffer
        → apply(.prepend, batch)   (anchor-preserving; §5 recipe)
        [beforeWaiting] insert above; viewport fixed; off-screen rows realize no cells

TICK last  iterator exhausted (file top reached, orphans flushed) + buffer drained
        → historyLoadState = .loaded   (the only "done" signal; see §8a)
```

Warm re-entry collapses to TICK 1 alone — content is already in the coordinator
from the continuous bridge, and `loadHistory` is an idempotent no-op, so there
are no CONTENT ticks. The multi-tick CONTENT sequence is the cold-open path.

---

## 7. Live merge — probably nothing to do

Backfill prepends at the **head**; live CLI events append/update at the **tail**.
Opposite ends — positionally non-conflicting. So the default position is: **live
events flow straight through `apply` during backfill, no queue.** A live
`.append` lands at the tail (where the user is) while the iterator keeps
prepending older history above; neither disturbs the other (§5 anchor recipe
holds for both independently).

The only events that *could* conflict are a live `.update` / `.replace` /
`.remove` targeting an entry the iterator is **still building** — but the
iterator builds *older* history (above), while live mutations target *recent*
entries (already present at the tail), so in practice they don't overlap. If a
real overlap is ever found, the narrow fix is to queue *those specific* events
keyed by entry id until the iterator passes that id — not a blanket
"queue everything while loading" gate.

No global busy `flag` is needed for this (see §8a). End of load is just
`historyLoadState = .loaded` when the iterator exhausts.

---

## 8. Scroller — the whole hide mechanism is deleted

There is **no custom scroller-visibility control**. The overlay scroller follows
AppKit's default `autohidesScrollers` behavior; nothing in this codebase hides,
fades, push/pops, or flash-suppresses it.

Deleted in full: `scrollerHiddenCount`, `pushScrollerHidden` /
`popScrollerHidden`, the `precondition`, `didPushForLiveResize`, the
`flashScrollers()` override — and, since there are no longer two producers to
coordinate, `applyInBackground`'s "completion fires exactly once" balancing
contract. The crash class disappears because the mechanism it guarded is gone,
not because the guard was softened.

**Accepted tradeoff:** while backfilling, the document's true top/total height is
provisional, so the overlay thumb may flash or jump as content grows. Judged not
worth any machinery. If it ever reads as ugly, the cheapest mitigation is tuning
AppKit's autohide, never reintroducing a refcount.

### 8a. Loading state (`isLoading`) — not new state

"Is history still loading" is a **data-pipeline fact**, session-scoped, surviving
view mount/dismount. It **already exists** as `SessionRuntime.historyLoadState`
(`@Observable`, forwarded through `Session`). The iterator is its new mechanism:
on exhaustion it sets `.loaded`. So:

- **Do not add an `isLoading` flag on the controller/coordinator.** That would be
  a shadow copy of state that already lives at the right layer (violates the
  Session-layer "no shadow state" rule) and couples render-side to load progress.
  `isLoading ≡ historyLoadState ∉ {.loaded, .failed}`, derived.
- The drain loop's "buffer not yet empty" stays a **controller-local** condition,
  never promoted to shared state.
- **With the scroller gone, re-examine who even reads it.** The cold-gap cover
  keys off *"first content applied"* (`controller.blockCount > 0`), not
  `isLoading`. The §7 pending gate is likely unnecessary (see §7). The honest
  expectation: after this refactor `isLoading` has near-zero consumers — so the
  right move is to derive it where needed, not to maintain it anywhere.

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
- ~~Scroller visibility owner / `isLoading` location.~~ → §8/§8a: scroller hide
  **deleted entirely** (AppKit default autohide); `isLoading` is **not** new
  state — derive from `SessionRuntime.historyLoadState`, and expect near-zero
  consumers after the scroller is gone.
- ~~Live/load merge (pending queue).~~ → §7: no queue by default; live flows
  straight through `apply` (head-prepend vs tail-append don't conflict).
- ~~Cold-gap cover.~~ → blank surface until first deposit; no affordance, no bake (§4.5/§6).
- ~~Test net: which merge-gate tests assert the anchor invariant and the
  single-width typeset contract under the new pipeline.~~ → §12: three tiers
  matching the existing suite shape — pure-logic (no UI), offscreen-UI
  measurement probes (merge gate, no `Snapshot` suffix), and opt-in snapshots.
  The anchor invariant and single-width contract are Tier-2 probes (U1/U2/U3);
  reverse pairing + drain timing are Tier-1 logic (A/B groups).

**Still open**
- *(none — all resolved; §12 closes the test-net question.)*

---

## 12. Test net

The suite already has the right three-tier shape; the new pipeline slots into
it without inventing a fourth kind. (See `cctermTests/CLAUDE.md`.)

| Tier | Kind | Runs on | Models the |
|---|---|---|---|
| **1** | pure-logic, no UI | default `make test-unit` (merge gate) | reverse builder + tool-pairing, drain/deposit **timing**, `apply` data half, derived `isLoading` |
| **2** | offscreen-UI **measurement probe** (mounted table, assert on geometry; **no `Snapshot` suffix**) | default `make test-unit` (merge gate) | single-width typeset contract, anchor invariant, block↔row alignment, cold-empty first tick |
| **3** | snapshot PNG (`*SnapshotTests.swift`) | opt-in only, never CI | visual review of the cold-gap blank + backfill frames |

The two questions §11 named — **anchor invariant** and **single-width typeset
contract** — are Tier-2 probes (`U1`/`U2`/`U3`), built on the *exact* harness
`TranscriptReentryLayoutCacheTests` / `TranscriptScrollFirstFrameSnapshotTests`
already use: an offscreen `alphaValue=0.01` window, the
`onLayoutCacheWriteForDebug` write trace, and `clip.bounds.origin.y` /
`rect(ofRow:)` sampling. **The new pipeline adds the multi-tick backfill
dimension those tests don't exercise** (they stop at re-entry, where blocks are
already present); §12.2 extends them across the prepend sequence.

### 12.1 Tier 1 — pure-logic (no UI)

Three groups. **Group A is fully synchronous** (the extracted pure builder, fed
canned reverse-ordered input — no async, no actor hop), so it is the cheapest
and most deterministic place to pin tool-pairing. **Group B drives the real
async deposit→drain lifecycle** and is the "timing scenario" net the brief asks
for — synchronized with `XCTestExpectation` / awaiting `historyLoadState`,
**never `Task.sleep`** (suite rule #6). **Group C** covers the `apply` data half
and derived state (no table needed — `coordinator.blocks` is the SoT).

#### Group A — reverse builder + tool-pairing (sync)

Lives next to `MessageEntryBlockBuilderTests` / `HistoryLoaderTests`. Suggested
class `TranscriptReverseBuilderTests`.

| # | Scenario | Assertion | Why it's a boundary/core case |
|---|---|---|---|
| A1 | bottom-up read of a clean file (tool_use above its tool_result, interleaved text) | emitted blocks, head-to-tail across all pages, equal **document order** | core — the whole "show before fully read" correctness claim (§4.2) |
| A2 | a `tool_result` read before its `tool_use` | result is **withheld** (not emitted) until the `tool_use` is reached; then one **complete paired block** emitted at the tool_use's position | core — the withhold-buffer mechanic |
| A3 | a `tool_result` whose `tool_use` is absent from the entire file (truncation/compaction) | on file-top, the orphan is flushed **best-effort, exactly once** (result-only/unknown-tool card) | boundary — true-orphan flush (§4.2) |
| A4 | a tool pair split across a page boundary (result on the lower page, use on the next page up) | pairing still completes; withhold-buffer **spans page boundaries** | boundary — proves paging is decoupled from emission |
| A5 | any load-path input | **no `.update` change is ever emitted** — load blocks are born complete; only `.prepend`/`.append` | core — the "no `.updated` on load" split (§4.2) |
| A6 | the same JSONL fed to the new builder and to today's `SessionRuntime.receive` grouping | grouped/tool-paired **entries match** | extraction guard — proves `buildEntries`' throwaway `SessionRuntime` (§4.1) was replaced 1:1, not approximated |

#### Group B — deposit→drain lifecycle (async, expectation-driven)

Suggested class `TranscriptBackfillPipelineTests`. Driven through a **fake page
source** (see §12.3) yielding canned `Sendable` pages so order/timing is
controlled, plus the real main-owned buffer + drain.

| # | Scenario | Assertion |
|---|---|---|
| B1 | cold attach, **nothing deposited yet** | the first drain produces **no content** — `blockCount == 0` until the first deposit lands (§4.5 "first tick on a cold open is empty") |
| B2 | N pages deposited | drain fires **only after a deposit** — drain invocations ≤ deposits, **never an empty-buffer drain** ("the deposit *is* the wake") |
| B3 | pages deposited tail-first then older (reverse-read order) | after full drain the coordinator's block order is **document order** (tail page at the bottom, each older page prepended above) |
| B4 | one giant buffer deposited at once | each drain tick applies **≤ budget K** rows (§9.2); the buffer drains over multiple self-rescheduled ticks |
| B5 | iterator reaches file top + buffer empties | `historyLoadState` transitions to `.loaded` **exactly once**; no further drain ticks |
| B6 | empty history (no entries) | `.loaded` immediately, **zero** content applied, no crash |
| B7 | interleaved deposits during an in-flight drain | pages land in deposit order; **no lost/duplicated/reordered** page (guards the "main-owned buffer, no lock" claim — §4.5) |

#### Group C — `apply` vocabulary + derived state (no UI)

Suggested class `TranscriptApplyVocabularyTests`. `apply` with no table bound
mutates `coordinator.blocks` directly (same as today's `setHistory`-with-no-table
path), so the data half is testable headless.

| # | Scenario | Assertion |
|---|---|---|
| C1 | `.prepend(batch)` | inserted at index 0, prior blocks shifted, order preserved |
| C2 | `.append(batch)` | inserted at tail |
| C3 | `.replace(oldIds:with:)` on a **contiguous** range | `newBlocks` swapped in at the same start index, **atomically** (resulting array exact); count delta = `newBlocks − oldIds` |
| C4 | `.replace(oldIds: [], with:)` (degenerate) | routes to `.append`, **not** an in-place swap (§4.6) |
| C5 | `.remove(ids)` | rows gone; the per-id cache/selection/highlight/fold/status eviction still fires |
| C6 | `.update(id, kind)` | same-id replacement in place, index stable |
| C7 | drive `historyLoadState` through its states | `isLoading == (state ∉ {.loaded, .failed})`, **derived** — assert there is **no stored `isLoading`/busy field** on controller or coordinator (§8a) |
| C8 | mutate blocks only via `apply` across a mixed sequence | `setHistory` is gone; **no second mutation path** reaches `blocks` (regression guard for §10's deletions) |

### 12.2 Tier 2 — offscreen-UI measurement probes (merge gate)

Mounted real `NSTableView` offscreen, assert on AppKit geometry. **No
`Snapshot` filename suffix** (so `scripts/test-unit.sh` keeps them in the
default suite) — these are the merge gates §11 asked for. Reuse the existing
scaffold verbatim: offscreen window, `onLayoutCacheWriteForDebug` write trace,
`drainMainLoop`, the `Write{ id, width, stage }` grouping helper.

Suggested classes: `TranscriptBackfillLayoutCacheTests` (U1), `TranscriptBackfillAnchorTests` (U2/U3/U7/U8), `TranscriptColdAttachTests` (U4/U5/U6).

| # | Scenario | Assertion | Maps to |
|---|---|---|---|
| **U1** | cold backfill: tail page lands, then ≥3 `.prepend(batch)` ticks, each its own source phase | **per tick, every block id is typeset at exactly one width** (the off-main width); because off-main precomputed at the current width, a prepend tick should be **cache-hits — ideally zero new typeset writes** at a third/fourth width | single-width contract (§4.3, §5) — the multi-tick extension of `TranscriptReentryLayoutCacheTests` |
| **U2** | after scrollToTail on the first screen, capture the visual-top row's `rect(ofRow:)`/clip origin; apply `.prepend(batch)`; re-measure **in the same tick** | the anchor row's on-screen position is **unchanged** — clip origin shifted down by **exactly the inserted batch's measured height** (within ~1pt); repeat over N ticks, anchor stays pinned, **no jitter** | anchor invariant (§5) — the core viewport-stability claim |
| **U3** | immediately after `apply(.prepend)`, **before any runloop drain** | `rect(ofRow:)` already returns **real** heights (forced tile in-tick) and the clip origin already reflects compensation — **no "next tick fixes it"**; falsifies any deferred-compensation regression (the deleted `mutationCounter` path) | in-tick stability (§5) |
| **U4** | attach a **cold** (never-loaded) session | TICK 1: `numberOfRows == 0`, surface blank, no spinner/placeholder; then drain the first deposit → tail content appears at the bottom | cold-empty first tick (§4.5/§6) |
| **U5** | a mixed sequence (`prepend`/`append`/`replace`/`remove`/`update`) | after **every** tick `coordinator.blocks.count == tableView.numberOfRows`, index-for-index | block↔row alignment invariant (§5) |
| **U6** | **warm** re-entry into a populated session | attach collapses to **TICK 1 alone** — **zero** CONTENT `.prepend` ticks fire, `loadHistory` is an idempotent no-op (probe sees no backfill writes) | warm path (§6) — extends the existing reentry gate to assert the *absence* of backfill |
| **U7** | `.update(id, kind)` (the ~95% tool_result merge) and `.replace` (segment swap) on an off-tail row while scrolled mid-document | viewport preserved — `noteHeightOfRows` with the anchor fixed; visible content does not jump | per-case scroll intent (§4.6) |
| **U8** | live `.append` at the tail **while** backfill `.prepend` ticks run at the head | both land; tail append sticks to bottom (if at bottom), head prepend preserves viewport; **neither disturbs the other** | live/load non-conflict (§7) |

**Boundary probes (same tier, lower priority — add if cheap):**

| # | Scenario | Assertion | Maps to |
|---|---|---|---|
| U9 | change row width mid-backfill (within the `[460,780]` clamp band) | pages built at the **old** width install as-is → `heightOfRow` **miss** → recompute at the new width on scroll-in (**self-healing**); future pages built at the new width after one `retarget` | resize self-heal (§4.4) — assert via the width trace that a stale-width entry never corrupts, only re-typesets |
| U10 | a single block whose own layout exceeds the budget (giant code block) | lands in **one** tick — the budget caps a batch, **never splits a block** | oversized-block exception (§9.3) |

### 12.3 Test seams the design must expose (no test-only hacks)

Per the engineering principle "never compromise production code to make tests
pass," every seam below is **real product surface / dependency injection**, not
a `forceXxxForTest()` :

- **Injectable page source on the iterator** — the reverse pager takes a
  reader abstraction by initializer. Production wires the JSONL file reader (the
  existing `loadHistory(overrideURL:)` shape — already used by
  `HistoryLoaderTests`); Group B injects a fake that yields canned `Sendable`
  pages on demand. This is legitimate DI, the same way `SessionManager` takes a
  `cliClientFactory`.
- **`onLayoutCacheWriteForDebug`** — the existing read-only `(id, width)` write
  probe. Carry it forward unchanged; it observes, it does not gate behavior.
- **`historyLoadState`** is already `@Observable` and forwarded through
  `Session` — Group B/U-tests **await it** rather than sleeping.
- **The pure builder is a free/`static` function** (the §4.1 extraction) — Group
  A calls it directly with no runtime, no CoreData, no actor.
- **Drain is driven by real deposits** — tests deposit a page (through the fake
  source) and `await`/drain the runloop; there is **no** "force a drain" method.

### 12.4 Explicitly NOT a gate

- **Scroller deletion (§8)** has nothing to assert at runtime — the mechanism is
  *gone*, so the test is the *absence* of the symbol (compile-time) plus the
  crash class disappearing. Do **not** add a runtime test that re-creates a
  scroller-state observer just to assert it; that would resurrect the coupling
  the refactor deletes. If anything, a one-line check that the bound scroll view
  keeps AppKit's default `autohidesScrollers` is sufficient, and even that is
  optional.
- **The cold-gap blank** is a Tier-3 snapshot (opt-in PNG) for human review, not
  a merge gate — there is no pixel to assert beyond "empty," already covered by
  U4's `numberOfRows == 0`.
