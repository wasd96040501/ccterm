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

Messages' group chat: the other party on the leading side, their name above
their bubble.

```
 ✦ Explore agent
 ┌───────────────────────────────────────────────────┐
 │ Found three call sites of rowSpacing: …           │
 └───────────────────────────────────────────────────┘
```

- **Sender line**, 11 pt secondary, 4 pt above the bubble, with the sidebar's
  glyph for that party in the sidebar's colour: subagent — the grey Lamé star;
  session — the coral conversation glyph; coordinator — the indigo workflow
  glyph; plugin — `puzzlepiece.extension`, grey. The glyphs mean the same
  thing here as in the sidebar.
- **Bubble**: the user bubble's geometry (14-pt radius, 16/14 padding, ¾ of the
  column) on the leading side, filled with the secondary system fill — grey
  where the user's is blue. Markdown inside.
- **Long messages** are cut by TranscriptKit's own truncation; **More** opens
  the whole message beside as a markdown document (the rule TranscriptKit
  already has for More).
- A subagent's name is the agent's description when the transcript knows the
  call that started it, else *Subagent* and its id's first 7 characters.
  A session is its name, else its address.

## Live

A message arrives whole. Nothing streams.
