# 6 · Messages from other agents

Messages another party put into the conversation: a subagent handing back its
report (`<agent-message>`), another Claude session (`<cross-session-message>`),
the team's coordinator, a plugin. Today they are bold-titled markdown and
read like Claude's own reply.

They are two different things:

- **A subagent's report is work.** It is what a call Claude made produced,
  like a diff or a command's output, and it runs to pages. It follows rule 2:
  a line in place, the content beside.
- **Anyone else is talking** to Claude — conversation, though not the user's.
  It gets the page.

## What a reader wants

- **Who** — before reading a word of it.
- **What they said**: a report when the reader asks for it; anyone else's
  words where they were said.

## A subagent's report: a line

```
▢  Explore agent reported                                                ↗
```

- The run row's grammar (01-run.md): 28 pt, the agent's tile (the Lamé star),
  the name as a noun, *reported*. No meta: a report says nothing a reader
  scans for.
- **Click** opens the report beside, as a markdown document titled with the
  name; double-click pins it. ↑ / ↓ step through it with the other lines that
  open something.

## Anyone else: a caption over their words

Two rows: a caption naming the speaker, then what they said, set by
TranscriptKit as markdown — the same renderer as Claude's replies. It is
quoted: a blockquote is TranscriptKit's form for someone else's words.

```
 ◌ Session “Squash merge admin”
 ┃ PR #314 is merged.
```

- **Caption row**, 20 pt, 13-pt secondary, with the sidebar's glyph for that
  party in the sidebar's colour: session — the coral conversation glyph;
  coordinator — the indigo workflow glyph; plugin — `puzzlepiece.extension`,
  grey. The glyphs mean the same thing here as in the sidebar.
- **The words**: a `.markdown` row whose source is the message as a
  blockquote (`> ` before every line) — TranscriptKit draws the 3-pt bar and
  the 14-pt indent, and find, selection and copy work in it as in any reply.
  Whole: a Messages-style bubble would need a second bubble renderer for
  markdown, which TranscriptKit deliberately doesn't have.

## Names

A subagent's name is the agent's description when the transcript knows the
call that started it, else *Subagent* and its id's first 7 characters. A
session is its name, else its address.

## Live

A message arrives whole. Nothing streams.
