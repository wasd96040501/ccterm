# 5 · Local commands, interruptions, compaction

What the user did *to the CLI* rather than said *to the model*: slash
commands, `!` commands, stopping a response — and the compaction that
rewrites what the model remembers. Today a slash command is a user bubble,
which says "you told Claude `/model opus`". You didn't; you set something.

## What a reader wants

- **That it happened and what it set** — a local command's output is one line
  at p99.
- **Where the session's shape changed**: it ended and resumed, it was
  compacted, it was stopped mid-answer.

## A slash command

```
                                                          ( / model opus )
                                                       Set model to opus
```

- On the user's side (trailing) — the user did it — but **not a bubble**: a
  24-pt capsule, 1-pt separator outline, no fill. The command in SF Mono 12,
  secondary; its arguments in label colour.
- Its output (`<local-command-stdout>`) is one 11-pt tertiary line **under**
  the capsule, right-aligned — where Messages puts *Delivered* under a bubble:
  a status of the thing above it, not a message of its own. stderr is red. An
  empty output shows nothing.
- A skill run as a command (`/skill-creator:skill-creator`) shows the skill's
  short name; the full name is the tooltip.
- A command output longer than two lines (rare: `/context`, `/usage`) is
  cut with *Show all*, which opens it beside as a monospaced document.

## Commands that change the session's shape

Two commands are 77 % of all slash commands, and both mark a boundary. They
don't get a capsule — they become the boundary.

- **`/compact`** — the command, its *Compacted* output and the compact boundary
  fold into one divider:

  ```
  ──────────── Conversation compacted · 168k → 14k tokens  Summary ────────────
  ```

  A hairline, the label centred on it in 11-pt secondary, **Summary** a link
  that opens the summary the model continued from, as a markdown document.
  An automatic compaction reads *Compacted automatically*. Tokens come from
  the boundary's `pre_tokens` / `post_tokens`; when unknown, no numbers.
- **`/exit`** — the session ended there. If the transcript continues (it was
  resumed), the divider is the resume: `Resumed · Tue 14:02`. If nothing
  follows, there is no divider — the transcript simply ends.

The same divider marks a **gap of more than an hour** between two rows, with
the time — Messages' rule for timestamps. A long transcript read later gets
its days back.

## A `!` command

```
                                               $ git status  12 lines  ›
```

- The same capsule, `$` for `⌘`. Its output is almost never one line, so the
  capsule says how long it was and opens the **command document** beside,
  titled *You ran*. One line of output fits inline like a slash command's.

## Interruption

`[Request interrupted by user]` is not a row of its own.

- **During a tool call** — it becomes that call's state: the item reads
  *Interrupted*, its tile a stop square, and the run's sentence ends
  *· Interrupted*. Nothing else.
- **While the model was writing** — a mark attached to the end of that reply:
  `stop.circle` and *Interrupted*, 11 pt tertiary, 20-pt line, 4 pt under the
  last line of text instead of a full row gap. It reads as the reply's last
  word.
- The next prompt follows as usual.

## Live

- A slash command appears at once; its output joins the capsule when it
  arrives. Commands that take time (`/compact`) show the divider with a
  travelling arc on a small tile at its centre — *Compacting…* — and settle to
  the counts.
- Interrupting while a permission card is open folds the card and marks the
  item *Interrupted*.
