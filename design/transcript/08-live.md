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
   after launch (folder, worktree) are the New tab's alone. The account is
   not a control: it follows the model (see *Model*).
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

## The sidebar and the conversation icon

The sheet's window draws the sidebar as `SidebarViewController` does today:
a source list, 22-pt rows, a 14-pt indent per level, the disclosure
triangle, a 16-pt icon at +13 and the title at +34, activity marks at the
trailing end, the selection a rounded inset 10 pt from each side. Projects
wear the system folder icon. A worktree session adds a small branch glyph
after its title in tertiary.

**The conversation icon is white**, as a Mac document is: white paper with
its kind's emblem, the way a Swift file is white with an orange bird. Today's
is a coral template glyph; on a sidebar of system folders it reads as a
badge, not a thing.

- **Shape.** A speech bubble — a Lamé squircle (n = 4, the family of every
  ccterm glyph) 13 × 10 pt with a tail to the lower left — white
  (`#FFFFFF`; `#F5F5F7` in Dark), edged with a 0.55-pt line at 34 % black
  (50 % in Dark) so it holds on a white or a selected row. The edge is
  drawn under the fill, so the tail joins the body without a seam.
- **Emblem.** The app icon's prompt, small: a chevron in system grey
  (`#6E6E73`) and the cursor as one solid block in coral (`#FF6E7C`, the
  middle of the icon's ramp). One mark in one colour, as a Mac document wears
  its kind: a ramp at 16 pt is three colours fighting for four pixels.
- **Full colour, not a template**, so it stays itself on a selected row, as
  Finder's icons do. The build (`design/sidebar-icons/src/build.ts`) emits
  it as a colour asset, and the sidebar stops tinting it.
- Subagent rows keep their Lamé star; the activity marks are unchanged.

## The New view

```
                             ▣                           app icon, 64 pt, a soft glow
                          ccterm ⌄                       folder: 22-pt pop-up
                       ~/dev/ccterm                      11-pt tertiary
                  ⑂ main ⌄    ⧉ Worktree                 branch pop-up · toggle; git folders only
        A new branch from main, in a new worktree        what Send will do; height kept
     ┌──────────────────────────────────────────────┐
     │ Ask Claude to…                                │    the composer, 640 pt
     │                                               │
     │ Opus 5.5 ⌄   ▂▄▆ High ⌄   ✧ Auto ⌄       (↑)  │
     └──────────────────────────────────────────────┘
                 ↩ Send   ⇧↩ New Line   ⇧⇥ Mode          11-pt tertiary, while empty
```

- **Centred**, vertically a third of the way down rather than at the centre
  (the optical centre, the way Spotlight's field sits).
- **The decoration is the app icon** (`design/icon`, the shipped pixels) at
  64 pt — the page is the app's own front door. Behind it, a glow made of the
  icon's cursor ramp (peach → coral → violet): a vertical gradient under a
  radial mask, 20-pt blur, at 60 % of its full strength (42 %, 36 % in Dark).
  It is the only coloured thing on the page, and **it holds still**: nothing
  on the page moves while you read or type.
- **Send is the one moment it moves — once, like a level meter rising.** A
  light passes up the icon's cursor, row by row from the bottom, and the glow
  swells upward to full strength with it. Then the page hands over (the prompt
  becomes the first bubble, the composer glides down). Until then the prompt
  stays in the field, dimmed, so nothing vanishes while the light rises.
  - **600 ms, decelerating.** Each row lights when an ease-out level reaches
    it: onsets at 0, 70, 150, 240 and 340 ms (65k + 5k²), each a 240-ms flash
    to 55 % white; the glow swells on `cubic-bezier(.2, .7, .2, 1)` over the
    same 600 ms. The first row answers Return within a frame — the feedback
    is immediate — and the top arrives slowly, so the end reads as arriving,
    not stopping.
  - **Why 600.** Under ~400 ms the five rows blur into one flash and nothing
    reads as rising; past ~800 ms it reads as waiting, with your prompt held.
    And it costs nothing: the CLI's launch starts at Send and takes longer
    (the login-shell probe alone is ≥ 1 s), so the rise fills time the launch
    takes anyway; the tab shows *Starting* for the rest.
  - **Reduce Motion:** no rise; the page hands over at once.
- **In Dark the icon is the system's Dark rendition**, not the Default one
  laid on a dark window. `ictool --rendition Dark` turns the plum plate a
  neutral near-black (≈ `#1F1F21` → `#0E0E0F`) and keeps the Liquid Glass
  rim, a white edge lit at the top (≈ 34 %) and bottom (≈ 20 %). That rim,
  not the plate, is what sets the icon off a dark window. The implementation
  must draw the rendition of the view's effective appearance: if
  `NSApp.applicationIconImage` doesn't follow the appearance (to be verified
  on macOS 26), `design/icon`'s build exports the Default and Dark renders
  into an image set with Any / Dark appearances.
- **The folder is the title**, because it is the one choice that can't be
  undone: a 22-pt semibold pop-up with the folder's name, its path and git
  branch under it in 11-pt tertiary. Its menu:
  - **Recent** — the sidebar's projects, most recent first, eight at most;
  - **Choose Folder… ⌘O** — an open panel (*Choose the folder Claude will
    work in.*).
- **Branch and Worktree** sit on one row under the path: a borderless
  pop-up with the branch glyph and name, and a toggle button, **Worktree**
  (accent-tinted when on, `aria-pressed`). Both are choices *about* the
  folder, so they sit under it, not in its menu. **The row never moves**: the
  toggle doesn't change either control's text, and what the choices add up to
  is said on the line under the row — 11-pt tertiary, its height kept when it
  has nothing to say, so the composer doesn't jump either:
  - in place, on the checked-out branch: nothing;
  - in place, another branch: *Switches to fix-gutter-overflow when you send*;
  - Worktree on: *A new branch from main, in a new worktree*;
  - a pull request: *Pull request #327, in a new worktree*.
- **The branch pop-up opens a popover with a filter**, as Xcode's toolbar
  branch picker does: a search field (focused, 26 pt) over the list,
  sections *Local* and *Remote* (a remote branch with a local twin is listed
  once), 360 pt at most, then it scrolls. Typing filters; ↩ takes the first
  match. Typing `#327` adds *Pull Request · #327 — Checked out in a new
  worktree*, and choosing it turns Worktree on.
- **What the branch means depends on Worktree.**
  - **In place** it's the branch Claude works on. The checked-out one is
    marked *Checked out here*. Another one is checked out with `git switch`
    when you send — ccterm's step, not the CLI's. Greyed, with the reason,
    when git would refuse or it would carry your work along: *Checked out in
    another worktree*; *Uncommitted changes here — use a worktree*.
  - **With a worktree** it's where the new branch starts, and every branch
    can be chosen. The CLI's `--worktree` starts from `worktree.baseRef`
    only — *fresh* (origin's default branch) or *head* (the local HEAD) —
    so ccterm passes `--settings {"worktree":{"baseRef":"head"}}` for the
    checked-out branch, nothing for origin's default, and for any other
    branch makes the worktree itself (`git worktree add -b <name>
    .claude/worktrees/<name> <branch>`) and launches the CLI in it. A pull
    request is the CLI's own: `--worktree #327`.
- **Worktree** is off by default, and off again when the folder changes (the
  branch goes back to the checkout's). Turning it off returns a branch that
  can't be had in place to the checkout's. **Only a git folder has the row** —
  the CLI refuses `--worktree` elsewhere (*Can only use --worktree in a git
  repository*). A folder that isn't one shows *Not a git repository* in its
  place, at the same height. A worktree session's tab title and sidebar row
  carry its branch (*quiet-otter · worktree*, *pr-327 · worktree*).
- **Default folder**: the folder of the session tab that was active when ⌘T
  was pressed; otherwise the most recent project.
- **No account control.** The account is chosen by choosing a model (see
  *Model*); a provider model's chip names its provider.
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
  cross-fade), and the tab enters *Starting* — after the rise (above).

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
  column plus its margins), the card radius (see *One shape language*), window background, a hairline and a
  soft shadow; it floats 16 pt above the tab's bottom edge and the transcript
  scrolls under it. Focus adds a 1-pt accent ring at 45 % with a 4-pt accent
  halo at 12 %.
- **The accessory row** is three pull-down buttons, a status slot, and the
  action button. Each pull-down is borderless, 24 pt tall, 12-pt secondary
  text with its glyph, and a chevron; hover gives it the hover fill. Their
  menus are NSMenus with item subtitles (`NSMenuItem.subtitle`, macOS 14.4)
  and section headers — except Model's, a panel with a height limit (see
  *Model*).
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
  that waits has scrolled out of view (click scrolls to it). It is never
  truncated: when the composer narrows, the chips drop their words first
  (the provider name, then the effort and mode names — glyphs and tooltips
  remain), and below 380 pt the status takes a line of its own under the
  chips.
- **Context.** A 14-pt ring with a percentage appears in the status slot once
  the context is half full (`get_context_usage` after each turn); click opens
  `/context` beside. Below half, it isn't shown.
- **Errors** (a send refused, a model the organisation doesn't allow) are one
  12-pt red line under the card, and the control reverts.

### Model

**One menu, sectioned by account.** Settings keeps several accounts — the
Claude subscription and API providers (a relay, DeepSeek, …) — and its design
already decides that *there is no default account: the account follows from
the model*. A provider's models only exist under that provider; *Claude Max ·
DeepSeek-V3* is not a pair anyone can choose. So the menu lists models, and
each account is a section of it, in Settings' order:

```
  ┌──────────────────────────────────────────────┐
  │ ✦ Claude Max  Subscription                    │  sticky section header
  │   Default (recommended)    Opus 5.5           │
  │ ✓ Opus 5.5                                    │
  │   Fable 5.1 · Sonnet 5.5 · Haiku 4.5          │
  │   7 More Models                               │  expands in place
  │ ▤ Work Relay  relay.example.com  Restarts the session │
  │   Default · Opus · Sonnet · Haiku           ↻ │
  │ ▤ DeepSeek  api.deepseek.com                  │
  │   Default                                   ↻ │  ↕ scrolls, 360 pt at most
  │ ───────────────────────────────────────────── │
  │ ⚡︎ Fast Mode                            ( ●) │  a switch, outside the scroll
  └──────────────────────────────────────────────┘
```

Two pop-ups (account, then model) were the alternative and lose on three
counts: the first one's only job is to filter the second; changing it would
have to pick a model on your behalf; and both would mean *restart* while only
one says so. With one menu, the only expensive choice — a model in another
account — is marked where it is chosen.

- **A panel, not an NSMenu**, because it has a height limit: 360 pt, then it
  scrolls, with each account's header sticking to the top as its models pass
  under it. A borderless child panel with the menu material, NSMenu's metrics
  (22-pt rows, 5-pt inset, 12-pt radius), keyboard navigation and
  type-select. Fast Mode sits under the scroll, always visible.
- **Older models** of an account fold into one *N More Models* row that
  expands in place (the panel stays open, the scroll stays put). The current
  model is never folded.
- **A section header** is the account's mark (the Claude mark for the
  subscription, a server glyph for a provider), its name, and its detail in
  tertiary (*Subscription*, the provider's host).
- **The chip** shows a provider model as *Sonnet  Work Relay* — the provider's
  name in tertiary after the model, dropped first when the composer narrows.
  The subscription isn't named: it's the usual case.
- **Another account restarts the session.** The CLI reads its account from
  its environment at launch; nothing in the control protocol changes it.
  While a process runs (Idle, Responding, Waiting), the other sections' header
  says *Restarts the session* and their items carry ↻. Choosing one opens a
  sheet on the window:

  > **Restart this session as Work Relay?**
  > Claude Code reads its account when it starts. ccterm ends this session's
  > process and resumes the conversation as Work Relay, on Sonnet.
  > *[Cancel]  [Restart]*

  While Claude works the text adds *Claude stops what it's doing now.*, the
  button reads **Stop and Restart**, and Cancel becomes the default button —
  Return must not throw away a turn. Restarting interrupts the turn, ends the
  process, and resumes with `--resume` plus the new environment and
  `--model`; the transcript gets a divider *Restarted as Work Relay · Sonnet*.
  At rest or failed there is no process: the choice is free and the next Send
  resumes in that account. While Starting nothing has run yet, so there is no
  alert either: the launch starts over in the new account.

- **Fast Mode** is a switch (a small `NSSwitch` at the row's trailing edge) — a
  setting that stays on, not a choice among items — so toggling it leaves the
  panel open and the chip's bolt appears behind it. Only models with
  `supportsFastMode` enable it. On others it's
  disabled: *Opus 5.5, Opus 5 and Opus 4.8 only*; on a provider's model,
  *Only with the subscription*. When the account can't use
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
`commands` (refreshed by `commands_changed`), 28-pt rows (a long description
wraps to a second line rather than being cut), the name in SF Mono
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
| **Branch** | choose · `git switch` at Send, or the worktree's base | — | — | — | — | — | — |
| **Worktree** | toggle, git folders only · `--worktree` | — | — | — | — | — | — |
| **Account** | follows the model · env | choose · the launch starts over in it | confirm → restart, resume | confirm → stop, restart | confirm → stop, restart | env on resume | env on restart |
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
| **Failed** | the CLI exited non-zero | the card's top section: a red octagon, *Claude quit unexpectedly* over *Exit code 1 · stderr's last line*, then **Show Log** and **Restart** (default) | red dot |

- **Starting is a real state.** Launch runs a login-shell environment probe
  that can take seconds. Today the tab shows the at-rest page with Send
  enabled; here the tab says it's starting and the prompt waits, dim, in its
  bubble until the CLI takes it. The probe's result should be reused across
  launches in an app run, so only the first launch pays for it.
- **Failure shows in the tab.** Today only the sidebar's red mark says so,
  and Send silently resumes. The card says what happened, in its own top section (a 6 % red wash, a hairline under it) — not a strip with a radius of its own above it. It reads as a notification does: symbol, title over detail, buttons trailing; narrow, the buttons move under the text. **Restart** is
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

## A prompt, from Send to the transcript

The CLI is launched with `--replay-user-messages`: every prompt ccterm writes
comes back on stdout as a `user` message with `isReplay: true` and **the
same `uuid`** (`UserInput.uuid`), and only then is it in the transcript file.
`Transcript.append` keeps it once, by uuid. Between the two the CLI reports
the prompt's fate with `command_lifecycle` (`queued` → `started` →
`completed` / `cancelled` / `discarded` / `refused`).

Measured with `QueueTimingSmoke` (2.1.286, Haiku, streaming):

| | idle | sent while a turn runs |
|---|---|---|
| `lifecycle.queued` | 2 ms | 1 ms |
| `lifecycle.started` | 3 ms | when the running turn ends (or at its next tool boundary) |
| **replay** | **2.1–2.6 s**, with the first streamed token | with `started`, or up to 0.7 s after it |
| `result` | 3.8 s | — |

So the replay is not an acknowledgement — it's the CLI writing the prompt
into the conversation, as the model's request goes out. **Drawing the bubble
only on the replay would leave the prompt invisible for two seconds after
Send**, and today's app does exactly that. Instead the bubble is drawn at
Send, keyed by its uuid, and each later signal changes it:

| State | Signal | The bubble |
|---|---|---|
| **Held** | the CLI is starting | dimmed (50 %), *Sent when Claude is ready* under it; Stop returns its text to the field |
| **Queued** | `queued` while a turn runs | dimmed at the end of the transcript, *Queued · Withdraw* (`cancel_async_message`) |
| **Sent** | `started`, no replay yet | full strength, **no label**. A sent bubble is just a bubble, as in Messages; the working indicator under it says Claude has it |
| **Confirmed** | the replay, same uuid | **nothing changes**: the transcript's message takes the local bubble's place. A queued prompt the CLI folds into a running turn moves once, from the end to where the CLI put it (after the tool result it was folded at), in one 0.25-s slide |
| **Not sent** | `refused`, `discarded`, or the process exits before the replay | stays, with a red mark: *Not sent — the session ended* (or the refusal's reason) and **Resend** |
| **Stopped before it was read** | Stop after `started`, before the replay (`cancelled`) | nothing was written to the transcript: the bubble leaves and **its text goes back into the field**, as the CLI's own prompt does on Esc — whoever stops that fast meant to edit |

- Prompts the CLI makes itself (task notifications, local-command output)
  are replayed with fresh uuids; they are their own rows (04, 05), never a
  local bubble.
- A slash command's bubble (05-local.md) follows the same states; its
  output line appears with the replay.

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

## One shape language

Every view on this page draws from the same few numbers.

| | value | used by |
|---|---|---|
| **Radius · tag** | 5 | the command token, tooltips |
| **Radius · control** | 7 | chips, tabs, sidebar and menu rows (row = control − 2) |
| **Radius · popover** | 12 | menus, the model panel, the slash list |
| **Radius · card** | 18 | the composer, the alert, cards |
| **Icon · row** | 16 | anything that heads a row: sidebar, menu items, tiles |
| **Icon · control** | 14 | inside a 12-pt control: chips, the action button, the ring |
| **Icon · badge** | 10 | a mark on a word: the clock, the bolt, the check |
| **Optical size** | √(w·h) = 11.5 of 16, long side ≤ 14 | every glyph that stands alone, at one 1.3-pt stroke (meters by width: 13 of 16) |
| **Spacing** | 4, 8, 12, 16, 24 | every padding and gap (the README's 4-pt grid) |

- **Corners are continuous** (Apple's squircle): the curve starts about
  1.5 r along each edge and eases into it, so no corner shows a kink where
  the straight edge stops. **The implementation uses AppKit's own:** every
  layer-backed shape sets `layer.cornerRadius` to the radius above and
  `layer.cornerCurve = .continuous` (macOS 10.15+), with no scaling — the
  continuous curve is made to read the same size as a circular corner of
  that radius. Shapes drawn with `NSBezierPath` use the same curve (a
  rounded-rect path built from the continuous-corner cubics, as
  `contRect()` in `preview-live.js` draws it). The + and the action button
  stay circles; tiles and icons stay Lamé curves.
- **About this sheet:** the specimens under *One shape language* draw the
  real curve in SVG, in every browser. The sheet's other shapes use CSS
  `corner-shape: squircle` (a superellipse, radius ×1.45 to match), which
  Chrome 139+ draws and Safari doesn't yet; there they show circular corners.
  The app's shapes are what the specimens show, not what the browser draws.
- **Glyphs match by eye, not by box.** A glyph drawn to sit on a tile (the
  tool kinds, ink ≈ 6 of 16) is too small on its own, and a sparse one
  reads smaller than a solid one. Wherever a glyph stands alone it is scaled
  so its ink covers the same area as the others and centred, its stroke kept
  at one weight — SF Symbols' optical sizing. In AppKit, use SF Symbols where
  one exists (`NSImage(systemSymbolName:)` with a `SymbolConfiguration` at
  the size above), and draw custom glyphs to the same keylines.
- **Words aren't cut.** A control's words are dropped whole when its glyph
  already says the same — the provider name first, then Effort's and Mode's
  names, kept in their tooltips — and a status sentence moves to its own
  line rather than end in an ellipsis. Only titles (a session's, a folder's),
  which can be any length, truncate, at the end, with the full text in the
  tooltip. Alert buttons size to their words.

## What this needs from the code (for the PR that builds it)

- AgentSDK: make `setModel` and `setPermissionMode` public. Decode
  `session_title_changed`, `system/status.permissionMode` and the
  output-direction `apply_flag_settings` (a typed `/effort` or `/fast`). Expose `cancel_async_message`, `get_context_usage`
  (exists) and `list_models`.
- `LiveSession` keeps the `initialize` result instead of discarding it. The
  catalog, cached on disk, is built from it — one per account, since each
  account's CLI lists its own models.
- Restart: end the process and resume with another account's environment
  and `--model`, then a divider row in the transcript.
- `SessionState` gains: `starting`, `compacting`, current model / effort / mode
  / fast, a pending model, and **local prompts by uuid** (text, state: held /
  queued / sent / not sent) drawn until the replay with the same uuid
  arrives. `cancelled` before the replay hands the text back to the
  composer; `refused` / `discarded` / exit mark it not sent.
- `SessionStore.start` takes model, effort, mode, fast, worktree and account.
  Resume passes the transcript's last settings. Worktree only when the
  folder is a git work tree (`GitService` knows the branch).
- `LibraryStore.isScratch` hides any path with a hidden component, so a
  session in `.claude/worktrees/<name>` would vanish from the sidebar. It
  should list it under the folder it came from, with its branch.
- Settings › General: *Allow Bypass Permissions*.
- TranscriptKit's workspace: an empty area hosts a view supplied by the app
  (the New view) instead of *No Editor*. Each group's tab bar gets a trailing
  accessory (the +).
- Sidebar: the white conversation icon from `design/sidebar-icons` as a
  colour image, not a template, so the row's tint no longer applies to it.

## Sources

The line numbers below are of one beautified copy and won't match another;
[protocol.md](protocol.md) gives each fact a string to search for, and how
to extract the bundle.

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
