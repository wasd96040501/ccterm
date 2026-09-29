# Settings

The Settings window, redesigned: **General** and **Accounts**. Open
`index.html` in a browser. It is the whole design: a working mock of the
window, its sheets and their interactions, in light and dark. The controls
above the window switch the appearance; they are not part of the design.

`index.html` is hand-written and self-contained; there is no build step.
The sample data follows the shape of `claude auth status` and of provider
aliases in a real `~/.zshrc`; hosts, tokens and the email are placeholders.

## Accounts

An account is what a session runs as. There are two kinds, one group each:

- **Subscription**: at most one, because the CLI holds one claude.ai login.
  Signed out, the group holds a single row with **Sign In…**, which waits on
  the browser. The group has no Add button; its shape is the rule.
- **API Providers**: any number. A provider is a base URL, a token or API
  key, optional model names, environment variables, a launch command and
  its arguments: everything a shell alias used to carry.

There is no default account. A session picks a model before it starts,
and each model belongs to an account, so the account follows from it.

Only the subscription carries an icon: Claude's mark, `assets/claude.svg`,
which is claude.ai's own favicon, unmodified. Providers are plain text rows
(name, then host · model); a monogram or a generic glyph would add colour
without telling them apart. Descriptions and footers are left out wherever
the label, a placeholder or the group's shape already says it.

Rows are not selectable, as in System Settings. **ⓘ** or a double-click
opens the account's sheet; right-click offers Details, Duplicate and
Delete (Details and Sign Out for the subscription).

## The account sheet

Fixed at 540 × 600 for both kinds, so the window never resizes under it:
a header (name and host; the Claude mark for the subscription), a scrolling form, and a button bar that gains
a hairline while content runs under it. Destructive action bottom left,
Cancel and the default button bottom right. Return is the default button,
Escape and ⌘. cancel. Add stays disabled until the name, a valid http(s)
URL and a token are in; a bad URL says so under the field as you type.

- **Secrets** show their first three and last four characters
  (`sk-••••••••7c1e`). Focusing the field switches it to a plain secure
  field; the eye reveals it.
- **Environment Variables** come right after the connection, above the
  fold. The list lives inside its group with **+ −** underneath, the way
  System Settings lists do. Click selects, a second click (or a
  double-click, or Return) edits, Tab moves to the value, Return commits,
  Escape reverts, Space toggles a row's checkbox, Delete removes it. A row
  that sets something the form already owns (`ANTHROPIC_BASE_URL`, …) or
  repeats a name gets a warning glyph.
- **Launch**: Command (empty runs `claude`) and Arguments, per account, so
  a provider can go through its own wrapper script.
- **Paste** into the list takes `KEY=value` lines, `export` lines or a
  whole `alias name="… claude --flags"`: known keys fill the form's
  fields, the rest become rows, the trailing command and flags fill
  Command (unless it's plain `claude`) and Arguments, and the alias name
  becomes the provider name. A toast says what was filled.
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
| Sidebar row | 32 tall, inset 10 (160 wide), radius 8, first row at y 52; glyph 18 at x 20, title at x 47 |
| Sidebar selection | `#3b85f0`, white glyph and title |
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

Text is SF Pro through `-apple-system`; Chrome and Safari set it with the
same advances as AppKit (“File extensions” at 13 is 176 px at 2× in both),
so no tracking correction is applied.
