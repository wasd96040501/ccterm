# Sidebar icons

The sidebar's own glyphs: a conversation, a subagent, a workflow run, and the
mark of a worktree session. Folders
stay the system folder icon. Open `index.html` for the sheet: each glyph on
its construction grid, and both appearances in a sidebar.

- **Geometry.** Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt
  grid. The bodies are squircles (n = 4), the family of the system's shapes.
  The subagent is a four-cusped star, n = 0.8, between the astroid (n = ⅔)
  and the rhombus (n = 1).
- **Colour.** As Xcode colours its file types. Xcode's navigator tints each
  file type's glyph with a colour set made to sit beside the system folder
  in both appearances. Most are system colours (`doc-gray` and `doc-purple`
  are `systemGray` and `systemIndigo`), and a few are Xcode's own
  (`doc-swift`). Its navigator reads as blue folders and orange Swift files,
  two complements, with everything else quieter. So:
  - a conversation, which most rows are, is not tinted at all: white paper
    with the app's prompt on it, as a Mac document is — a full-colour image
    that stays itself on a selected row (see *The conversation icon*). The
    coral of our own, `oklch(0.70 0.155 50)`, `#e97d39`, remains as the one
    colour set, `SidebarCoral`, for the needs-input mark.
  - a subagent, nested and secondary, is `systemGray`;
  - a workflow, which is rare, is `systemIndigo`, the one cool accent;
  - the worktree mark, after a session's title, is the tertiary label colour,
    as the design's `.wtb` is.
- **The worktree mark is the design's own.** `SidebarWorktree` is the design's
  branch glyph (design/transcript/preview-live.js `LV.branch`) as drawn there:
  three 1.2-pt rings and a 1-pt line on a 9 × 10 box, which is the size it is
  shown at. Not a Lamé shape and not an SF Symbol: the system's
  `arrow.triangle.branch` is an arrow, a different mark.
- **Flat and restrained.** Filled shapes, no gradients, no outlines. Detail is
  cut out of a shape (1.5-pt slots) rather than drawn on it.

## The conversation icon

White paper with its kind's emblem, the way a Swift file is white with an
orange bird (design/transcript 08-live.md). A squircle bubble (Lamé, n = 4,
13 × 10 pt) with a tail to the lower left, `#FFFFFF` (`#F5F5F7` in Dark), edged
with a 0.55-pt line at 34 % black (50 % in Dark) drawn under the fill so the
tail joins the body without a seam. On it, the app icon's prompt, small: a
chevron in `#6E6E73` and the cursor as one solid block in `#FF6E7C`, the middle
of the icon's ramp. It is an image set with Any and Dark SVGs and the
`original` rendering intent, so it is never tinted.

## Source of truth

`src/build.ts` holds the geometry and the colours. Nothing else decides what
ships.

```bash
make sidebar-icons                  # from the repo root; same as the line below
cd design/sidebar-icons && bun run build
```

`build` writes `macos/ccterm/Assets.xcassets/Sidebar` from scratch. Each glyph
becomes `Sidebar<Name>.imageset`, a template SVG with its vector data
preserved (the conversation's is full colour, see above). A colour of our own becomes a colour set; a system colour is
named by the app.

It also rewrites `index.html`. Don't edit the generated files by hand; the
next build overwrites them.

The app loads each image and colour set by its generated symbol,
`NSImage(resource:)` and `NSColor(resource:)`, and tints each template glyph
with its colour. When a row is selected and focused, the
glyph turns white, like the title.

## Status marks

A live session's row ends in one small mark, 14 pt wide, for the state of its CLI.
Colour follows the transcript design: coral is a session waiting for you, red a
failure, and a running thing moves and is not coloured.

| state | mark |
|---|---|
| at rest | none |
| idle | a 6-pt dot, secondary label at 55 % |
| responding | a 1.5-pt arc, a third of a ring, turning once a second; Reduce Motion holds it still |
| needs input | a coral dot, `SidebarCoral` |
| failed | a `systemRed` dot |

A collapsed group shows the mark of its most urgent session (needs input, then
failed, responding, idle); an open group shows none, each session its own. On a
selected, focused row every mark is white, the idle dot at 55 %.
