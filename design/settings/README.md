# Settings

The Settings window, redesigned: **General** and **Accounts**. Open
`index.html` in a browser. It is the whole design: a working mock of the
window, its sheets and their interactions, in light and dark. The controls
above the window switch the appearance; they are not part of the design.

`index.html` is hand-written and self-contained; there is no build step.

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
