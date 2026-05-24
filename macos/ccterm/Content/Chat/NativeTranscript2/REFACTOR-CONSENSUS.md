# Transcript load & scroll — refactor consensus

> ⚠️ **DO NOT MERGE INTO `main`. Delete this file before the PR lands.**
> Working scratch — a shared consensus to anchor the upcoming refactor, not a
> permanent doc. It must not survive in `main`; remove it before squash-merge.

**Status: consensus only. No plan, no file-level steps yet.** This records
*what we agree is wrong* and *what the target shape is, in principle*. The
concrete plan (new types, migration order, test net) is a deliberate
follow-up — do not read implementation steps into this doc.

Scope: the machinery behind "switch to a session → show its history →
keep the viewport stable", spanning two areas:

- `Services/Session/Session/SessionRuntime+History.swift` — history load (Phase A/B).
- `Content/Chat/NativeTranscript2/` — `setHistory` (Phase 1/2), `apply`,
  scroll anchoring, scroller visibility, attach (`TranscriptDetailViewController`).

---

## 0. Trigger

A session switch hard-crashes with `EXC_BREAKPOINT`:

```
Transcript2ScrollView.popScrollerHidden()  → precondition(scrollerHiddenCount > 0) failed
Transcript2Coordinator.popScrollerHidden()
Transcript2TableView.viewDidEndLiveResize()
-[NSWindow _endLiveResize]   (window-manager spring resize)
```

At crash time three things overlapped on one runloop tick: a window-manager
resize animation ending, a session cold-loading (Phase A `parseTail` on a
worker thread), and a session booting (`Session.start`).

---

## 1. Crash root cause

`scrollerHiddenCount` is a manual push/pop refcount that:

- **lives on the `Transcript2ScrollView` instance** — which is destroyed and
  recreated on every session switch (`factory.dismantle` + `factory.make`);
- is **late-resolved** through the mutable `coordinator.tableView?.enclosingScrollView`,
  so a `pop` targets whatever scroll view is current *when it runs*, not the
  one the matching `push` targeted;
- is written by **three independent, partly-async producers**:
  1. live-resize — `Transcript2TableView.viewWillStartLiveResize` / `viewDidEndLiveResize`;
  2. cold-load — `setHistory` push at the top, pop in the `applyInBackground` completion (async);
  3. post-resize prefetch — `refillLayoutCache` push, pop in a detached task's `defer` (async).

Because push and its matching pop can land on **different scroll-view
instances** (one timeline's deferred pop fires after the view was swapped),
some instance's count goes to 0/negative, and the next legitimate pop trips
the `precondition`. The per-table `didPushForLiveResize` flag only patches one
narrow per-table imbalance; it cannot fix push/pop crossing instances.

---

## 2. Essence (one line)

> Whether the scroller is hidden is a **session-level** fact ("is this
> transcript's content geometry in flux?"), but it is implemented as a
> **manually-paired refcount stored on a throwaway view instance,
> late-resolved through a mutable pointer, written by three uncoordinated
> async producers** — the state's ownership and lifetime are mismatched, so
> the bookkeeping cannot survive view recreation.

---

## 3. Accidental complexity that must not survive the refactor

Each item exists only to compensate for a design mismatch; in the target
shape it has nothing to compensate for and disappears.

### 3a. "tail-first, prefix-later" stitch-up
- `ToolResultReresolver` as a **subsystem** (tool_use index + `applyResolution`
  + `.updated` re-fan-out).
- `buildEntries` spinning up a **throwaway in-memory `SessionRuntime` +
  CoreData stack** just to borrow `receive()`'s Message2→MessageEntry
  conversion ("shadow handle — too heavy", per its own comment).
- The `tailBaseline / newTailStart / absoluteTailEnd / tailMessagesAsArray`
  absolute-offset arithmetic — bookkeeping for "where did the tail move after
  prepend".

### 3b. `setHistory` fuses four concerns into one method
- declare contents · first-screen fast path · scroll anchoring · scroller visibility.
- Knock-on: the bridge's two reset paths (`didLoadInitial` branch — first reset
  → `setHistory` two-phase, re-fire → remove-all + insert); `applyAppend`'s
  `if !didLoadInitial { setHistory(seed) }` race patch; `setHistory`'s
  zero-width branch (it degrades to "just stuff blocks in" when there is no
  geometry — proof half its job is view-only); the defensive remove-existing +
  `blockIds != …` idempotency short-circuit.

### 3c. scroller refcount and its derived contracts
- the refcount itself (§1);
- `didPushForLiveResize` per-table flag;
- `flashScrollers()` no-op override (fighting AppKit's auto-flash);
- `applyInBackground`'s "completion fires exactly once in every outcome"
  contract — its only purpose is to balance push/pop across the async hop.

### 3d. generation guards from having >1 mutation channel
- `mutationCounter` drift guard, highlight `inflightGen` — same shape: "I
  launched async work, the world may have changed, discard on drift." Rooted in
  three mutation paths (sync `apply`, fire-and-forget `applyInBackground`,
  `refillLayoutCache`) racing deferred `noteHeightOfRows` on one table.

---

## 4. Target principles (consensus, not plan)

1. **One source of truth** — `Transcript2Coordinator.blocks`.
2. **One ordered write entry** — `apply(changes)`, `@MainActor`.
3. **`apply` = data mutation + table structural notify, atomic, in one tick.**
   `blocks` change ⟺ `insertRows`/`removeRows`/`noteHeightOfRows` in the *same*
   source phase. Pixels are **pulled** by NSTableView in `beforeWaiting`
   (`heightOfRow` / `viewFor` ← layout cache). `apply` pushes no pixels and
   draws nothing; it only marks which rows are dirty.
4. **Two independent producers, each only ever calls `apply`:**
   - *content pipeline* (history loader + live CLI) — emits block changes
     only; **never** touches scroll or scroller.
   - *view lifecycle* (attach / resize / dismantle) — owns geometry, scroll
     position, anchoring; **reads** `blocks`, never writes them.
5. **Scroll-anchor intent rides with the change, semantically** — a prepend
   means "preserve the viewport"; a tail append means "stick to bottom". This
   coupling is correct and stays.
6. **Scroller visibility is derived, not pushed** —
   `scrollerHidden = f(contentPipeline.isLoading, view.inLiveResize)`. Owned at
   session/coordinator lifetime, recomputed when its inputs change, applied to
   the *currently bound* scroll view (re-applied on rebind). No counter, no
   push/pop, no cross-instance hazard.

---

## 5. Scroll-stability consensus

> **Within any single source-phase tick, scroll can be made stable — iff, in
> that same tick and before computing the scroll target, every row geometry
> the target depends on has been settled synchronously.**

In-tick order, all synchronous (no cross-hop, no "next tick will fix it"):

```
[one source phase]
  1. blocks change + insertRows/removeRows      (data ⟺ structure, atomic)
  2. tableView.layoutSubtreeIfNeeded()          (force tile NOW → rect(ofRow:) is real)
  3. compute target origin from real rects
  4. clip.scroll(to:) + reflectScrolledClipView
  ── 1–4 wrapped in CATransaction.setDisableActions(true) + allowsImplicitAnimation=false ──
        ▼
[beforeWaiting] flushes exactly ONE composite: rows at true heights, clip at right origin. No intermediate frame.
```

Preconditions that make step 2 cheap and correct: the target-relevant rows'
layouts are **already cached at the final width** (so the tile is all
cache-hits, not a typeset storm). NSTableView queries `heightOfRow` for every
row during tile to know total document height; uncached rows either typeset
in-tick (correct but costly) or — the failure mode — get a target computed
before they settle (one wrong frame).

What destroys single-tick stability: depending on **async-settled** geometry —
reading a rect after a queued `noteHeightOfRows`, splitting one mutation across
two main-hops, or computing a target against wrong-width / missing heights.
Today's `applyInBackground` + `saveVisible` cross-hop pattern is exactly this.

**Multi-tick loads stay stable iff:** every tick is individually stable (above)
**and** non-first ticks only ever *prepend above with anchor preservation* — so
no tick ever produces an intermediate wrong frame and the user sees no jump.
This is what Phase 1/2 should be: a sequence of self-contained stable ticks,
not "render half now, async-patch later, balance with a completion closure".

---

## 6. Tick shape — cold session switch (illustrative)

```
TICK 1  [source]  VIEW: attach — done synchronously in one tick
        make shell → addSubview → layoutSubtreeIfNeeded (settle width)
        → bindData → render current blocks (cold = empty / warm = full) → scrollToTail
        → spawn detached history parse (spawn only, no main work)
        → scrollerHidden = true (pipeline loading)
        [beforeWaiting] single tile @ final width, draw, commit
        ── the view line ends here; it does not know whether history is loading ──

TICK 2  [source]  CONTENT: first screen (tail) — after off-main tail parse, one main hop
        loader → apply(.insert tail)  (still anchored to tail)
        [beforeWaiting] insertRows, tile, draw

TICK 3..N [source]  CONTENT: backfill (older, document order) — one hop per batch
        loader → apply(.prepend, anchor-preserving)
        [beforeWaiting] insert above; viewport stays fixed

TICK last  CONTENT pipeline idle → scrollerHidden recomputed false → fade in (own tick)
```

Live CLI events take the same shape as TICK 2/3 — `apply` then draw. No special path.

---

## 7. The resolver — what actually dies

The **need** to reconcile a tail `tool_result` with a `tool_use` that loads
later is *inherent* to "show the tail before reading the head" — it is not
debt. What is debt is the resolver **as a bespoke subsystem** (raw Message2 +
byte offsets + shadow runtime).

Clean resolution — **define the need away** rather than make it cheap: do not
cut the tail at a fixed line count. Extend the backward scan until the window
is **tool-call-self-consistent** (every `tool_result` in the window has its
`tool_use` in the window; the two are adjacent JSONL lines, so this usually
costs a few extra lines). Then:

- the tail window renders fully correct on first screen — no orphans;
- the prefix becomes a **pure prepend** — zero patch-up;
- `ToolResultReresolver`, the shadow `SessionRuntime`, and the offset math all
  evaporate.

**Fallback** (a pathological gap pushing the safe boundary too far up): degrade
to a single ordinary `.update(entry)`, rebuilt by the *same pure builder* and
applied through the *same `apply`* — a normal update on the one channel, not a
resolver.

---

## 8. Production-safety conclusion

`precondition` (not `assert`) fires in **release** and is fatal. Guarding a
**cosmetic bookkeeping** invariant (scroller visibility — worst real
consequence of imbalance is a scroller flashing for a frame) with a release
`precondition` is the wrong trade: it converts a bookkeeping slip into a hard
crash of the user's daily-driver app. The rule going forward: debug-only
`assert` for the invariant + release-safe clamp/early-return for the value.
Cosmetic state must never `SIGTRAP`.

---

## Out of scope (intentionally deferred to the plan)

New type boundaries, file moves, the content-pipeline API surface, the
`apply` change-set vocabulary, migration order, and the test net. None of that
is decided here.
