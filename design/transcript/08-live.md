# 8 · Live sessions — the New tab and the composer

How a session is started and steered from ccterm: the **New tab** where a
session is set up, the **+** that makes one, and the **composer** at the
bottom of a session tab. Facts about the CLI are from `claude` 2.1.286 in
stream-json mode (the bundle beautified and probed, see *Sources*); facts
about the app are from `macos/` at #327.

## The idea: before the first prompt it's a form, after it's a conversation

A session's settings reach the CLI in two different ways, and the two tabs
follow them.

- **A New tab is a draft.** Nothing runs. Every choice — folder, model,
  effort, permission mode — is local until **Send**, which launches the CLI
  with all of them as flags. Every choice is free, instant and reversible,
  because none of it has happened yet.
- **A session tab steers a running process.** The folder is fixed. Model,
  effort and mode go to the CLI as control requests, and each one lands at a
  different moment: the mode **now**, the effort **from the next request**,
  the model **after this turn**. The composer says which, at the moment you
  choose.

Five rules follow.

1. **One composer.** The New tab and a session tab use the same field and the
   same controls in the same order. Only the controls that can't change
   after launch (folder, account, worktree) are the New tab's alone.
2. **The control says when.** A choice that will apply later shows that on
   the control itself (*after this turn*), not in an alert or a toast.
3. **Choices only the CLI can refuse are greyed, with the reason.** A menu
   item is never hidden because it's unavailable *now* — it's disabled with
   a subtitle that says why (*Not on Haiku 4.5*, *Unavailable while Fast Mode
   is on*). Hiding moves the other items; a reason teaches the rule.
4. **The transcript records what the CLI did, the composer what you chose.**
   A model change becomes the `/model` command bubble (05-local.md) when the CLI
   applies it — the CLI echoes it as a local-command output. Effort and mode
   changes leave no row; their control is the record.
5. **Report the exception** (README). The composer is plain while things are
   normal. Coral appears only when the session waits for you, red only for
   a failure or for Bypass Permissions.

## Tabs and the +

```
 ┌ Row gap and tool rows ┐ ┌ New Session ┐ ┌ Fix gutter ┐        (+)
```

- **Every tab bar ends in a +.** A 24-pt circle at the trailing end of each
  editor group's bar, quaternary fill, a 10-pt plus in secondary ink —
  Ghostty's control, at the sheet's scale. Hover lifts the fill one step and
  shows the tooltip **New Tab ⌘T**. In a split each group has its own, and it
  opens the New tab in *its* group.
- **⌘T** opens a New tab in the focused group, after the active tab. If that
  group already has an untouched New tab, ⌘T selects it instead of adding a
  second (an empty draft is not worth two tabs). File › New Tab ⌘T replaces
  File › New Session… ⌘N and its folder sheet: the folder is chosen in the
  New tab. ⌘N stays as a second key for the same command.
- **No tabs, no bar.** When the window has no tabs at all, the editor area *is*
  a New tab without its tab: the same New view, centred, no bar and no + (the
  New view is already there). This replaces today's *No Editor*. Sending from
  it opens the session as the first tab and the bar appears.
- **A New tab's title** is *New Session*, upright (it is a pinned tab, not a
  temporary one). On Send it becomes the prompt's first line, cut at 40
  characters; when the CLI names the session (`session_title_changed`, or
  ccterm asks with `generate_session_title` after the first turn) the tab and
  the sidebar take that name.
- **Activity in the tab.** A session tab shows the sidebar's mark in the slot
  its close button uses: the running arc while Claude works or starts, a
  coral dot when it waits for you, a red dot when it failed. Idle and at rest
  show nothing (unlike the sidebar, the tab bar has room only for exceptions).
  Hover swaps the mark for ×, as Safari swaps a tab's speaker.
- **Closing tabs.** Closing a session tab ends nothing — a live session
  outlives its tab, as it does today. Closing a New tab drops the draft's
  settings. Its text is kept, and the next New tab in the window opens with it.

## The New view

```
                              ◆                          coral session glyph, 32 pt
                          ccterm ⌄                       folder: 22-pt pop-up
                     ~/dev/ccterm · main                 11-pt tertiary
     ┌──────────────────────────────────────────────┐
     │ Ask Claude to…                                │    the composer, 640 pt
     │                                               │
     │ Opus 5.5 ⌄   ▂▄▆ High ⌄   ✧ Auto ⌄       (↑)  │
     └──────────────────────────────────────────────┘
                 ↩ Send   ⇧↩ New Line   ⇧⇥ Mode          11-pt tertiary, while empty
```

- **Centred**, vertically a third of the way down rather than at the centre
  (the optical centre, the way Spotlight's field sits).
- **The decoration is the session glyph**: the sidebar's coral conversation
  squircle at 32 pt, with a soft coral halo (12 %, 24-pt blur). It is what
  this tab will wear in the sidebar. It is the only coloured thing on the page.
- **The folder is the title**, because it is the one choice that can't be
  undone: a 22-pt semibold pop-up with the folder's name, its path and git
  branch under it in 11-pt tertiary. Its menu:
  - **Recent** — the sidebar's projects, most recent first, eight at most;
  - **Choose Folder… ⌘O** — an open panel (*Choose the folder Claude will
    work in.*);
  - **New Worktree** — a checkbox (`--worktree`): *Claude works on a new
    branch in .claude/worktrees*. Off by default, and turned off when the
    folder changes.
- **Default folder**: the folder of the session tab that was active when ⌘T
  was pressed; otherwise the most recent project.
- **Account** — a chip after Mode, *only when Settings has more than one
  account*. It chooses the launch environment, so it lives here only.
- **Defaults for model, effort and mode** are the last ones chosen in a New
  tab (an app preference); the first time, the CLI's own: `Default
  (recommended)`, the model's default effort, and the CLI's
  `current_permission_mode`. *Default* follows the CLI's setting rather than
  pinning a model.
- **Typing `/`** at the start of the field opens command completion above the
  field (see *Slash commands*).
- **Send** (↩, or the arrow) launches. The page turns into the session tab in
  place: the prompt appears as the first bubble at once, the composer glides
  from its centre to the bottom (0.3 s, ease-out; Reduce Motion: a
  cross-fade), and the tab enters *Starting*.

**Where the menus get models before any session runs.** ccterm keeps a
**catalog** — `initialize`'s `models` (with each one's `supportedEffortLevels`,
`supportsFastMode`, `supportsAutoMode`), `commands`, `account`,
`fast_mode_state` and `current_permission_mode`. It's read from a short-lived
CLI started once per launch configuration (at app start and whenever
Settings changes the command or the config folder), then cached on disk. A
New tab never waits on it; the very first launch shows *Loading…* in the
menus for the second it takes. The CLI writes no transcript until the first
prompt, so this leaves nothing in the sidebar.

## The composer

```
┌────────────────────────────────────────────────────────────────┐
│ Message Claude                                                   │  14 pt, grows 1 → 8 lines
│                                                                  │
│ Sonnet 5.5 ◷ ⌄   ▂▄▆█ Extra High ⌄   ✎ Accept Edits ⌄    ◔ 72 %  (■)│  accessory row, 28 pt
└────────────────────────────────────────────────────────────────┘
```

- **The card.** 720 pt wide at most, centred in the tab (the transcript's
  column plus its margins), 16-pt radius, window background, a hairline and a
  soft shadow; it floats 16 pt above the tab's bottom edge and the transcript
  scrolls under it. Focus adds a 1-pt accent ring at 45 % with a 4-pt accent
  halo at 12 %.
- **The accessory row** is three pull-down buttons, a status slot, and the
  action button. Each pull-down is borderless, 24 pt tall, 12-pt secondary
  text with its glyph, and a chevron; hover gives it the hover fill. Their
  menus are NSMenus with item subtitles (`NSMenuItem.subtitle`, macOS 14.4)
  and section headers.
  - **Model** — the model's short name. *Fast* adds a bolt before it.
  - **Effort** — a 5-bar level glyph filled to the level, then its name. The
    bars are the page's one bit of ornament in the composer.
  - **Mode** — the mode's glyph and short name. Bypass is red, glyph and text;
    every other mode is secondary.
- **The action button** is a 28-pt circle: an accent arrow when there is text
  to send, a grey disabled arrow when the field is empty, a stop square
  (label fill) while Claude works. Working *and* text in the field shows both,
  stop to the left.
- **The status slot** (11-pt, tertiary, before the button) is empty unless
  something is out of the ordinary: *Starting Claude…*, *Compacting…*, *Will
  resume when you send*, or the coral *Waiting for you ↑* when the request
  that waits has scrolled out of view (click scrolls to it).
- **Context.** A 14-pt ring with a percentage appears in the status slot once
  the context is half full (`get_context_usage` after each turn); click opens
  `/context` beside. Below half, it isn't shown.
- **Errors** (a send refused, a model the organisation doesn't allow) are one
  12-pt red line under the card, and the control reverts.

### Model

Items come from the catalog, in its order. The top level holds the default and
the current families; older models sit in **Other Models ▸**.

```
  Default (recommended)          ← subtitle: Opus 5.5
✓ Opus 5.5
  Fable 5.1
  Sonnet 5.5
  Haiku 4.5
  ─────────
  Other Models                ▸
  ─────────
  ⚡︎ Fast Mode                    ← subtitle: Faster output on Opus · billed as extra usage
```

- **Fast Mode** is a checkbox for models with `supportsFastMode`. On others it's
  disabled: *Opus 5.5, Opus 5 and Opus 4.8 only*. When the account can't use
  it, the subtitle is `fast_mode_disabled_reason` in words (*Requires extra
  usage*). ccterm opts in with the flag setting `fastMode: true`, which the CLI
  requires from an SDK host. Turning Fast on turns Auto mode off (the CLI
  refuses Auto with Fast); switching to a model without Fast turns Fast off.
  Both cascades show on the chips at once.
- **While Claude works** the menu opens with the section header *Applies after
  this turn*. The chip takes the new name at once, with a 10-pt clock after it
  in tertiary (tooltip *Switches after this turn*). When the turn ends the
  CLI applies it, echoes *Set model to Sonnet 5.5*, the `/model` bubble
  appears in the transcript, and the clock goes.
- **While idle** the change is sent at once; the CLI checks entitlement first
  (≈ 1.5 s). The chip shows the new name and the bubble follows. If the CLI
  refuses (`restricted_by_org`, `catalog_unknown`), the chip reverts and the
  reason is the red line under the card.

### Effort

```
  EFFORT · OPUS 5.5
  ▂     Low
  ▂▄    Medium
✓ ▂▄▆   High                    ← subtitle: Default
  ▂▄▆█  Extra High
  ▂▄▆██ Max                     ← subtitle: This session only
```

- Levels are the model's `supportedEffortLevels`. The others are listed but
  disabled — *Not on Sonnet 4.6* — so the scale reads the same everywhere.
- The model's default effort is marked *Default*. *Max* isn't saved by the CLI
  beyond the session; its subtitle says so.
- **A model with no effort** (Haiku 4.5): the chip is disabled, showing *—*,
  tooltip *Haiku 4.5 doesn't take an effort level*. It isn't hidden, so Mode
  doesn't move.
- **Switching to a model without the level**: the CLI runs it as High. The chip
  shows *High* — what will actually run — and the menu's disabled item says
  why. Switching back restores the choice.
- Applied **from the next request**, mid-turn included. No clock: by the time
  you could look, it has applied.

### Permission mode

```
  PERMISSION MODE         ⇧⇥
  ◇ Ask Permissions       Asks before edits and commands
  ✎ Accept Edits          Edits files without asking; asks before commands
  ▤ Plan                  Reads and plans; changes nothing
✓ ✧ Auto                  Approves safe actions, asks when unsure
  ⊘ Don't Ask             Runs only what's already allowed
  ─────────
  ⚠︎ Bypass Permissions    Runs everything without asking   (red)
```

- **⇧⇥ in the field cycles** Ask → Accept Edits → Plan → Auto, the CLI's own
  key. Don't Ask and Bypass are reached only from the menu.
- **Auto** needs a model with `supportsAutoMode` and Fast off; otherwise
  disabled with the reason. When the model changes to one without it, the mode
  steps down to Ask and the chip shows it. (The CLI does this when it starts a
  session in Auto on such a model; the step-down on a model *change* is
  ccterm's to do and needs verifying against the CLI.)
- **Bypass Permissions** can be entered only by a CLI launched with
  `--allow-dangerously-skip-permissions`, a launch decision. Settings ›
  General gets one checkbox, **Allow Bypass Permissions** (off). When it's on,
  every launch carries the flag and the item is enabled. When it's off the
  item is disabled: *Allow it in Settings › General*.
- Applied **now**, mid-turn included: the next tool call is checked against
  the new mode. The CLI confirms with `system/status`, which updates the chip.
  A request already waiting stays waiting — a mode change doesn't answer it.

### Slash commands

`/` at the start of the field opens a list above the card: the catalog's
`commands` (refreshed by `commands_changed`), 28-pt rows, the name in SF Mono
12 and its argument hint in tertiary, the description in secondary. Typing
filters it, ↑ ↓ move, ↩ or ⇥ completes. A completed command becomes the
token the transcript's bubble draws (05-local.md): mono, on an inset of the
field's own fill. Backspace into it removes it whole. `/model` and `/effort` typed out still
work. The CLI runs them, and the chips follow its echo.

## Settings × state

What each control does in each state: whether it can be chosen, **when** it
applies, and **how** ccterm sends it. The two tabs are the two halves.

|  | **New tab** | **Starting** | **Idle** | **Responding** | **Waiting for you** | **At rest** | **Failed** |
|---|---|---|---|---|---|---|---|
| **Folder** | choose · `cwd` | — fixed | — | — | — | — | — |
| **Worktree** | toggle · `--worktree` | — | — | — | — | — | — |
| **Account** | choose (> 1) · env | — | — | — | — | — | — |
| **Model** | choose · `--model` | choose · held, sent when ready | `set_model` · ≈ 1.5 s, `/model` bubble | choose · **after this turn** ◷ | after this turn ◷ | choose · `--model` on resume | choose · `--model` on restart |
| **Fast** | toggle · `fastMode` flag setting | held | `apply_flag_settings` | after this turn ◷ | after this turn ◷ | flag on resume | flag on restart |
| **Effort** | choose · `--effort` | held | `apply_flag_settings` · next request | next request | next request | `--effort` on resume | `--effort` on restart |
| **Mode** | choose · `--permission-mode` | held | `set_permission_mode` · now | now | now (the request stays) | `--permission-mode` on resume | on restart |
| **Send ↩** | launches | held, shown dim | sends | queues | queues | resumes, then sends | restarts, then sends |
| **Stop ⌘.** | — | cancels the launch | — | `interrupt` | `interrupt` (the request is withdrawn) | — | — |

*Held* means the composer keeps the change until `initialize` returns, then
sends it. The user sees no difference from an applied change.

## States of a session tab

| State | From | The composer | The tab |
|---|---|---|---|
| **Starting** | Send in a New tab; Send in a tab at rest or failed | *Starting Claude…*, stop button cancels | arc |
| **Idle** | `initialize` answered; a turn's `result` | plain | — |
| **Responding** | a prompt sent, until its turn's `result` | stop; text in the field queues | arc |
| **Waiting for you** | a permission request, question or plan | stop; coral *Waiting for you ↑* when it is off screen; ⌘↩ / ⎋ answer the request | coral dot |
| **Compacting** | `system/status` = `compacting` | *Compacting…*; the transcript's live divider (05-local.md) | arc |
| **At rest** | no CLI: never started here, `/exit`, End Session, quit | *Will resume when you send*; chips show the session's last settings | — |
| **Failed** | the CLI exited non-zero | a red banner over the card: *Claude exited (code 1)*, stderr's last line, **Show Log**, **Restart** | red dot |

- **Starting is a real state.** Launch runs a login-shell environment probe
  that can take seconds. Today the tab shows the at-rest page with Send
  enabled; here the tab says it's starting and the prompt waits, dim, in its
  bubble until the CLI takes it. The probe's result should be reused across
  launches in an app run, so only the first launch pays for it.
- **Failure shows in the tab.** Today only the sidebar's red mark says so,
  and Send silently resumes. The banner says what happened. **Restart** is
  Send's resume without a prompt.
- **At rest, the chips show the session's last settings** — the last
  assistant entry's `model` and `effort`, the last user entry's
  `permissionMode` — and resume passes them as `--model`, `--effort` and
  `--permission-mode`. A plain `--resume` would start on the settings' default
  model instead, and the conversation would change model without anyone
  asking. A last mode of Bypass resumes as Ask when Settings no longer allows
  Bypass, and the chip says so.

## Sending while Claude works

- **↩ queues.** The prompt is sent with the CLI's default priority, `next`. The
  CLI folds it into the running turn at the next tool boundary, or runs it
  after the turn. Until the CLI starts it (`msg_lifecycle`: queued → started),
  its bubble sits at the end of the transcript at 50 % opacity, with
  *Queued* under it, and a × on hover that withdraws it
  (`cancel_async_message`). Once started, it is an ordinary bubble.
- **⌘. stops** (the Mac's Cancel). Esc stays with the permission card (⎋
  denies), as 01-run.md has it. Stopping keeps queued prompts. The CLI runs
  them next.
- **Not exposed**: priority `now` (interrupt and send in one key — Stop, then
  Send, says the same thing in two). The thinking budget is not exposed
  either: effort is the CLI's control for it, and `ultrathink` in a prompt
  still works.

## Keys

| Key | Where | Does |
|---|---|---|
| ⌘T | anywhere | New tab in the focused group |
| ⌘W | a tab | closes it (a live session keeps running) |
| ↩ / ⇧↩ | the field | send (queue while working) / new line |
| ⇧⇥ | the field | next permission mode |
| ⌘. | a session tab | stop |
| ⌘↩ / ⎋ | waiting for you | allow / deny (01-run.md) |
| ⌘O | the New view | Choose Folder… |
| / | start of the field | command completion |

## What this needs from the code (for the PR that builds it)

- AgentSDK: make `setModel` and `setPermissionMode` public. Decode
  `session_title_changed`, `system/status.permissionMode` and
  `per_turn_effort_changed`. Expose `cancel_async_message`, `get_context_usage`
  (exists) and `list_models`.
- `LiveSession` keeps the `initialize` result instead of discarding it. The
  catalog, cached on disk, is built from it.
- `SessionState` gains: `starting`, `compacting`, current model / effort / mode
  / fast, a pending model, queued prompts.
- `SessionStore.start` takes model, effort, mode, fast, worktree and account.
  Resume passes the transcript's last settings.
- Settings › General: *Allow Bypass Permissions*.
- TranscriptKit's workspace: an empty area hosts a view supplied by the app
  (the New view) instead of *No Editor*. Each group's tab bar gets a trailing
  accessory (the +).

## Sources

- CLI 2.1.286, beautified (`all.pretty.js`):
  - control dispatcher in `print.ts` (~1087600);
  - schemas `set_model`, `set_permission_mode` and `apply_flag_settings` (94224–94946);
  - `ModelInfo` (92641) and its builder (292534);
  - effort levels and their downgrade (35456, ~156560);
  - permission-mode validation (636398).
- Live probes on the same version:
  - `initialize` returns the models, their effort levels and `current_permission_mode`;
  - `set_permission_mode` → `system/status`;
  - `set_model` ack ≈ 1.5 s, echoed as a `/model` local-command output;
  - `bypassPermissions` refused without the launch flag (`bypass_not_launched`);
  - no transcript file until the first user message.
- App: `SessionStore.start(in:)` (folder only), `LiveSession.start()`
  discards the `initialize` result, and `ComposerView`'s Return sends
  mid-turn.
