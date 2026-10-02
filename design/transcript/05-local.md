# 5 · Local commands, interruptions, compaction

What the user typed *to the CLI* rather than *to the model*: slash commands,
`!` commands, stopping a response — and the compaction that rewrites what the
model remembers. A command is still something the user typed, so it stays a
user message. Only the command part is set apart.

## What a reader wants

- **That it happened and what it set** — a local command's output is one line
  at p99.
- **Where the session's shape changed**: it ended and resumed, it was
  compacted, it was stopped mid-answer.

## A slash command

```
                     ╭────────────────────────────────────────────────╮
                     │ ⟦/dataviz⟧ Pull the latest code; this PR is     │
                     │ about designing live sessions                   │
                     ╰────────────────────────────────────────────────╯
                                                    ╭──────────────────╮
                                                    │ ⟦/model⟧ opus    │
                                                    ╰──────────────────╯
                                                       Set model to opus
```

- **The user bubble, unchanged.** It has the same shape, the same width rule
  and the same 14-pt text as any prompt. The user typed it, so it stays on the
  user's side, in the user's form.
- **Only the command is set apart.** The command is a *token* at the start of
  the bubble: SF Mono 13, medium weight, in label ink, on a 5-pt-radius inset
  of the bubble's own blue (accent at 16 % over the bubble). The token is a
  deeper patch of the bubble's colour, not a new colour. The `/` is in
  secondary ink. The token is padded 4 pt on each side, sits on the text's
  baseline and doesn't change the line height.
- **Arguments are ordinary text.** They follow the token and wrap like any
  message: a skill's prompt reads as a prompt.
- **A command without arguments** is a bubble holding only the token. It is
  short, but it's still a bubble.
- **Skills and plugins** show the short name in the token (`/skill-creator`).
  The full name (`/skill-creator:skill-creator`) is its tooltip.
- **The output** (`<local-command-stdout>`) is one 11-pt tertiary line *under*
  the bubble, right-aligned, where Messages puts *Delivered*: it reports on the
  message above it and is not a message of its own. stderr is red. An empty
  output shows nothing. Output longer than two lines (rare: `/context`,
  `/usage`) is cut with *Show all*, which opens it beside as a monospaced
  document.
- **The composer draws the same token** as you type (08-live.md): what you
  typed is what the transcript shows.
- **A setting changed from the composer is a command too.** The CLI writes a
  model chosen from the composer's Model control as `/model`, so it shows as
  this bubble. The transcript reads the same either way.

## Commands that change the session's shape

Two commands are 77 % of all slash commands, and both mark a boundary. They
don't get a bubble — they become the boundary.

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
                                               ╭────────────────────────╮
                                               │ ⟦!⟧ git status --short  │
                                               ╰────────────────────────╯
                                                          4 lines  ›
```

- The same bubble, with a `!` token. The command is all of the message, so the
  text after the token is SF Mono 12.5 in label ink.
- Its output is almost never one line, so the line under the bubble gives the
  output's length, as a link that opens the **command document** beside,
  titled *You ran*. One line of output fits inline, as a slash command's does.

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

- A slash command appears at once; its output joins the bubble when it
  arrives. Commands that take time (`/compact`) show the divider with a
  travelling arc on a small tile at its centre — *Compacting…* — and settle to
  the counts.
- Interrupting while a permission card is open folds the card and marks the
  item *Interrupted*.
