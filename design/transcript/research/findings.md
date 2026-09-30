# What the transcripts say

Measured with `corpus_stats.py` over 1 500 main-thread transcripts sampled from
`~/.claude/projects` (subagent files and the app's own test sessions left out).
Aggregates only; nothing here quotes a transcript.

```bash
python3 design/transcript/research/corpus_stats.py 1500
```

A **run** is a maximal sequence of tool calls with no visible row between
them — assistant text, a prompt, a command, a notification. Thinking and tool
results are hidden today, so they don't break a run.

## Rows

| | count | share |
|---|---:|---:|
| tool-call rows (one per call, today) | 38 610 | 62 % |
| every other visible row | 23 411 | 38 % |
| runs | 15 349 | — |

Merging each run into one row takes the working from 62 % of the rows to 40 %
(15 349 of 38 760), and the transcript from 62 021 rows to 38 760 (−37 %).

## Runs

| | p50 | p75 | p90 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| calls per run | 1 | 3 | 5 | 7 | 16 | 97 |
| distinct tools per run | 1 | 1 | 2 | 2 | 4 | 8 |
| calls per assistant message (parallel) | 1 | 1 | 2 | 2 | 4 | 68 |
| wall time, seconds | 8 | 30 | 90 | 152 | 513 | — |
| files changed per run | 0 | 0 | 1 | 1 | 3 | 22 |
| edits to one file in one run (runs that edit) | 1 | 1 | 2 | 3 | 6 | 24 |

- **53 % of runs are a single call** (8 098). A run of one is the common case,
  not the edge case.
- **1.7 % of runs are longer than 12 calls** (264).
- Runs of one kind of tool: 67 % are Bash only.

## Tools

| tool | calls | failed |
|---|---:|---:|
| Bash | 29 185 (75.6 %) | 4.0 % |
| Edit | 2 279 | 1.3 % |
| Read | 1 813 | 0.8 % |
| Write | 1 495 | 1.5 % |
| Agent | 707 | 0.3 % |
| Task* / Todo | 1 108 | < 1 % |
| everything else | < 400 each | |

Overall about 3.3 % of calls fail.

- **Bash**: 96.6 % carry a `description`. Command: p50 1 line / 230 chars, p90
  21 lines, p99 116 lines. 15 % start with `cd <dir> &&`. Output: p50 9 lines,
  p90 64, p99 319.
- **Edit**: p50 +3 −1, p90 +22 −5; 99 % are one hunk.
- **Write**: 92 % create a file; p50 55 lines, p90 203.
- **Read**: 60 % read part of a file; p50 60 lines; 18 % are images.

## User-side rows

| kind | count | vs. prompts |
|---|---:|---:|
| prompt | 3 359 | — |
| task notification | 917 | 27 % |
| interruption | 348 | 10 % |
| slash command | 177 | 5 % |
| its output | 159 | — |
| `!` shell command | 1 | — |

- Slash commands: `/exit` 85 and `/compact` 51 — 77 % of them.
- A local command's output is one line at p99.
- Assistant text: p50 148 chars, p90 1 025.

## Live signals the SDK gives

What a design may show while a session runs — nothing else exists:

- a tool call's **input as it streams** (`inputJSON` deltas);
- a **permission request** (tool, input, reason, suggested rules);
- **elapsed time** of a running call (`ToolProgress`, heartbeats) — **not its
  output**; Bash stdout arrives only with the result;
- a background task's **start, progress** (tokens, tool count, last tool) and
  **notification**;
- **permission denied**, and the request **withdrawn** when interrupted.
