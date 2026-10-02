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

## Talking out: the advisor and SendMessage

The other direction — Claude reaching another party — is work, so it is a
line in a run like any call, and what was said opens beside.

- **The advisor** (`--advisor <model>`) is a server tool: the reply itself
  carries a `server_tool_use` named `advisor` and its `advisor_tool_result`,
  so it never appears as a tool result in a user message. AgentSDK decodes
  both as `.unknown` today, and the app shows nothing; it needs both blocks
  decoded and paired by id.
  - Its own kind, lightbulb glyph. The clause: *Asked the advisor*. Alone:
    *Asked the advisor* and the advice's first line in tertiary; in a list,
    *Advice* and the first line. Live: *Asking the advisor*.
  - Click: the advice beside, as markdown, the advisor's model as the
    document's status.
  - `advisor_redacted_result`: *Not shown in the transcript*, nothing to
    open. `advisor_tool_result_error`: the red tile and the code in words —
    *Overloaded — try again shortly*, *The conversation is too long for the
    advisor*, *Asked as often as this session allows* (`max_uses_exceeded`).
- **SendMessage** — the message kind, `paperplane`.
  - The clause names the party: *Messaged **team-lead***, *Messaged the
    team* (`to: "*"`), several parties *Sent 3 messages*. An item: *To
    team-lead* and the `summary` the model gave, tertiary. Live:
    *Messaging team-lead*.
  - Click: the message beside — *To team-lead*, the summary as status, the
    body as markdown. A structured message (`shutdown_request`,
    `plan_approval_response`) is named by what it does: *Asked qa to shut
    down*, *Approved qa's plan*.
  - The answer, when it comes, is a message *from* that party (above): the
    two directions look different on purpose — Claude's sending is work, the
    other party's words are conversation.

## Names

A subagent's name is the agent's description when the transcript knows the
call that started it, else *Subagent* and its id's first 7 characters. A
session is its name, else its address.

## Live

A message arrives whole. Nothing streams.
