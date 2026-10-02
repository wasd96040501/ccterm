# Transcript views

How a transcript shows what isn't plain conversation: tool calls, the documents
they open beside the transcript, and the markup the CLI writes into user
messages. Open `index.html` for the sheet — every state of every view, both
appearances, and a playground window that replays a live turn.

Every number below comes from [research/findings.md](research/findings.md).

## The idea: conversation gets the page, work gets a line

A transcript holds two things. **Conversation** is what was said — prompts,
replies, messages from other agents. **Work** is what was done — tool calls,
command echoes, background-task news. Today work is 62 % of the rows, and every
row gets the same space as a paragraph of the reply.

The views follow five rules.

1. **One line per stretch of work.** Consecutive tool calls become one row
   (a *run*); so do consecutive notifications. A row is one line and says three
   things: *what kind of work*, *how much*, *how it went*. Work drops from
   62 % of the rows to 40 %.
2. **Lists in place, content beside.** Expanding a run shows a list of one-line
   items and nothing taller. Anything with a body — output, a diff, a file, a
   subagent's conversation — opens in the other editor of the split, so the
   reading position never moves. (TranscriptKit already rules this for More:
   *never expand the row in place*.)
3. **Report the exception.** Success is silent, as in Xcode's build log. The
   only colours that mean something: **red** — a call failed; **coral** — the
   session is waiting for *you*; green and red digits — lines added and removed.
   A running call moves; it isn't coloured.
4. **A row keeps its height through its life.** Streaming, running and
   finished are the same line; only its words and its glyph change. The one
   exception adds height because it needs a decision: a permission request.
5. **Nothing is shown because it exists.** A field earns a place by answering a
   question a reader has at that moment. Duration appears only when a run took
   longer than the median run; files are named only when there are two or
   fewer (> 95 % of runs); a list stops at 12 items (98.3 % of runs fit).

## The system

**Grid.** 4-pt unit. A run row and an item row are 28 pt (7u) — the box
the hover lights, its words' 16-pt line in the middle — and a glyph tile
16 pt (4u). Items indent 24 pt — one tile plus its gap — so an item's
glyph sits under its run's text.

**Spacing.** Two levels, each with one gap. **First level** — every entry
of the transcript (a prompt, a reply, a run's line, news, a capsule, a
divider): 14 pt between them, TranscriptKit's row gap, the same everywhere.
It is measured from a line of work's words, not its hover: the 6 pt the
hover reaches above and below them is part of the gap.
**Second level** — what a line discloses (a run's items, *Show N more*): 0 pt,
flush under the line and each other; a 28-pt row is its own air, as an
outline view's children are. The approval card, level with its run, sits 6 pt
under it. Nothing else adds space between rows.

**Scrollers.** Overlay, hidden until you scroll, everywhere in the editor
area — the transcript and every document — whatever *Show scroll bars* says.
A scroller never takes width, so lines never rewrap when one appears.

**Type.** Transcript body is 14 pt. Work is set one step down, 13 pt, in
secondary label colour, so the eye separates it from the reply without a box.
Metadata is 11 pt tertiary with monospaced digits. Code, commands and paths are
SF Mono 12 pt.

**Tile.** Each kind of work has a glyph on a tile: a Lamé squircle
|x|⁴ + |y|⁴ = 8⁴, the family of the sidebar's glyphs (`design/sidebar-icons`),
filled with a quaternary fill, the glyph in secondary ink. States change the
tile, never the row:

| state | tile |
|---|---|
| done | plain |
| preparing (input streaming) | glyph at half ink |
| running | a 1.5-pt arc, ⅓ of the outline, travels the squircle once a second |
| background | the outline dashed, turning once every four seconds |
| waiting for you | coral outline, still |
| failed | red fill at 16 %, `!` in red |
| denied / interrupted | glyph replaced by a stop square, tertiary |

The arc is the only decoration that moves, and it is the tile's own outline —
there is no separate spinner. Reduce Motion turns it into a slow pulse.

**Kinds.** Tool names map to eleven kinds, each with one SF Symbol:

| kind | tools | symbol |
|---|---|---|
| command | Bash, `!` commands, TaskOutput | `terminal` |
| change | Edit, NotebookEdit, Write over a file | `pencil` |
| create | Write a new file | `doc.badge.plus` |
| read | Read | `doc.text` |
| search | Grep, Glob, ToolSearch | `magnifyingglass` |
| web | WebFetch, WebSearch | `globe` |
| agent | Agent / Task, Workflow | the sidebar's Lamé star |
| tasks | TaskCreate, TaskUpdate, TodoWrite | `checklist` |
| schedule | Cron*, ScheduleWakeup, Monitor | `clock` |
| message | SendMessage | `paperplane` |
| other | MCP tools, anything unknown | `puzzlepiece.extension` |

**Colour.** System colours only, plus the sidebar's coral. Red and green
appear as text or 10–16 % washes, never as filled buttons.

## The views, largest first

| # | View | Share it covers | Doc |
|---|---|---|---|
| 1 | Run row — consecutive tool calls as one line | 62 % of rows | [01-run.md](01-run.md) |
| 2 | Command document — a Bash call beside the transcript | 76 % of calls | [02-command.md](02-command.md) |
| 3 | File documents — change, new file, read | 14 % of calls | [03-file.md](03-file.md) |
| 4 | Background news — task notifications | 27 % of prompts | [04-background.md](04-background.md) |
| 5 | Local commands, interruptions, compaction | 15 % of prompts | [05-local.md](05-local.md) |
| 6 | Messages from other agents — a subagent's report (a line; the report beside), sessions, coordinator, plugins | — | [06-agent-messages.md](06-agent-messages.md) |
| 7 | Tools that talk to you — questions, plans, task lists | < 3 % | [07-talk.md](07-talk.md) |

## Opening a document beside the transcript

One rule for every view that opens something:

- **Click** opens it in the *other* editor as its temporary tab (italic title,
  hollow pin). The first click splits the area if there is one editor.
  Another click replaces that tab where it stands — clicking down a list never
  piles up tabs. This is Xcode's navigator and the `TranscriptWorkspace`
  temporary tab as it already works.
- **Double-click** opens it pinned.
- The transcript keeps focus, so **↑ / ↓** move through items — across runs —
  and the document follows. Reviewing twenty edits is twenty key presses.
- The item whose document is showing keeps a selection highlight; the
  document's **Show in Transcript** scrolls back to it and flashes it.
- A document's tab identifier is the transcript URL plus the tool call id, so
  editor history returns to it after it's closed.
- A document shown live updates in place when its call finishes.
- The window's title keeps the transcript's project and branch while one of
  its documents is the active tab: a document belongs to its session, as
  Xcode keeps the project when the assistant editor has focus.

## Files

```
design/transcript/
├── README.md          this file
├── 01-run.md … 07-talk.md
├── index.html         the sheet (open directly; no build)
├── preview.css        tokens for both appearances
├── preview.js         tiles, the run sentence, documents — the rules as code
├── preview-sheet.js   sample session, playground split, live replay, specimens
└── research/
    ├── corpus_stats.py
    └── findings.md
```
