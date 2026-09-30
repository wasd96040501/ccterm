# 2 · The command document

What a Bash call — or a `!` command the user ran — opens beside the transcript.
Three out of four calls are Bash, so this is the document readers open most.

## What a reader wants from it

- **What exactly ran.** The description says the intent; the command is the
  truth. 15 % of commands begin with `cd <dir> &&` — noise to read, but not to
  hide.
- **What it printed**, findable: output is 9 lines at p50 but 64 at p90 and
  319 at p99. ⌘F must work on it.
- **Why it failed**, when it did: the exit code and the lines that say so.
- **Anything unusual about how it ran**: in the background, with the sandbox
  off, cut off by a timeout, interrupted. These are rare and each changes how
  far to trust the output — so they are shown, and only when true.

## Layout

The document is a page, not a terminal. It reads top to bottom: what was
meant, what ran, what came out.

```
┌ jump bar ─────────────────────────────────────────────────────────────────┐
│ ▢ Run the unit tests                                ↩ Show in Transcript  │
├───────────────────────────────────────────────────────────────────────────┤
│  Run the unit tests                                                       │  15 pt semibold
│  Failed · exit 65 · 48s · Sandbox off                                     │  11 pt
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ $ cd ~/dev/ccterm &&                                                │  │  prefix tertiary
│  │   make test-unit FILTER=TranscriptViewTests                   ⧉     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│   1  Test Suite 'TranscriptViewTests' started                             │  output, 12 pt
│   2  …                                                                    │
│  41  error: 'rowSpacing' is inaccessible due to 'private' protection level│
│  42  ** TEST FAILED **                                                    │
│                                                                           │
│  stderr ───────────────────────────────────────────────────────────────── │
│   1  xcodebuild: error: Failed to build workspace                         │
└───────────────────────────────────────────────────────────────────────────┘
```

- **Jump bar** (28 pt): the kind's tile and the tab's title; trailing, *Show in
  Transcript*. Every document has this bar, so every document has the way
  back in the same place.
- **Title**: the description; without one, *Command*. The tab's title is the
  description cut to 32 characters.
- **Status line**, 11 pt, only facts that are true: *Failed · exit N* (red
  word, rest tertiary) — success writes nothing but the time; the duration;
  *Background*; *Sandbox off* with `exclamationmark.shield` in orange (a
  security fact, the one orange on the page); *Timed out after 2m*;
  *Interrupted*.
- **Command card**: the code-card shape of the transcript (6-pt radius,
  quaternary fill, 16/12 padding). `$` hangs in the left padding in tertiary,
  so the command's own text aligns with the output below. A leading
  `cd <dir> &&` is set in tertiary on its own line — there, but quiet. Shell
  tokens are tinted like inline code: the command word in the inline-code teal,
  strings in the string colour of the code card; flags stay label colour.
  Copy appears on hover. Commands over 12 lines fold with *Show all 43 lines*.
- **Output**: no card — it is the page's body. SF Mono 12 pt, line numbers in
  a tertiary gutter, ANSI SGR colours honoured (bold, the 16 colours mapped to
  system colours). The CLI's note on a meaningful exit code
  (`returnCodeInterpretation`, *No matches found*) sits above the output as an
  `info.circle` line.
- **stdout and stderr are one stream.** The CLI runs a command with its
  stderr into stdout, so warnings and errors are in the output, in the order
  they were printed — there is nothing to split. What it records as `stderr`
  is its own note, *Shell cwd was reset to `dir`*, which answers no question
  the reader has and is not shown. Anything else in `stderr` goes under a
  hairline headed *stderr*, its numbers red. A failed
  call is recorded as one string (*Exit code N* and the merged output): its
  status line takes the exit code, the rest is the output.
- **The gutter is not text.** Line numbers are never selected, copied or
  found, and a selection never paints over them — Xcode's gutter. A click or a
  drag in the gutter starts no selection.
- **The header is not text either.** Title, status line and command card
  are views above the output, each selectable on its own; a double-click on
  one selects a word of it, never a block of the page.
- **No output**: *No output*, tertiary, where the output would be.
- **Cut off**: when the CLI persisted the output elsewhere, a footer line —
  *Output was too long to keep here. The full output is in* `path` —
  with **Open**.
- **Image output** (`isImage`): the picture, through `TranscriptMedia`.
- **Failure** gets no red wash. The status word is red; the gutter numbers of
  lines that match `error:` / `fatal:` / `FAILED` turn red — the eye lands on
  them in a long log without the page shouting.

## Live

| moment | the document shows |
|---|---|
| input streaming | the command card filling, a caret at its end; no output area |
| waiting for you | an approval bar under the jump bar: *Claude wants to run this command* · reason · **Deny** / **Allow**. Same buttons, same keys as the card in the transcript; answering either answers both |
| running | *Running · 12s* in the status line, the tile's arc in the jump bar; output area: *Output appears when the command finishes.* — the SDK doesn't stream it, so nothing fakes it |
| in background | *Running in background · 3m*; when the CLI names an output file, its tail follows live, pinned to the bottom while you are at the bottom (Terminal's rule) |
| finished while open | the output fills in place; the scroll position is the top |
| denied | status *Denied*; no output area |
| interrupted | status *Interrupted*; whatever output was recorded |

## A `!` command

The same document. The title is *You ran*, and the status line says *Local*.
The transcript row for it is in [05-local.md](05-local.md).
