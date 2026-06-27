# Streamed text disappears when a tool follows it (`[stream_text, tool] → [tool]`)

## Symptom

In a streamed assistant turn that says something, then calls a tool (e.g. "I'll
read the file." → `Read`), the streamed text block vanishes the moment the tool
appears, leaving only the tool row.

## Root cause

The CLI streams the turn as a single `message_start`, but on finalize it splits
**one `message.id`** into separate envelopes — a text-only one and a tool-only
one — that **share that id**. (Confirmed via `PartialMessagesSmoke`: one
`message_start(M1)` with `content_block idx0=text` + `idx1=tool_use`, finalized
as two assistant messages both carrying `msg.id = M1`.)

`SessionRuntime.streamingPreviewEntryIds` is keyed by `message.id`
(`SessionRuntime+Streaming.swift:268`, `applyStreamingPreview`). A streaming
preview entry only ever carries the synthetic `[text@0]` shape
(`syntheticAssistantMessage`).

When the text finalize arrives **before the typewriter finishes revealing**, it
is deferred (`replaceAssistantEntry` → `scheduleFinalize`,
`SessionRuntime+Receive.swift:378`) and the preview mapping is **not yet
consumed**. The next, tool-only envelope shares `message.id`, so
`action(for:)` (`SessionRuntime+Receive.swift:204`) found the still-present
text preview entry and returned `.replaceAssistant(entryId:)` for it. The
parked finalize then ran `swapAssistantPayload`
(`SessionRuntime+Receive.swift:392`), replacing the entry's text payload with
the tool payload — the streamed text was overwritten in place and disappeared.

This is a **runtime-layer** payload swap, not a renderer diff problem: the entry
id is stable; its *contents* get replaced from text to tool.

## Fix

`SessionRuntime+Receive.swift`, `action(for:)`: a groupable (tool-only)
finalized assistant envelope must never converge onto a text preview entry.
Added a `!message.isGroupableAssistant` guard before claiming
`streamingPreviewEntryIds[msgId]`. The tool envelope falls through to `.append`
and lands as its own tool group; the text preview keeps its deferred finalize
and settles back to its text payload on drain.

`isGroupableAssistant` (`SessionRuntime+Receive.swift:701`) is the existing
"all content blocks are tool_use" predicate, already used by
`appendToTimeline` for grouping — reused here, no new concept.

## Relationship to #273

#273 (`fix(transcript): stop streamed markdown blinking out when a tool is
inserted`) is a **different, orthogonal** path and remains valid:

- #273 fixes a *flicker* in `Transcript2Coordinator.applyStructuralChange(.replace)`
  when one assistant message grows `[text] → [text, tool]` (append-only) and the
  unchanged boundary markdown row was needlessly removed + reinserted.
- This bug is a *disappearance* one layer up, in `SessionRuntime` payload
  swapping. It is unreachable by the coordinator-level prefix heuristic #273
  added.

#273 should not be reverted.

## Regression test

`cctermTests/TranscriptStreamTextToolReplayTests.swift` replays the captured
wire ordering through the real `SessionRuntime` → `Session.wireRuntimeMessagesSink`
→ bridge → `Transcript2Controller` stack:

- `testToolFinalizeMidRevealDoesNotReplaceStreamedText` — the bug-trigger
  ordering (text + tool finalize arrive mid-reveal). Fails before the fix.
- `testTextToolTextDrainedKeepsAllBlocks` — companion guarding the drained
  ordering.
