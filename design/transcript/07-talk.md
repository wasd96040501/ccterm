# 7 · Tools that talk to you

A few tool calls are addressed to the reader, not to the machine. Folding
them into a run would hide the one thing in it the user was asked about.
Rare (< 3 % of calls together), so these are small, exact designs.

## AskUserQuestion — breaks out of the run

The question was the user's to answer; the transcript keeps question and
answer together, like a form that was filled in.

```
 ?  Auth method
    Which library should we use for date formatting?
    ● date-fns          Small, tree-shakeable
    ○ Moment
```

- Leading tile `questionmark.bubble`, the header (`Auth method`) as the title
  in 13-pt secondary, the question in 14-pt label.
- Options as a list: the chosen ones with a filled mark and label-colour text,
  the others hollow and tertiary; descriptions in 12-pt tertiary. Several
  questions stack with 12 pt between them.
- **Live**, waiting for the answer: the options are live controls (radio or
  checkbox per `multiSelect`), the tile has the coral outline, and **Submit**
  (⌘↩) sits under them — the same "waiting for you" as a permission card.

## ExitPlanMode — breaks out of the run

A plan is a document the user approves, addressed to the user — so it gets the
page, like a reply. Two rows:

```
 ▤  Plan
 1. Split EditorGroupViewController's tab bar …
 2. …                                                    (the whole plan)
```

- A **caption row** (the plan tile, *Plan*), then the plan as a `.markdown`
  row: TranscriptKit renders it whole — headings, lists, code — exactly as it
  renders a reply. No card of its own, no cut: there is nothing a card would
  add that the markdown renderer doesn't already do.
- **Live**, waiting: the tile has the coral outline, the caption reads
  *Plan · Waiting for your approval*, and **Keep Planning** / **Approve** (⌘↩)
  sit under the plan.

## Task list — stays in the run

`TaskCreate`, `TaskUpdate`, `TodoWrite` are bookkeeping; the run says
*Updated the task list*. The item opens a **checklist document**: the whole
list as it stood after that call — done items struck through in tertiary,
the one in progress with the arc tile, the rest hollow — so stepping through
task items with ↓ plays the plan's progress forward.
