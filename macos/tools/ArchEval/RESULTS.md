# ArchEval — results of iteration 1

Baseline: ArchMap at `55b1c141`. v1: the iteration-1 commit (binder `keeps`, edge kinds,
static geometry in B1, Placement). Counts are hits / reviews; see GOAL.md for the rules.

## Dev (9 seeds, readable while building — direction only)

| arm | hits | tree | layout | data | top-3 true/false |
|---|---|---|---|---|---|
| baseline core3 (28 KB) | 7/16 | 5/6 | 2/6 | 0/4 | 39/27 |
| v1 core3 (30 KB) | 13/16 | 6/6 | 4/6 | 3/4 | 58/8 |
| baseline full (247 KB) | 5/8 | 3/3 | 2/3 | 0/2 | 28/5 |
| v1 full (246 KB) | 7/8 | 3/3 | 2/3 | 2/2 | 31/2 |
| source | 8/8 | 3/3 | 3/3 | 2/2 | 30/0 |

## Holdout (6 seeds + 1 control, never read; one review per arm)

| arm | hits | tree | layout | data | top-3 true/false |
|---|---|---|---|---|---|
| baseline full (247 KB) | 3/6 | 2/2 | 0/2 | 1/2 | 16/5 |
| v1 core3 (30 KB) | 4/6 | 2/2 | 0/2 | 2/2 | 18/3 |

The source arm was cut short to save tokens (2 of 6 seeds reviewed, both found), so the
holdout is uncalibrated: all six seeds count.

## Verdict against GOAL.md

- Recall: 4/6 vs 3/6 — one case, so **no measurable change** by the two-case rule.
  The success bar is not met.
- Precision: 18/3 vs 16/5 — not worse.
- Size: the deciding map is 30 KB against 247 KB; the v1 full map is 246 KB.
- The one consistent signal across dev and holdout: data defects (binder state) went
  from 0/4 and 1/2 to 3/4 and 2/2 — the `keeps` lines.
- Layout stays the blind spot: 0/2 on holdout for both maps. Placement showed no
  measurable effect on any seed; cutting it is the default unless it earns its place.

## Iteration 2 — reading in levels, lifecycle (4 fresh seeds, one review per arm)

| arm | hits | tree | layout | data | top-3 true/false | tokens per review (mean) |
|---|---|---|---|---|---|---|
| v1 core3 (30 KB) | 3/4 | 1/1 | 1/2 | 1/1 | 11/1 | 81k |
| v2 in levels (33 KB core, units on demand) | 4/4 | 1/1 | 2/2 | 1/1 | 12/0 | 118k |
| source | 4/4 | 1/1 | 2/2 | 1/1 | 12/0 | 156k |

- One case apart, so by the two-case rule **no measurable change** on recall. The case
  that differs is a size-before-content break (`viewWillAppear` reads the bounds): v1 had
  no way to see it; v2 named it from rule C1. That is the blind spot iteration 1 left.
- v2 matched source on these four seeds at about three quarters of source's tokens; v1
  core3 is the cheapest and missed the lifecycle case.
- Caveat: the author prompt has always listed "size-dependent work run before the view is
  laid out" among its layout examples, so a lifecycle seed was likely; four seeds is small.
