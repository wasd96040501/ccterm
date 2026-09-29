# Settings

The Settings window, redesigned: **General** and **Accounts**. Open
`index.html` in a browser. It is the whole design: a working mock of the
window, its sheets and their interactions, in light and dark. The controls
above the window switch the appearance; they are not part of the design.

`index.html` is hand-written and self-contained; there is no build step.
The sample data follows the shape of `claude auth status` and of provider
aliases in a real `~/.zshrc`; hosts, tokens and the email are placeholders.
The mock stands in for the disk: `claude`, `~/.local/bin/claude`,
`/usr/local/bin/claude`, `/opt/homebrew/bin/claude` and `~/bin/claude-relay`
answer `--version` as Claude Code; `/usr/bin/python3`, `/usr/bin/true` and
`~/.zshrc` fail in the ways a command can; `~/.claude` and
`~/.claude-work` are configuration folders (signed in and signed out), and
any other folder path doesn't exist.

## General

One group, **Claude Code**:

- **Launch Command**: the `claude` every session and every
  `claude auth status` runs. Empty runs the auto-located binary; the
  placeholder shows its path.
- **Configuration Folder** (`CLAUDE_CONFIG_DIR`): a path field and nothing
  else; its placeholder shows the folder in effect (`~/.claude` by
  default). The CLI keeps its settings, its claude.ai sign-in and its
  session transcripts (`projects/`) there.

The check result shows where the value is typed, the way System Settings
and the Add User sheet report on a field, rather than in an alert on
commit: in the row's description line, by its text and colour alone. No
glyph: a field keeps the row's usual width and edge.

**When it checks.** Typing changes nothing on screen: the last result stays
until the check runs, 0.5 s after the last keystroke. Return or leaving the
field checks at once. Checks run off the main thread and only the result
for the value still in the field is shown. The launch command runs
`<command> --version` and must print `<x.y.z> (Claude Code)`; the folder
must be an existing folder.

**What the row shows.**

| State | Description line |
|---|---|
| Checking | *Checking…*, secondary |
| Valid command | *Claude Code 2.1.284*, secondary (the field, or its placeholder, already shows the path) |
| Valid folder | *Claude Code's settings, sign-in and sessions*, secondary |
| Invalid | the reason in systemRed, then *Still using …* in secondary: **Not found.**, **Not executable.**, **Didn't print a version.**, **Timed out.**, or the command's own last error line; **Folder doesn't exist.**, **Not a folder.** |

Only a value that passes is saved; a failing one stays in the field until
it is fixed or Settings closes, and the last good value keeps running. A
saved change to either field changes which sessions the main window's
sidebar lists (`<folder>/projects`) and whose sign-in the subscription
reads: the sidebar reloads, and the subscription row goes back to
*Checking…* while `claude auth status` runs again with the new command and
folder.

## Accounts

An account is what a session runs as. There are two kinds, one group each:

- **Subscription**: at most one, because the CLI holds one claude.ai login.
  Signed out, the group holds a single row with **Sign In…**, which waits on
  the browser. The group has no Add button; its shape is the rule.
- **API Providers**: any number. A provider is a base URL, a token or API
  key, optional model names, environment variables, a launch command and
  its arguments: everything a shell alias used to carry.

With no providers the group holds an empty state, as `ContentUnavailableView`
draws one: a quiet `server.rack` symbol, **No API Providers**, one line of
what a provider is for, and **Add Provider…**, which moves in from under the
group while it's there. **Add Provider…** is a split button
(`NSComboButton`): the button opens a blank provider, its menu holds
**Import from Clipboard ⌘V**, enabled while the clipboard holds something
to read. It does what **⌘V** on the pane does. The empty state's hint says
*Or press ⌘V to paste shell aliases or commands.*

**Import** reads the paste the way the variable list does (see *Paste*
below), as one provider or several. Each `alias name="…"` line is a
provider, and so is each bare command line
(`ANTHROPIC_BASE_URL=… ANTHROPIC_AUTH_TOKEN=… claude --model x`); `export`
and `KEY=value` lines gather into one until a command line or a blank
line. Aliases that set no variables (`alias ll="ls -la"`) and comments are
ignored, so a whole `~/.zshrc` can be pasted.

- **One provider**: its sheet opens, filled, for a look before **Add**.
- **Several**: added straight to the list, each new row briefly tinted,
  and a toast at the bottom of the pane counts them: *Imported 3
  providers*. A provider without a base URL or a token is skipped and
  counted: *Imported 2 providers · 1 skipped*, or *No providers imported ·
  3 skipped*.

Either way the name is the alias name, else the host, and a name already
in the list gets a number (`Local Proxy 2`).

The review bar's **Copy Sample Alias** and **Copy Three Providers** put
both shapes on the clipboard; its Providers control switches the sample
list off to show the empty state.

There is no default account. A session picks a model before it starts,
and each model belongs to an account, so the account follows from it.

Every row carries a 28 mark: the subscription Claude's, `assets/claude.svg`
(claude.ai's own favicon, unmodified), every provider the same
`server.rack` in secondary ink. Providers are told apart by their text
(name, then host · model), not by per-provider colour. Descriptions and footers are left out wherever
the label, a placeholder or the group's shape already says it.

Rows are not selectable, as in System Settings. **ⓘ** or a double-click
opens the account's sheet; right-click offers Details, Duplicate and
Delete (Details and Sign Out for the subscription).

## The account sheet

Fixed at 540 × 600 for both kinds, so the window never resizes under it:
no header (the row that opened it already names the account), a scrolling
form starting 20 from the top, and a button bar that gains
a hairline while content runs under it. Destructive action bottom left,
Cancel and the default button bottom right. Return is the default button,
Escape and ⌘. cancel. Add (or Save) stays disabled until the name, a valid
http(s) URL and a token are in and the launch command passes its check; a
bad URL says so under the field as you type.

- **Secrets** show their first three and last four characters
  (`sk-••••••••7c1e`). Focusing the field switches it to a plain secure
  field; the eye reveals it. No description: the title says what it is.
- **Environment Variables** come right after the connection, above the
  fold. The list lives inside its group with **+ | −** underneath, the way
  System Settings lists do: two 20 × 20 buttons, radius 5, with a 1 × 12
  divider between them. They have no fill at rest; the pointer over one
  fills that square only (black 5 % / white 8 %), a press deepens it.
  **−** is disabled while no row is selected. Click selects, a second click (or a
  double-click, or Return) edits, Tab moves to the value, Return commits,
  Escape reverts, Space toggles a row's checkbox, Delete removes it. A row
  that sets something the form already owns (`ANTHROPIC_BASE_URL`, …) or
  General owns (`CLAUDE_CONFIG_DIR`), or repeats a name, gets a warning
  glyph.
- **Models**: Default Model (`ANTHROPIC_MODEL`), then Opus, Sonnet, Haiku
  and Fable (`ANTHROPIC_DEFAULT_*_MODEL`). An empty field reads
  *Automatic*: the CLI picks.
- **Launch**: Command and Arguments, per account (the subscription's
  sheet has them too), so an account can go through its own wrapper
  script. Command is checked like General's, with the same timing,
  description line; empty runs General's command, which its
  placeholder shows. The default button stays disabled until
  the command in the field has passed: while it is unchecked, checking or
  failing (with no *Still using*, since nothing falls back). Return in the
  field checks at once and then acts as the default button. The subscription's status
  (`claude auth status`) runs with the subscription's own command when it
  has one, else General's, else the auto-located `claude`.
- **Paste** into the list takes `KEY=value` lines, `export` lines, a bare
  command line or an `alias name="… claude --flags"`: known keys fill the
  form's fields, the rest become rows, the command fills Command (unless
  it's plain `claude`), its flags fill Arguments, and the alias name
  becomes the provider name. A paste holding several providers fills the
  sheet from the first. A toast says what was filled.
- Delete and Sign Out confirm through an alert stacked on the sheet. Like
  every NSAlert it shows the app's icon (`../icon/preview.png`); Cancel is
  its default button.

Popup and context menus open with the checked item over the control, stay
open after a quick click and pick on press-drag-release, like AppKit's.
Arrow keys and Return work in them.

## Measured, not guessed

One CSS px is one point. Every size in the page was measured from a 2×
screenshot of a macOS 27 settings window (Xcode's) and from real SwiftUI
controls rendered offscreen at 2×. A 2× screenshot of `.window`, laid over
the reference, registers text, groups, separators and controls to within a
pixel. The Swift implementation should land on the same numbers:

| Element | Measure |
|---|---|
| Window | 880 × 680, corner radius 15 |
| Sidebar | 180 wide, full height, `#eeeff0` / dark `#303032` |
| Traffic lights | 14 Ø, centres at y 26, x 26 / 49 / 72 |
| Sidebar row | 32 tall, inset 10 (160 wide), radius 8, first row at y 52; glyph 17 tall at x 20.5, title at x 47 (as Xcode's Settings) |
| Sidebar selection | `#3b85f0`, white glyph, white semibold title |
| Toolbar | 52 tall; back/forward capsule 73 × 36 at x 8, y 8; title 15 semibold at 13 past the capsule |
| Form inset | groups 20 from the detail's edges; content 10 inside a group |
| Group | radius 12, fill black 2.7 % (`#f8f8f8` on white) / white 4.2 % |
| Separator | 1, inset 10 both sides, black 3.7 % / white 6 % |
| Section header | 13 semibold, line top at 20 below the toolbar for the first, 30 below the previous group for the rest; 10 above its group |
| Row, title only | 37 + 1 separator; padding 10.5 |
| Row, title + description | 52 with a switch, 55 with a popup (the popup's frame is 22, pushing the description 2.5 lower) |
| Title / description | 13 / 16 line; 11 / 14 line, secondary label |
| Description width | runs under the trailing control, stops 62 short of the row's right edge |
| Popup button | value, 12 gap, 20 Ø indicator (fill black 6 %), 2 from the content edge |
| Switch | 36 × 16 track, 21 × 13 pill knob inset 1.5; on `#3b85f0`, off black 9 % |
| Push button | 24 tall, radius 6, fill black 6 %, no border; 12 padding |
| Large button | 28 tall, capsule |
| List bar (**+ \| −**) | 28 tall, hairline above, 4 inset; buttons 20 × 20, radius 5, 10 glyph; divider 1 × 12, 3 each side; hover black 5 % / white 8 %, press black 12 % / white 18 % |
| Check timing | 0.5 s after the last keystroke; at once on Return or blur |
| Pane toast | centred on the detail area, 24 above its bottom; the sheet's toast sits 66 above the sheet's bottom |

Text is SF Pro through `-apple-system`; Chrome and Safari set it with the
same advances as AppKit (“File extensions” at 13 is 176 px at 2× in both),
so no tracking correction is applied.
