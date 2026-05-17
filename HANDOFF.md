# HANDOFF — input-bar picker UX alignment

Session 2 landed the work below. Branch
`claude/loving-noyce-6b2731`; baseline before this work was
`367b9d1 docs: add HANDOFF.md for next session`.

## Ground truth (don't repeat the reverse)

- **CLI is the only source.** `/tmp/claude-init-models.json` (captured
  via `/tmp/probe_claude_models.py`) is the real `init.models[]`
  payload. Three entries — `default` / `sonnet` / `haiku` — with
  per-model `supportsEffort` / `supportedEffortLevels` /
  `supportsAdaptiveThinking` / `supportsAutoMode`. **No
  `supportsFastMode` field exists.** Only `default` declares
  `supportsAutoMode == true`.
- **Claude.app is NOT a reference for visuals.** Its renderer
  (`/Applications/Claude.app/Contents/Resources/app.asar` → unpack with
  `npx asar extract`) is a Vue framework shell with no business UI
  strings — the picker chrome must live in a webview / remote page.
  All picker logic in CCTerm anchors to CLI data, not Claude.app's
  5-row expansion.
- **ccmaster** (`/Users/luoyangze/code/ccmaster/claude-code-source`) is
  the authoritative reference for *behavior*:
  - `src/utils/effort.ts → getDefaultEffortLevelForOption` falls back
    to `'high'`.
  - `src/utils/permissions/PermissionMode.ts` maps permission modes to
    theme color keys (text / planMode / autoAccept / error / warning).
  - `src/utils/theme.ts` carries the light/dark RGB tables for those
    keys.

## Spec implemented

| # | Rule | Code |
|---|---|---|
| S1 | Model rows = `ModelStore.models` original entries. No expansion, no `default` filtering. No fallback to "first as default" — `handle.model == nil` shows the trigger as "Model" and no row is checked. | `ModelEffortPicker.swift` |
| S2 | Picker row primary line = `info.value` (raw `default` / `sonnet` / `haiku`). Secondary line = `info.description` (smaller, secondary color). | `ModelEffortPicker.ModelPopoverRow` |
| S3 | Effort levels strictly from active model's `supportedEffortLevels`. Section hidden when nil/empty or `supportsEffort != true`. | `ModelEffortPopoverContent.activeEffortLevels` |
| S4 | **Per-model effort default**, persisted in `UserDefaults`. First-time table: `default → xhigh`, `sonnet → high`, fallback → `high` (matches ccmaster's `'high'` final fallback). On model switch, the resolved default auto-applies via `handle.setEffort`, clamped to the new model's `supportedEffortLevels`. | `EffortDefaultStore.swift` |
| S5 | Fast mode toggle is **always enabled**. CLI doesn't ship `supportsFastMode` so there's nothing to gate on; the CLI itself rejects fast-mode on incompatible models. | `ModelEffortPicker.FastModeToggleRow` |
| S6 | Permission `auto` row in popover is gated by `model.supportsAutoMode == true`. Hidden otherwise — never blanks the picker (default/plan/acceptEdits/bypass stay visible). | `PermissionModePicker.visibleModes(for:)` |
| S7 | Permission trigger tint follows ccmaster's per-mode theme key. Light/dark dual via `NSColor(name:dynamicProvider:)`. Popover rows are NOT tinted (a row label is an option, not the active mode). | `PermissionMode+Color.swift` |
| S8 | Context ring always renders; empty state = 0% ring (no `> 0` guard). | `ContextRingButton.swift` |
| S9 | `ModelStore.prefetchIfNeeded` no longer short-circuits on a non-empty disk cache. Disk cache only seeds the UI for cold start; every launch refetches. In-flight dedupe is preserved (the only guard left). | `ModelStore.prefetchIfNeeded` |

## Files

| Added | |
|---|---|
| Services / per-model effort memory | [EffortDefaultStore.swift](macos/ccterm/Services/EffortDefaultStore.swift) |
| Permission trigger tint (light/dark) | [PermissionMode+Color.swift](macos/ccterm/Models/PermissionMode+Color.swift) |
| Tests | [EffortDefaultStoreTests.swift](macos/cctermTests/EffortDefaultStoreTests.swift), [PermissionModePickerVisibilityTests.swift](macos/cctermTests/PermissionModePickerVisibilityTests.swift) |

| Modified | |
|---|---|
| Per-launch prefetch | [ModelStore.swift](macos/ccterm/Services/ModelStore.swift) |
| Row layout + auto-apply effort + fast-mode always-on | [ModelEffortPicker.swift](macos/ccterm/Content/Chat/InputBarControls/ModelEffortPicker.swift) |
| Tint + auto-row gating + activeModel injection | [PermissionModePicker.swift](macos/ccterm/Content/Chat/InputBarControls/PermissionModePicker.swift), [InputBarSessionChrome.swift](macos/ccterm/Content/Chat/InputBarControls/InputBarSessionChrome.swift) |
| Always-render ring | [ContextRingButton.swift](macos/ccterm/Content/Chat/InputBarControls/ContextRingButton.swift) |
| Public `PopoverRowHoverStyle` for two-line rows | [PopoverList.swift](macos/ccterm/Content/Chat/InputBarControls/PopoverList.swift) |
| Fast-mode comment | [SessionHandle2.swift](macos/ccterm/Services/Session/SessionHandle2/SessionHandle2.swift) |
| Snapshot fixture refreshed to real `default/sonnet/haiku` shape | [InputBarSnapshotTests.swift](macos/cctermTests/InputBarSnapshotTests.swift) |

| Deleted | |
|---|---|
| Display rewrite helpers (`conciseDisplayName` / `displayParts` / `isDefaultMeta`) — replaced by raw `value` + `description` | `Models/ModelInfo+Display.swift` |
| Tests for the deleted helpers | `cctermTests/ModelInfoDisplayTests.swift`, `cctermTests/ModelEffortPickerResolverTests.swift` |

## Verification

- `make fmt` — clean.
- `make build` — Debug build succeeds (~6s).
- `make test-unit` — could not be observed: while this session ran, a
  parallel `xcodebuild` from another worktree
  (`/Users/luoyangze/code/ccterm/.claude/worktrees/nice-cannon-0b70b2`)
  kept a `com.ccterm.app`-bundle `ccterm.app` host process alive, which
  blocks the second worktree's xctest harness from completing the IPC
  handshake (xcresult: "The test runner hung before establishing
  connection" — confirmed reproducible on `main` baseline once the
  other worktree was active, so it is NOT caused by these changes).
  Re-run after the other worktree's xctest cycle ends.

## Probe script (kept for the next reverse)

`/tmp/probe_claude_models.py` — spawns `claude` with the AgentSDK
argv (`--output-format stream-json --verbose --input-format
stream-json --permission-prompt-tool stdio --replay-user-messages
--allow-dangerously-skip-permissions`), sends an `initialize`
control_request with `promptSuggestions: false`, and dumps the
matching `control_response.response.models[]` to
`/tmp/claude-init-models.json`. Re-run if the CLI ships fields we
haven't seen.

## Out-of-scope reminders (still apply)

- Don't touch session bootstrap / transcript.
- Don't add `forceXxxForTest()` seams or `#if DEBUG` UI branches.
- Don't re-introduce `String(localized:)` on picker labels.
- Tests must not read/write `UserDefaults.standard` —
  `EffortDefaultStore` accepts an injected `UserDefaults` for tests
  (see `EffortDefaultStoreTests.setUpWithError`).
