# 1 · The run row

Consecutive tool calls with nothing visible between them become one row. It
covers 62 % of today's rows, so it gets the most care — and the least ink.

## What a reader asks of a stretch of work

Watched live and read later, the questions are the same, in this order:

1. **Is it still going, and is it waiting for me?** — live only.
2. **Did anything go wrong?** — 3.3 % of calls fail; that one must not hide.
3. **What changed?** — files are the lasting outcome of a turn.
4. **What did it do, roughly?** — kinds and counts, not every call.
5. **Show me that one.** — a single output, a single diff.

Questions 1–4 are answered by the collapsed row; 5 is one click. Anything not
answering one of these stays off the row: tool names, ids, timeouts, token
counts, the model's descriptions of every command.

## Where a run begins and ends

- A run is a maximal sequence of `tool_use` blocks on the main thread with no
  visible row between them. Thinking, tool results, synthetic text and the
  local-command caveat are invisible, so they don't break it. Assistant text,
  any user row, a notification or a compaction does.
- **Tools that talk to you break out** of runs (`AskUserQuestion`,
  `ExitPlanMode`): their content is addressed to the reader, so it is
  conversation — see [07-talk.md](07-talk.md).
- An interruption during a tool call doesn't make a row; it becomes that
  call's state (below).

## Anatomy

```
 ┌16┐ 8 ┌──────────────────────── text, 13 pt ──────────────┐   ┌ meta 11 ┐ ┌chev┐
 │▢ │   Edited TranscriptView.swift, ran 3 commands · 1 failed  +12 −3  34s    ›
 └──┘
 └──────────────────────────────── 28 pt ─────────────────────────────────────────┘
```

- **Tile** (16 pt, at x = 0): the kind that best says what the run did — the
  first of *change, create, command, agent, web, search, read, tasks,
  schedule, message, other* present. Live, the kind of the call running now.
- **Summary** (x = 24, 13 pt, secondary): a sentence built from the run.
- **Meta** (trailing, 11 pt, tertiary, monospaced digits): lines added and
  removed when the run changed files; wall time when it is ≥ 10 s (the median
  run is 8 s, so half the rows carry no clock and the ones that do are the
  ones worth noticing).
- **Chevron** (trailing, tertiary): only on runs of two or more. It points
  right; expanded it points down.
- Hover lights the row with the quaternary fill, 6-pt radius, 4 pt past the
  text on each side — the sidebar's hover.

### The sentence

Clauses in a fixed order, each a past-tense verb and a count, joined by
commas, first one capitalised:

| kind | clause |
|---|---|
| change | Edited **A.swift** · Edited **A.swift** and **B.swift** · Edited 3 files |
| create | Created **Foo.swift** · Created 4 files |
| command | Ran a command · Ran 3 commands |
| agent | Ran an agent · Ran 2 agents |
| web | Searched the web · Fetched 2 pages |
| search | Searched for `pattern` · Searched 3 times |
| read | Read **A.swift** · Read 4 files |
| tasks | Updated the task list |
| schedule | Scheduled 2 tasks |
| advisor | Asked the advisor · Asked the advisor 2 times |
| skill | Used the **dataviz** skill · Used 2 skills |
| worktree | Moved into a worktree · Left the worktree |
| message | Messaged **team-lead** · Messaged the team (`to: "*"`) · Sent 3 messages |
| notify | Sent you a notification |
| other | Used computer-use 3 times (MCP: the server's name) |

- **At most three clauses**, then *and 2 more*. Runs have at most two kinds
  of tool at p95 and four at p99; three chunks is what a glance holds.
- **Files are named when there are two or fewer**, and the names are links:
  clicking one opens its diff without expanding the run. Named files are in
  label colour — the nouns a reader scans for; the rest is secondary.
- Edits to the same file count once — the reader asks *which files*, not *how
  many Edit calls* (a file is edited up to 3× in one run at p95).
- **Clauses count what took effect.** A denied call did nothing and a failed
  edit changed no file, so neither is in a clause; they appear only as
  exceptions. A failed command still ran, and is counted.
- Then the exceptions, each its own token: **N failed** in red, *N denied*,
  *Interrupted*, *N in background* in secondary. They are set apart from the
  sentence: in a narrow editor the sentence is cut at the tail, the
  exceptions never are.
- **The tile shows how the run ended; the sentence counts what failed on the
  way.** A run whose last call failed has the red tile; a failure the model
  recovered from shows only as *1 failed*.

### A run of one is the call itself

53 % of runs are one call. Their row names the call instead of counting it,
and a click opens its document straight away — no chevron, nothing to expand.
On hover a small `arrow.up.right` appears where the chevron would be: it opens
beside, not below.

| call | row |
|---|---|
| Bash | its `description` (96.6 % have one), then the command's first line in 12-pt mono, tertiary, cut at the tail. No description: the command itself, mono, secondary. |
| Edit | **TranscriptView.swift** · `+3 −1` |
| Write, new | Created **Foo.swift** · `55 lines` |
| Read | Read **LibraryStore.swift** · `lines 40–120` / `image` |
| Grep / Glob | Searched for `pattern` · `4 files` |
| WebFetch | Fetched docs.swift.org · `200` |
| Agent | its description · `Explore` · `12 tools` |

## Expanded

A run's items, one 28-pt row each — the run's own height — indented 24 pt,
in the order they ran.

```
▢  Edited TranscriptView.swift, ran 3 commands · 1 failed        +12 −3  34s  ⌄
   ▢  Build the package        swift build -c debug                          6s
   !  Run the unit tests       make test-unit FILTER=Tran…
   ▢  TranscriptView.swift     macos/TranscriptKit/Sources/…           +12 −3
   ▢  Run the unit tests       make test-unit FILTER=Tran…                  21s
```

- **Item row**: tile (the call's kind and state), label, one detail in
  tertiary mono (a command's first line, a file's folder), trailing meta.
  Labels are those of a run of one.
- **Items sit flush.** The list is the run's second level, so it is set
  tighter than the first: items follow the run's line and each other with no
  gap — a 28-pt row is its own air, as in an outline view — and the entry
  after the list keeps the transcript's 14-pt gap (README "Spacing").
- **Consecutive edits to one file are one item** (Edit→Edit is the second most
  common pair): its document is the combined change.
- **A failed item is its red tile**, and nothing more: no word, no error line.
  The tile already says it failed; why is the document's to say, one click
  away. An item keeps its 28 pt whatever its state.
- **Twelve items at most** (98.3 % of runs fit), then *Show 85 more* in link
  colour. A longer list is a log, and a log belongs beside, not in the page.
- **⌥-click the chevron** expands or collapses every run in the transcript —
  the Finder and Xcode outline convention.
- A run is never expanded for the reader, finished or failed. The reader
  opens it; the transcript remembers that per tab.

## Live

The row stands in the same place from the first streamed byte to the result.
Its height doesn't change (except for a permission request), so a live
transcript doesn't jitter as calls start and end.

| moment | tile | text | meta |
|---|---|---|---|
| input streaming | kind, glyph at half ink | the call's live label (below) | — |
| waiting for you | coral outline | *Waiting for your approval* | — |
| running | travelling arc | live label | elapsed, ticking: `12s` |
| two or more running | arc on the first one's kind | *Running 2 commands* | elapsed of the oldest |
| in background | dashed outline, turning | summary so far · *1 in background* | — |
| between calls (the model is thinking) | done | summary so far, past tense | — |
| finished | done / failed | summary | stat, time |

**Live labels** say what is happening with the input the SDK has so far:

| call | label |
|---|---|
| Bash | its description; before it has streamed, the command so far in mono |
| Edit | Editing **A.swift** |
| Write | Writing **Foo.swift** · `142 lines`, counting as content streams |
| Read | Reading **A.swift** |
| Grep / Glob | Searching for `pattern` |
| Agent | description · `Reading LibraryStore.swift · 8 tools`, from task progress |
| WebFetch | Fetching docs.swift.org |

- The words change with a 150-ms crossfade; the tile's arc keeps turning
  across items, so a run of quick calls reads as one motion, not a flicker.
- A running call's output doesn't exist yet (the SDK sends only elapsed time),
  so nothing pretends to stream it.
- Expanded while live, a new item appears at the end of the list. Items
  running in parallel each carry their own arc.
- **Not in a run's row:** the turn-level *thinking* indicator. Between calls
  the row shows only what has happened; the session's status lives at the
  foot of the transcript.

### Waiting for you

The only time a run grows. Under the row, an approval card:

```
◌  Waiting for your approval
┌─────────────────────────────────────────────────────────────────────┐
│ ▢  Run the unit tests                                               │
│    $ make test-unit FILTER=TranscriptViewTests                      │
│    Needs approval: writes outside the project (build/test-dd)       │
│                             [Always Allow ▾]   [Deny]   [Allow ⌘↩]  │
└─────────────────────────────────────────────────────────────────────┘
```

- The card is the user bubble's shape (14-pt radius), outlined with the
  separator colour, not filled — it belongs to the work, not to the user yet.
- It sits level with the row, not indented under it like the items: it is
  not one more item of the list but the question that stops the run, so it
  takes the column's full width.
- It shows **what the call will do**, whole: the full command (up to 12 lines,
  then *Show all*), the edit's diff inline (the one place a diff is inline —
  the decision is here), the path it touches, the reason the CLI gave.
- **Allow** is the default button (⌘↩), **Deny** is ⎋. **Always Allow** is a
  pull-down of the CLI's suggested rules, worded as the rule
  (*Always allow `make test-unit` in this project*).
- On a decision the card folds back into the row: allowed → running; denied →
  the item is *Denied*. If the CLI withdraws the question (interrupted), the
  card goes with the same fold.
- The coral tile is the one warm spot on the screen: the session is stopped
  until you look.

## States of an item, all of them

| state | tile | trailing | extra |
|---|---|---|---|
| streaming input | half-ink glyph | — | |
| queued (parallel, not started) | plain | — | |
| waiting for you | coral outline | *Needs approval* | approval card under the run |
| running | travelling arc | elapsed | |
| in background | dashed outline | *Background* | settled by its notification |
| done | plain | stat / time ≥ 10 s | |
| done in background | plain | *Background · 4m* | |
| failed | red `!` | a command's time ≥ 10 s | the error is in its document |
| denied | stop square | *Denied* | |
| interrupted | stop square | *Interrupted* | |
| no structured result (inside a subagent) | plain | — | document falls back to the model-facing text |
