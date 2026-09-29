# 4 · Background news

A `<task-notification>` is the CLI telling the model that something started
earlier has ended — a background command, an agent, a workflow — or that a
monitor saw something. There are 27 of them for every 100 prompts. Today each
is an italic line.

It is **work**, not conversation: nobody said it. So it takes the run row's
grammar — one 28-pt line, a tile, a sentence, trailing meta — and a reader's
eye files it with the work.

## What a reader wants

1. **Which task, and did it succeed?**
2. **What did it produce?** — an agent's answer, a command's output file.
3. **Where did it come from?** — the call that started it may be screens
   above.

## The row

```
▢  Agent “Review the diff” finished                     14 tools · 2m 10s   ↖
▢  Background command “Build” failed · exit 1                          6m   ↖
```

- **Tile** by task: command → `terminal`; agent → the Lamé star; workflow →
  the sidebar's workflow glyph; remote agent → star with `icloud`; monitor →
  `waveform.path.ecg`.
- **Text**: the CLI's `summary`, which is already one line. Status as the run
  row does it: completed is silent; *failed* and *killed* red; *stopped*
  secondary.
- **Meta**: what the usage says — tools and time for an agent; agents done of
  total for a workflow (`8 of 9 agents · 1 failed`); time for a command.
  Tokens are left out: they answer no question the reader has here.
- **↖ origin**, on hover: scrolls to the call that started the task (by
  `tool-use-id`), flashes its item. If that call is inside a collapsed run,
  the run expands just for the flash and closes after.
- **Click** opens what the task produced, beside:
  - an agent or workflow → its **result** as a markdown document, with the
    usage and the worktree (`path` · `branch`) in the status line; the
    failures and the recovery hint, when there are any, above the result;
  - a command → the **command document** of the call that started it, whose
    output now follows the output file;
  - a monitor → the event text.

## Consecutive news is one row

Like tool calls: consecutive notifications with nothing visible between them
become one row — *3 background tasks finished · 1 failed* — and expand into
their rows. Monitors are what make this common.

## The other end: the call that started it

A call launched into the background is settled by its notification:

- **Live**: the item's tile has the dashed, slowly turning outline and reads
  *Background*; the run's summary adds *1 in background*. When the
  notification arrives, the item settles — *Background · 6m* or red *Failed*
  — and a new notification row appears at the bottom, where it happened.
- **Read later**: the transcript pairs them on load (by `tool-use-id`), so the
  item already shows how the task ended. Both rows remain: one where the task
  started, one where the news arrived — the transcript is a timeline.

## Live

A notification row arrives whole; it has no running state of its own. Its
running state is the launching item's (above).
