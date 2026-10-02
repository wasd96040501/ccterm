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
    ● date-fns
      Small, tree-shakeable
    ○ Moment
      Familiar, but large and in maintenance mode
    ○ Other — type something
    [Submit ⌘↩]  Chat About This
```

- Leading tile `questionmark.bubble`, the header (`Auth method`) as the title
  in 13-pt secondary, the question in 14-pt label — wrapped, however long.
- **An option is two lines**: its label (13 pt) and, under it, its
  description (12 pt), both wrapped, never cut — an option's description is
  often a sentence, and side by side it either truncates or pushes the
  label's column wide. The mark (radio, or checkbox for `multiSelect`) sits
  on the label's line; a live option's hover covers both lines.
- Answered: the chosen ones with a filled mark, label colour and secondary
  description; the others hollow and tertiary. A multi-select question says
  *Choose any* after its header.
- **Several questions** (up to four) stack in one card, 12 pt apart, with one
  Submit: a form shows every field at once. (The CLI's terminal UI pages
  through them with tabs and a review step, because it has one screen.)
- **The answers the CLI adds** to the model's options, as its own question
  UI does:
  - **Other** — always last in each question: a row whose label is a text
    field (*Other — type something*). Choosing it focuses the field; what's
    typed is the answer. Answered, it shows as the chosen option with
    *Other* as its description.
  - **Chat About This** — a plain button beside Submit. It answers nothing:
    ccterm denies the question with the CLI's own feedback (*The user wants to
    clarify these questions … Start by asking them what they would like to
    clarify*, with what was asked and any answers so far), and the focus goes
    to the composer. The card then reads *Not answered — talked over in the
    conversation*.
  - An option with a `preview` (single-select) shows the preview beside the
    list, monospaced, as the CLI does, with a *Notes* field whose text goes
    back as *User notes*.
- **Live**, waiting for the answer: the tile has the coral outline, and
  **Submit** (⌘↩) is enabled once every question has an answer — the same
  "waiting for you" as a permission card. ⎋ declines (*User declined to
  answer questions*).

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
