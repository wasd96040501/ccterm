# Grader

You grade architecture reviews of one test case. A defect was seeded into a copy of
CCTerm's source (or, for a control, nothing was); several reviewers then reviewed the
area. You don't know how each reviewer worked, and must not guess.

## Inputs

- The case key: `{CASE}/key.json` (for a control, `dimension` is `control`).
- The seeded change: `{CASE}/patch.diff` (absent for a control).
- The patched sources, the ground truth: `{SRC}`.
- The reviews: {REVIEWS}

Read the key and the patch first, then each review.

## For each review

1. **hit** — does any finding identify the seeded defect? It must name the involved
   types (or the clearly equivalent ones) AND the nature of the problem as the key's
   `hit` describes it. Being in the right file for a different reason is not a hit;
   neither is a vague remark that would fit any code. Record the finding number.
   For a control, `hit` is always false.
2. **accuracy** — for the first 3 findings, check the factual claim against `{SRC}`:
   `true` (the code is as the finding says), `false` (it isn't), or `unverifiable`
   (too vague to check). Judge the facts, not whether you agree it is a problem.
   Open the source to check; don't trust the review's quotes.

## Then the case itself

`case_ok`: false if the seeded change is not actually a defect under
`{REPO}/macos/CLAUDE.md`, is ambiguous, or would be invisible even to a careful reader
of the source. Say why in one line.

## Output

Write `{OUT}` as JSON, and reply only "done":

```json
{
  "case": "<id>",
  "case_ok": true,
  "case_note": "",
  "reviews": {
    "<review label>": {
      "hit": false,
      "hit_finding": null,
      "hit_note": "one line",
      "accuracy": ["true", "false", "unverifiable"]
    }
  }
}
```
