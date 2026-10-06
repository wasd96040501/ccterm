# ArchEval — the goal it measures

`make arch` exists for this, in the owner's words:

> 我需要他能用最小的信息量，来反馈 ui 开发中最重要最关键的架构信息。然后这个信息，可以被 ai 很好的利用，发现不合理的组件树，布局依赖链，数据依赖等东西。

So a map is good when an AI that reads only the map finds what is wrong with the UI's
**component tree**, **layout dependency chain** and **data dependencies** — about as
well as one that reads the source — while the map stays small and doesn't mislead.

## What is measured

| Metric | Meaning |
|---|---|
| recall | share of seeded defects a map-only reviewer reports, per dimension |
| precision | share of a reviewer's top findings whose factual claims hold in the source |
| size | bytes of the map the reviewer reads |

A source-only reviewer runs once per case set. It calibrates the cases: a seed it also
misses is too subtle or not a defect, and leaves the set.

## Rules against overfitting

- Cases are written by agents, never by whoever changes ArchMap. The holdout set is
  written by a separate agent that never sees the dev set, and is not read — keys,
  patches or grader prose — until the final run.
- An ArchMap change must extract a dimension across the whole codebase and read
  sensibly on the unpatched tree. A change that only lights up one seeded patch is
  rejected.

## Stop criteria (fixed before the first run)

- At most two ArchMap iterations after the baseline; one holdout run at the end.
- Success: holdout recall on the three dimensions is higher than the baseline map's,
  precision does not drop, and the UI-scope map (`SCOPE=app,Components,DisplayModels`)
  is no larger than the baseline's 247 KB.
- Whatever the result, the report says it plainly; missing the bar is not a reason to
  iterate again.

### Reading the numbers (added after the dev baseline, before any holdout run)

- The sets are small: 9 dev seeds, 6 holdout seeds, two or three per dimension. Every
  number is reported as hits / reviews with the case count beside it, never as a bare
  percentage.
- One case is noise. "Higher" above means the new map hits at least two more holdout
  cases than the baseline map does on the same arms, and no dimension loses a case.
  A one-case difference is reported as "no measurable change".
- Holdout arms, fixed now: baseline map (full) ×1, v1 core3 ×1, source ×1, each seed
  graded blind. One run per arm, for token cost — single-run variance is higher, and the
  two-case rule stands.
- The comparison that decides: v1 core3 (≈30 KB) against baseline full (≈247 KB). core3
  was chosen on dev (13/16 vs full-v1's 7/8) and is the harder test: a smaller map must
  find more.
- A pattern that repeats across cases (the same kind of miss in several seeds) outweighs
  any single rate.

### Iteration 2 (fixed before its cases exist)

- The last iteration GOAL allows. Changes: reading in levels (`index.md` tops the tree with
  counts; units only on demand) and lifecycle (per-controller phases, rule C1).
- Fresh cases: one new author agent writes four (two layout, one data, one component-tree),
  with the same author prompt — it is not told what the map now shows. Never read by the
  developer before grading.
- Arms, one review each: v1 core3, v2 read in levels (core plus units on demand), source.
  The comparison that decides: v2 against v1 core3, by the same two-case rule.
- Cost is measured too: each review's subagent tokens are recorded, so "levels save tokens"
  is a number, not a claim.
