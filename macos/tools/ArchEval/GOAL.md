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
