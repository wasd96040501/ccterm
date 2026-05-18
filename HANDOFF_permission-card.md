# Permission Card — Handoff (Round 2)

> **DO NOT MERGE THIS FILE INTO `main`.** Working notes for the next
> session on branch `claude/relaxed-lederberg-faa3ea` / PR
> <https://github.com/wasd96040501/ccterm/pull/121>. Delete (or move
> to `/tmp`) before the branch is squashed onto `main`.

## Branch / PR state

- Branch: `claude/relaxed-lederberg-faa3ea`
- PR: <https://github.com/wasd96040501/ccterm/pull/121>
- Working tree: clean. Eleven commits pushed.
- `make test-unit` green at 157 cases. CI re-runs on every push.
- `make build` last verified before the round 1 → 2 transition.

### What landed this round (5 commits)

| SHA | Message |
|---|---|
| `e0419f9` | `feat(permission-card): classify requests by tool kind` — adds `PermissionCardKind` enum + `kind(for:)` |
| `02698e2` | `feat(permission-card): per-kind body dispatch + shell body` — refactors `PermissionCardView` to switch on kind, adds `PermissionShellCardBody` |
| `0956602` | `feat(permission-card): file-write body with DiffView preview` — adds `PermissionFileWriteCardBody` for `.fileEdit` + `.fileWrite` |
| `f1775a3` | `feat(permission-card): NotebookEdit body` — adds `PermissionNotebookEditCardBody` |
| `b6f10dd` | `feat(permission-card): WebFetch body` — adds `PermissionWebFetchCardBody` |

### Reference table — upstream permission UIs

This is the canonical reference for what each upstream
`*PermissionRequest` renders. Every row was read from
`/Users/luoyangze/code/ccmaster/claude-code-source/src/components/permissions/*`
during round 2. The next session should keep going through this
table and implement each remaining `PermissionCardKind` body in
the same style. **Read the upstream file before implementing —
the table is a summary, not a substitute.**

The mounting machinery is identical for every kind:
`permissionComponentForTool(tool)` in
[PermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/PermissionRequest.tsx)
dispatches by tool identity to one of the kind-specific components,
each of which renders inside `PermissionDialog` (a rounded box with
a title bar) and almost always calls `PermissionRuleExplanation` +
`PermissionPrompt` (the option list).

Done in ccterm:

| Kind | Upstream component | Title | Body fields | Notes |
|---|---|---|---|---|
| `.bash` / `.powerShell` | [BashPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/BashPermissionRequest/BashPermissionRequest.tsx) (481 lines) | "Bash command" / "Bash command (unsandboxed)"; subtitle = classifier status (shimmer "Attempting to auto-approve…" / "Auto-approved · matched <rule>" / "Requires manual approval") | • `command` via `BashTool.renderToolUseMessage` (always verbose)<br>• `description` dimmed (when not in classifier-explainer mode)<br>• Compound branch (`decisionReason.type === 'subcommandResults'`): suggestions extracted to a single editable prefix, the prefix is shown as inline-editable input<br>• Destructive command warning (when feature flag on)<br>• `PermissionRuleExplanation` | Three to five options: Yes / Yes-apply-suggestions or Yes-prefix-edited / Yes-classifier-reviewed (flag) / No. Each option may have its own feedback input. The classifier polls a backend during render — we have no equivalent yet. ccterm body just shows command + description + a rule-count hint. |
| `.fileEdit` (Edit, MultiEdit) | [FileEditPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/FileEditPermissionRequest/FileEditPermissionRequest.tsx) (181 lines) | "Edit file"; subtitle = `relative(getCwd(), file_path)` | • Question: "Do you want to make this edit to **basename**?"<br>• Content: `FileEditToolDiff` rendered against `[{ old_string, new_string, replace_all }]` — same renderer the transcript uses; reads the file synchronously and computes the full diff | Wraps `FilePermissionDialog` which handles IDE diff sync, allow-always-with-glob-rule prompt, and a feedback flow. ccterm currently shows a **snippet diff** (`old_string` → `new_string`) without reading the file. Upgrading to a full-file diff (read file → apply edit → diff) is the obvious next step for the `.fileEdit` body. |
| `.fileWrite` (Write) | [FileWritePermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/FileWritePermissionRequest/FileWritePermissionRequest.tsx) (160 lines) | "Create file" or "Overwrite file" (based on sync `readFileSync` of `file_path`); subtitle = relative path | • Question: "Do you want to create/overwrite **basename**?"<br>• Content: `FileWriteToolDiff` — reads the file synchronously, diffs old vs `input.content`; falls back to `oldContent = ""` on ENOENT (and `DiffBlock(oldString: nil)` mode in ccterm parlance) | ccterm matches the upstream content shape: full-file diff via `DiffView` + 240pt scroll cap. |
| `.notebookEdit` | [NotebookEditPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/NotebookEditPermissionRequest/NotebookEditPermissionRequest.tsx) (165 lines) | "Edit notebook"; subtitle = relative path | • Question: "Do you want to **insert this cell into / delete this cell from / make this edit to** basename?"<br>• Content: `NotebookEditToolDiff` renders the cell payload — for insert/replace shows `new_source` highlighted as python or markdown; for delete reads the existing cell from disk and renders it as the "removed" content. | ccterm renders `new_source` in a 200pt scroll, plus a `Cell <id> · python|markdown` metadata line. Full pre-edit cell diff (parse `.ipynb`, extract cell, old → new) is deferred. |
| `.webFetch` | [WebFetchPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/WebFetchPermissionRequest/WebFetchPermissionRequest.tsx) (257 lines) | "Fetch" | • `WebFetchTool.renderToolUseMessage({url, prompt})` — typically `WebFetch(URL, prompt)`<br>• `description` dimmed<br>• `PermissionRuleExplanation` | Three options: Yes / Yes-don't-ask-again-for-**hostname** / No. ccterm reuses the shared "Allow always" button (which forwards the request's `permissionSuggestions` — those encode `domain:<host>`); the body shows URL + parsed hostname chip + prompt. |

Still to do (the next session's queue) — every entry needs an
`Permission<Kind>CardBody.swift` view, a `Permission<Kind>CardBodyTests.swift`
logic test, a dispatch case in `PermissionCardView.body(for:)`, and any
new Localizable.xcstrings keys both languages:

| Kind | Upstream component | What it shows |
|---|---|---|
| `.filesystemRead` (Read, Glob, Grep, FileRead) | [FilesystemPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/FilesystemPermissionRequest/FilesystemPermissionRequest.tsx) (114 lines) | • Title: `Read file` / `Edit file` (based on `tool.isReadOnly(input)`)<br>• Subtitle: relative path<br>• Content: `Box{ Text { userFacingName(input) + '(' + renderToolUseMessage(input) + ')' } }` — e.g. `Read(/path/to/foo.swift)` or `Grep(pattern:"foo", path:"src")`<br>• Falls back to `FallbackPermissionRequest` if `getPath(input)` returns null<br>• Wraps `FilePermissionDialog` for IDE sync<br><br>**ccterm shape suggestion:** show the tool name as a label ("Read" / "Glob" / "Grep"), the resolved path / pattern / glob below it in monospace, and an icon (e.g. `doc.text` / `magnifyingglass` / `text.viewfinder`). For Glob: also show the `path` (search root) if present. For Grep: show `pattern` + optional `output_mode` (files_with_matches / content). |
| `.enterPlanMode` | [EnterPlanModePermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/EnterPlanModePermissionRequest/EnterPlanModePermissionRequest.tsx) (121 lines) | • Title: "Enter plan mode?" with **planMode purple** border (`color="planMode"`)<br>• Body: three blocks separated by `marginTop={1}`:<br>　1. `"Claude wants to enter plan mode to explore and design an implementation approach."`<br>　2. A bullet list (dimColor): "In plan mode, Claude will:" then four lines each prefixed " · " — explore codebase, identify patterns, design strategy, present a plan<br>　3. "No code changes will be made until you approve the plan."<br>• Options: "Yes, enter plan mode" / "No, start implementing now"<br><br>**ccterm shape suggestion:** hard-code the four bullets. The card needs an accent color override since the existing card border uses `.barSurface` material — see `RootView2.swift`'s `barSurface(cornerRadius:)` and the `permission` / `planMode` theme keys. Could expose a `tint: Color?` parameter on `PermissionCardView` driven by the kind. |
| `.exitPlanMode` (incl. `ExitPlanModeV2`) | [ExitPlanModePermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/ExitPlanModePermissionRequest/ExitPlanModePermissionRequest.tsx) (767 lines — by far the most complex) | • Title: typically not shown — the body itself is a fullscreen-style review surface<br>• Body: `Markdown` render of `input.plan` (the agent's plan). Plan length isn't bounded — upstream uses a sticky footer so options stay visible while the user scrolls<br>• Below the plan: context-window percentage usage, image attachment support, a built-in prompt editor (open in `$EDITOR`)<br>• Options: many — bypass-permissions / accept-edits / accept-edits-keep-context / default-keep-context / resume-auto-mode / auto-clear-context / ultraplan / no — depending on feature flags + workspace state. Each transitions the session's `PermissionMode` plus optionally clears context or starts a new agent<br><br>**ccterm shape suggestion (v1):** render `input.plan` as markdown using the existing `Markdown.swift` parser → NativeTranscript IR pipeline — but the card needs to be much taller (no scrollback in the input bar overlay). For the first cut, render the plan as plain monospaced text inside a `ScrollView` with a large max height (e.g. 480pt) — sticky footer is automatic because the buttons live below the scroll. Skip the auto-mode / ultraplan / accept-edits-keep-context branches — they need session-mode plumbing we don't have. Three-button "Allow once / Allow always / Deny" is sufficient. Mention in the PR description that exit-plan-mode is "v1; the multi-option button matrix is future work." |
| `.taskAgent` (Task, Agent) | No dedicated component in upstream — falls through to `FallbackPermissionRequest` | The Task / Agent tools generally request permission via the generic fallback. Input shape: `subagent_type` (e.g. "Explore" / "Plan" / "claude-code-guide"), `prompt`, optional `description`, `model`, `isolation`. <br><br>**ccterm shape suggestion:** show `subagent_type` as the headline ("Run Explore agent"), then `description` dimmed, then `prompt` in a 200pt-cap scroll. If `isolation == "worktree"`, show a chip "Isolated worktree". |
| `.skill` | [SkillPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/SkillPermissionRequest/SkillPermissionRequest.tsx) (368 lines) | • Title: derived from `userFacingName`; subtitle includes the skill name<br>• Body: shows the skill name + (when present) the `command` field from `permissionResult.metadata`<br>• `originalCwd` is bolded — the rule that "Allow always" installs is per-skill-per-cwd<br>• Options: Yes / Yes-don't-ask-again-for-**skill-in-cwd** / Yes-don't-ask-again-for-**prefix-in-cwd** / No (the prefix variant kicks in when the skill name has a space)<br><br>**ccterm shape suggestion:** show the `skill` field (the skill's name), optional `args` in monospace below, and a chip showing the working directory's basename. |
| `.askUserQuestion` | [AskUserQuestionPermissionRequest/](../../../../../../ccmaster/claude-code-source/src/components/permissions/AskUserQuestionPermissionRequest/) (644 lines + helpers) | This is **not really a permission card** — it's a full multi-step question UI: title navigation bar between questions, multi-select state, image / paste support, syntax-highlighted code in option labels. The "permission" framing is just how the CLI plumbs interactive questions through the same tool-use approval pipe.<br><br>**ccterm shape suggestion:** **don't** try to inline this into the input-bar card. Either:<br>　(a) keep the existing fallback body for now and add a TODO; or<br>　(b) render a single-line summary ("Claude wants to ask you N questions") with the three buttons, where "Allow once" pops a sheet hosting the real question UI. The full question UI deserves its own follow-up PR — flag it in the handoff and don't try to fit it under the input bar. |
| `.mcp` (`mcp__*`) | No dedicated component — falls through to `FallbackPermissionRequest` | • Title: "Tool use"<br>• Body: `userFacingName(input)(renderToolUseMessage(input, { theme, verbose: true }))` plus optional "(MCP)" dim suffix<br>• `description` truncated to 3 lines, dimmed<br><br>**ccterm shape suggestion:** show the tool name parsed from the `mcp__<server>__<tool>` triple (split on `__`), the server name as a chip, and the input `rawInput` rendered as pretty JSON in a 200pt-cap monospace scroll. |
| `.sedEdit` | [SedEditPermissionRequest.tsx](../../../../../../ccmaster/claude-code-source/src/components/permissions/SedEditPermissionRequest/SedEditPermissionRequest.tsx) (229 lines) | Triggered by `BashPermissionRequest` when `parseSedEditCommand(command)` returns a non-null `SedEditInfo`. Renders the same body as `FileEditPermissionRequest`: reads the target file, applies the sed substitution, shows the resulting full-file diff.<br><br>**ccterm status:** the classifier already returns `.sedEdit`, but the dispatcher currently routes it to `PermissionShellCardBody` as a fallback so the user still sees the literal `sed -i …` command. To upgrade: port `parseSedEditCommand` from `tools/BashTool/sedEditParser.ts` (~250 lines, regex-heavy but pure logic — straight Swift translation), apply the substitution to the file content, build a `DiffBlock`, and dispatch `.sedEdit` to `PermissionFileWriteCardBody` (or a dedicated `PermissionSedEditCardBody` that reuses `DiffView`). |
| `.unknown` | `FallbackPermissionRequest` (see `.mcp` above) | Generic body. ccterm's current `PermissionFallbackCardBody` (single-line monospaced field from `parameter(for:)`) is the same minimal shape. Worth keeping. |

## Things to keep / not regress

- Per-kind body files colocated under `Content/Chat/InputBarControls/` with names `Permission<Kind>CardBody.swift`. Logic tests in `cctermTests/Permission<Kind>CardBodyTests.swift`.
- Pure-data getters on bodies are `internal` (not `private`) so tests can assert against them directly. This is "widening access modifier only", per `cctermTests/CLAUDE.md` — no `forceXxxForTest()` methods, no test-only init seams.
- `PermissionCardKind.kind(for:)` is the single dispatch authority. Add new branches there (and update its test) instead of switching on `request.toolName` inside the view.
- The `.barSurface(cornerRadius:)` modifier on the parent `PermissionCardView` is the only chrome. Per-kind bodies render flat — no inner cards, no extra borders.
- Don't claim a feature works on file edits if you didn't read the file. The card may be displayed before the file exists in some edge cases — every body needs a fallback when the inputs are missing or malformed.
- **String localization**: `String(localized: "…")` for every visible string. New keys go in `macos/ccterm/Localizable.xcstrings` with both `en` (source) and `zh-Hans` translations. Tests must compare against `String(localized: "…")`, **not** the bare English literal — tests run under whatever the system locale is (zh-Hans on this machine).

## Verifying changes

- `make test-unit FILTER=Permission<Kind>CardBodyTests` — fast logic test loop.
- `make test-unit FILTER=PermissionCardSnapshotTests` (opt-in) — re-render the two existing snapshots; outputs at `/tmp/ccterm-screenshots/`. Extending the snapshot suite to cover the new kinds is one of the bottom todos.
- `make test-unit` — runs the whole logic suite (~7s, 157 cases at last push).
- `make build` — confirms the app still builds. Run before opening a PR review.

## Next-session priority order

1. **`.filesystemRead`** — short and high-impact (Read/Glob/Grep are the most common tool invocations).
2. **`.taskAgent`** — Task is also frequently approved; subagent_type + prompt body is straightforward.
3. **`.skill`** — straightforward.
4. **`.mcp`** — when third-party MCP tools start hitting permission flow.
5. **`.enterPlanMode`** — needs accent-color plumbing in `PermissionCardView`.
6. **`.exitPlanMode`** — render plan as markdown in a tall scroll; defer the multi-option button matrix.
7. **`.sedEdit`** — port `parseSedEditCommand` from upstream TypeScript.
8. **`.askUserQuestion`** — last; almost certainly its own PR.
9. **Snapshot tests per kind** — one PNG per kind so reviewers can see them. Update `macos/cctermTests/CLAUDE.md` Existing snapshot tests table.

## How to drive the next session

```
Read /Users/luoyangze/code/ccterm/.claude/worktrees/relaxed-lederberg-faa3ea/HANDOFF_permission-card.md
in full, then continue from "Next-session priority order" item 1. Read
the upstream component referenced in each row before implementing.
One body + tests + push per commit, same cadence as the last 5 commits.
```

---

**Reminder — do not merge `HANDOFF_permission-card.md` into main.**
Delete or relocate before the branch is squashed.
