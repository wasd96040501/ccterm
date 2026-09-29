# 6 · Other voices

Messages another party put into the conversation: a subagent handing back its
report (`<agent-message>`), another Claude session (`<cross-session-message>`),
the team's coordinator, a plugin. They are **conversation** — somebody is
talking to Claude — but not the user. Today they are bold-titled markdown and
read like Claude's own reply.

## What a reader wants

- **Who is speaking** — before reading a word of it.
- **What they said**, in full when short, in a document when long (subagent
  reports run to pages).

## The row

Two rows: a caption naming the speaker, then what they said, set by
TranscriptKit as markdown — the same renderer as Claude's replies, because
what an agent writes *is* markdown. It is quoted: a blockquote is
TranscriptKit's form for someone else's words.

```
 ✦ Explore agent
 ┃ Found three call sites of `rowSpacing`: …
 ┃
 ┃ And one hard-coded 14 in `EditorAreaTests.swift:118`.
```

- **Caption row**, 20 pt, 13-pt secondary, with the sidebar's glyph for that
  party in the sidebar's colour: subagent — the grey Lamé star; session — the
  coral conversation glyph; coordinator — the indigo workflow glyph; plugin —
  `puzzlepiece.extension`, grey. The glyphs mean the same thing here as in the
  sidebar.
- **The words**: a `.markdown` row whose source is the message as a
  blockquote (`> ` before every line) — TranscriptKit draws the 3-pt bar and
  the 14-pt indent, and find, selection and copy work in it as in any reply.
- **Whole, not cut.** A voice is conversation, and conversation gets the page.
  A Messages-style bubble would need a second bubble renderer for markdown,
  which TranscriptKit deliberately doesn't have (its bubble holds plain text).
- A subagent's name is the agent's description when the transcript knows the
  call that started it, else *Subagent* and its id's first 7 characters.
  A session is its name, else its address.

## Live

A message arrives whole. Nothing streams.
