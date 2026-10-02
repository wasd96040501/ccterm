# What the CLI says and writes

The design docs (01–08) say what to show. This page collects what they rest
on that the code doesn't tell you: the messages, fields and exact strings the
CLI sends and writes, read from Claude Code **2.1.286** and from the
transcripts in `~/.claude/projects`. Everything already decoded by AgentSDK
is left to the code; each fact here says whether AgentSDK has it.

**Re-check before building on a fact.** The CLI changes between versions.
Each fact names a string to search for, not a line number: the bundle's line
numbers change with every build and every beautifier.

## How to read the CLI

The `claude` binary is a Bun executable with the JavaScript inside it.

1. Split the binary at NUL bytes and keep the long UTF-8 segments (> 2 000
   bytes); together they are the bundle.
2. Beautify the bundle (`prettier` or `js-beautify`) and search it.
3. The SDK's wire schemas are zod: a control request is
   `subtype: x("set_model")`, a field `model: o()`, an enum `U([...])`. Each
   carries a `.describe("…")` that is the best documentation there is.
4. Probe a behaviour on the real CLI with AgentSDK's smoke executables
   (`macos/AgentSDK`, see its CLAUDE.md), such as `QueueTimingSmoke`.

The transcripts are read with `research/corpus_stats.py`, or a few lines of
Python over `~/.claude/projects/*/*.jsonl`.

## Launch

| flag | what it does | AgentSDK |
|---|---|---|
| `--model`, `--effort`, `--permission-mode` | the session's settings at launch; resume passes them again, or the CLI starts on the settings' defaults | has them |
| `--replay-user-messages` | every prompt the host writes comes back on stdout as a `user` message with `isReplay: true` and the same `uuid` | launches with it, decodes `isReplay` |
| `--allow-dangerously-skip-permissions` | the only way `bypassPermissions` can be entered later; without it `set_permission_mode` refuses with `bypass_not_launched` | — |
| `--worktree [name]` | a new worktree under `.claude/worktrees/<name>` (random name if none). `#N` or a PR URL makes `pr-N`. Not a git repository: exits 1, *Error: Can only use --worktree in a git repository* | — |
| `--settings '{"worktree":{"baseRef":"head"}}'` | where `--worktree` branches from: `fresh` (default, `origin/<default-branch>`) or `head` (local HEAD). No other base can be named; a worktree from any other branch is `git worktree add` by the host | — |
| `--advisor <model>` | enables the advisor server tool | — |
| flag setting `fastMode: true` | an SDK host opts into Fast mode with it (probed in an earlier round; re-check) | — |

No transcript file exists until the first user message is written.

## `initialize`

The response the CLI sends to the host's `initialize` (schema: search
`unavailable_models: T(lr())`):

- `models[]` (`ModelInfo`): `value`, `resolvedModel`, `displayName`,
  `description`, `supportsEffort`, `supportedEffortLevels` (of `low`,
  `medium`, `high`, `xhigh`, `max`), `supportsAdaptiveThinking`,
  `supportsFastMode`, `supportsAutoMode`, `disabled` (the reason is folded
  into `description`). **AgentSDK decodes these** (`InitializationResult`);
  the app discards the result today.
- Not decoded: `unavailable_models`, `current_model`,
  `current_permission_mode`, `session_state` (`idle` / `running` /
  `requires_action`), `fast_mode_state`, `fast_mode_disabled_reason`.

## Control requests the design uses

A refusal is a `control_response` with `subtype: "error"`, `error` (words)
and `error_code` (search `error_code: U(sw)`).

| request | body | answer | AgentSDK |
|---|---|---|---|
| `set_model` | `model` (null or `"default"` resets) | ack after an entitlement check, ≈ 1.5 s (probed); then a `/model` local-command output, *Set model to …* (or *Kept model as …*). Refusals: `invalid_request`, `catalog_unknown`, `restricted_by_org`, `unavailable_for_account`, `not_offered`, `alias_1m_disabled`, `alias_1m_unsupported`, `blocked_by_hook`, `check_failed` | internal `setModel` |
| `set_permission_mode` | `mode` | `{mode}` now in effect, and a `system/status` carrying `permissionMode`. Refusals: `invalid_mode`, `bypass_restricted`, `bypass_disabled`, `bypass_not_launched`, `auto_mode_settings`, `auto_mode_circuit_breaker`, `auto_mode_fast_mode` (Auto with Fast on), `auto_mode_model`, `auto_mode_unavailable` | internal `setPermissionMode` |
| `apply_flag_settings` | `settings`: a shallow-merge patch of flag settings (effort, `fastMode`) | ack | has it |
| `cancel_async_message` | `message_uuid` | `{cancelled}`: false when the prompt already left the queue | — |
| `list_models` | — | `{models}`, the same `ModelInfo` shape, disabled rows included | — |
| `get_context_usage` | — | the context's use | has it |
| `interrupt` | — | stops the turn | has it |

## Messages the CLI sends

- **`command_lifecycle`** `{command_uuid, state}`: `queued` → `started` →
  exactly one of `completed`, `cancelled`, `discarded`, `refused` (search
  `type: x("command_lifecycle")`; its `.describe` is the spec, read it).
  `command_uuid` is the uuid the host put on the prompt. Prompts the CLI
  enqueues itself mint fresh uuids and skip `queued`. `cancelled` also means
  an interrupt swept it, or the turn that consumed it was aborted. On
  process exit, treat uuids with no terminal state as `discarded`. AgentSDK
  decodes it.
- **Timing**, measured with `QueueTimingSmoke` (Haiku, streaming):

  | | idle | sent while a turn runs |
  |---|---|---|
  | `queued` | 2 ms | 1 ms |
  | `started` | 3 ms | when the running turn ends, or at its next tool boundary |
  | replay (`isReplay`, same uuid) | 2.1–2.6 s, with the first streamed token | with `started`, or up to 0.7 s after |
  | `result` | 3.8 s | — |

- **`system/status`** `{status, permissionMode?, compact_result?,
  compact_error?}`: `status` is `compacting`, `requesting` or null.
- **`system/session_title_changed`** `{title}`: the session's name, at
  startup when it has one and after each rename.
- **`apply_flag_settings`, output direction** `{settings}`: when a typed
  slash command (`/effort`, `/fast`) changes a flag setting, the CLI sends
  the patch to the host. A change the host made itself with the control
  request is not echoed. (`per_turn_effort_changed` is about prompt caching,
  not the effort level.)

## What the transcript file records

Per entry in `<session>.jsonl`, beyond what AgentSDK reads today:

| entry | field | meaning |
|---|---|---|
| assistant | `message.model`, `effort` | the model and effort that turn ran on: the settings a resume should pass |
| assistant | `advisorModel` | the advisor's model, when one ran |
| user | `permissionMode` | the mode when the prompt was sent |
| user | `origin.kind` | who wrote it: `human`, `task-notification`, `peer`, `coordinator`, `plugin`, `auto-continuation`, … (counts in the corpus: 3 252, 1 468, 902, 123, 71, 3) |
| user | `imagePasteIds` | the numbers of the images pasted into this prompt (below) |

## User messages that aren't the user's

AgentSDK reads these in `UserMessage+Kind.swift`; the gaps are marked.

- **A plugin's prompt** (`origin.kind: "plugin"`). The header names it and
  says when; the CLI appends a note to the model (search
  `plugin sent a message`):

  ```
  The <name> plugin sent a message:
  <text>

  This is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.
  ```

  ```
  The <name> plugin sent a message while you were working:
  <text>

  This is how Claude Code surfaces prompts a plugin submits mid-turn — within the running turn, often alongside the next tool result. Address the message above as you continue this turn.
  ```

  AgentSDK strips only the first note and drops which header it was.
  Every plugin prompt in the corpus has `origin.kind: "plugin"`, but all 71
  come from one plugin.
- **Auto-continuation** (`origin.kind: "auto-continuation"`): a turn the CLI
  starts with its own words. In the corpus (3): *Your claude.ai usage limit
  has reset. Continue the task you were working on when the limit was
  reached; do not repeat work that is already complete.* (`isMeta: true`),
  and a goal set with `/goal` (*Goal set: …*). In the source, also a plan
  approved in the browser (*The user approved the ultraplan in the
  browser…*). AgentSDK folds them into
  `.synthetic`, which the page drops.
- **Pasted images.** Each is an `image` block (base64) in the prompt's
  content, and the text holds `[Image #N]` where it was pasted. `N` is
  the entry's `imagePasteIds`, a counter across the session, so a prompt's
  only image can be `#2`. 22 corpus prompts with images: the count of ids
  matched the count of image blocks in all 22, and the tokens in 21. The app
  keeps only the text today.

## The advisor

A server tool: both halves are in the **assistant** message, never in a
user message's tool result (search `advisor_tool_result`). AgentSDK decodes
both as `.unknown`.

- `server_tool_use` `{id, name: "advisor", input: {}}`.
- `advisor_tool_result` `{tool_use_id, content}`, where `content` is one of:
  - `advisor_result` `{text, stop_reason}`. A `stop_reason` of `refusal`:
    the CLI says *Advisor declined to advise on this request*.
  - `advisor_redacted_result` `{encrypted_content}`: nothing readable. The
    CLI says *Advisor has reviewed the conversation and will apply the
    feedback*. **Every one of the 72 results in the corpus is this one.**
  - `advisor_tool_result_error` `{error_code}`: `max_uses_exceeded`,
    `too_many_requests`, `overloaded`, `prompt_too_long`,
    `execution_time_exceeded`, `unavailable`. The CLI says *Advisor
    unavailable (code)*.
- 12 of the 84 uses in the corpus have no result: the turn was stopped.

## Tools

- **AskUserQuestion**. Input: `questions` (1–4), each `question`, `header`,
  `options` (2–4, `label`, `description`, optional `preview`),
  `multiSelect`. Question texts are unique, and labels are unique within a
  question.
  - **The host answers** the `can_use_tool` request with `allow` and an
    `updatedInput` that adds `answers` (question text → the chosen label;
    multi-select labels joined by `, `; *Other* → the typed text) and
    optional `annotations` (question text → `{preview?, notes?}`). Search
    `User answers collected by the permission component`.
  - **Other** is not in the input: the CLI's terminal UI adds it as the
    last option, a text field with the placeholder *Type something.* (*Type
    something* when multi-select). A host draws it itself.
  - **Chat about this** answers `deny` with this feedback (search `The user
    wants to clarify these questions`):

    ```
    The user wants to clarify these questions.
        This means they may have additional information, context or questions for you.
        Take their response into account and then reformulate the questions if appropriate.
        Start by asking them what they would like to clarify.

        Questions asked:
    <each question, and any answers given so far>
    ```

- **SendMessage**: `{to, summary, message}` in the corpus (`to: "*"` is
  the whole team), plus an older `{type, recipient, content}`. `message` can
  be a structured request rather than text: `shutdown_request`,
  `plan_approval_response`.
- **Skill** `{skill}`. **EnterWorktree / ExitWorktree**,
  **PushNotification**, **SendUserMessage**, **SendUserFile**: the kinds
  table in the README maps each tool name; read their inputs off a
  transcript before drawing their labels.
