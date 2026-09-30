# 3 · File documents

What Edit, Write and Read open beside the transcript. One layout — Xcode's
source editor, read-only — in three modes: **change**, **new file**, **read**.

## What a reader wants

- **Change**: *what is different*, at the size it really is. The typical edit
  is +3 −1 in one hunk; the p90 is +22 −5. A change that small is lost in a
  side-by-side view (half the width holds one line) — so the view is
  **unified**, changes in place in the file, the way Xcode 26's coding
  assistant shows its edits.
- **New file**: *the file*. 92 % of writes create one; showing 55 new lines
  as 55 green lines says only "new", 55 times.
- **Read**: *what the agent saw* — and what it didn't. 60 % of reads are a
  slice of a file; the reader's real question is "did it read the part that
  matters?".

## The frame

```
┌ jump bar ─────────────────────────────────────────────────────────────────┐
│ ▢ ccterm › macos › TranscriptKit › … › TranscriptView.swift   +12 −3   ↩  │
├───────────────────────────────────────────────────────────────────────────┤
│ 1 ┃ import AppKit                                                         │
```

- **Jump bar**: the path as Xcode's jump bar — folders collapse to `…` from
  the middle when narrow, the file name never does. Trailing: the stat, then
  *Show in Transcript*.
- **Body**: SF Mono 12 pt, 18-pt lines, syntax-highlighted with the transcript
  code card's palette, so a function name is the same teal everywhere.
- **Gutter**: Xcode's code review. At its leading edge, a 3-pt change bar in
  Xcode's source-control blue, hatched, one bar per hunk — the removed and
  added lines together — rounded at its ends; then the line numbers of the
  file *after* the change, tertiary, right-aligned. The bar marks *where*;
  the washes say *what*. The gutter is not text: numbers are never selected
  or copied, and a selection never covers them.
- Find (⌘F) searches the document.

## Change

- **With the original file** (the CLI keeps it unless the file is large):
  the whole file, with each hunk in place and ±3 unchanged lines around it —
  the unified-diff convention. Longer unchanged stretches fold into a
  22-pt bar: `⋯ 120 lines`, tertiary; click to unfold.
- **Without it**: the hunks alone, separated by the same fold bar reading
  `Lines 41–86`.
- **Removed lines**: red wash at 10 %, no line number (they are not in the
  file any more); the text keeps its syntax colours, as in Xcode. **Added
  lines**: green wash at 14 %. Both washes run the whole line, gutter
  included. The characters that actually differ within a changed line get the wash
  again at 30 % — for a +1 −1 edit that one word is the whole story.
- The first change is scrolled to a third of the way down, not to the top:
  the eye wants context above.
- **Several edits to one file in one run** show as one document, the combined
  change. `⌃⌘↑ / ⌃⌘↓` (Xcode's *previous / next change*) step through hunks;
  the jump bar reads `Change 2 of 3` while stepping.
- *Replace all* and *You edited this change before accepting it*
  (`userModified`) appear as `info.circle` notes above the first hunk — only
  when true.

## New file

- The file, highlighted, no wash. The change bar — same place, same shape —
  is green and runs the full height: one mark says "all of this is new".
- Jump bar stat: `New · 55 lines`.
- Write over an existing file (8 %) is a **change** document.

## Read

- The lines read, numbered as in the file (from `startLine`).
- Jump bar: `Lines 40–120 of 880`.
- **The file map**, the one ornament of this document: a 4-pt track down the
  right edge standing for the whole file, the read slice filled in secondary
  ink, the rest a quaternary fill. At a glance: *it saw this much, here.* A
  whole-file read fills the track and says so by being full.
- Image reads (18 %) show the picture at its size, centred, through
  `TranscriptMedia`; PDF and notebook reads show the pages / cells read.
- *Unchanged since last read* (the CLI skipped it) is a one-line document
  saying that, with **Show earlier read** linking to the item where it was.

## Live

| moment | change | new file |
|---|---|---|
| input streaming | the edit's new text arriving in an unanchored card: where it goes is known only when `old_string` is complete | lines appear as they stream; the stat counts up |
| waiting for you | the diff as it will be, approval bar on top | the file as it will be, approval bar on top |
| running | brief; the diff is shown as proposed | same |
| failed | the proposed diff, and the error above it in a red `xmark.octagon` note (*String to replace not found in file*) | same |
| denied | the proposed diff under *Denied* | same |
