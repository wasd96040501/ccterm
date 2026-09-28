# Sidebar icons

The sidebar's own glyphs: a conversation, a subagent, a workflow run. Folders
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
  - a conversation, which most rows are, is a coral of our own,
    `oklch(0.70 0.155 50)`, `#e97d39`: the folder's lightness, clean.
    `systemOrange` is too bright for that many rows. It is the one colour
    set, `SidebarCoral`, the way Swift has its own.
  - a subagent, nested and secondary, is `systemGray`;
  - a workflow, which is rare, is `systemIndigo`, the one cool accent.
- **Flat and restrained.** Filled shapes, no gradients, no outlines. Detail is
  cut out of a shape (1.5-pt slots) rather than drawn on it.

## Source of truth

`src/build.ts` holds the geometry and the colours. Nothing else decides what
ships.

```bash
make sidebar-icons                  # from the repo root; same as the line below
cd design/sidebar-icons && bun run build
```

`build` writes `macos/ccterm/Assets.xcassets/Sidebar` from scratch. Each glyph
becomes `Sidebar<Name>.imageset`, a template SVG with its vector data
preserved. A colour of our own becomes a colour set; a system colour is
named by the app.

It also rewrites `index.html`. Don't edit the generated files by hand; the
next build overwrites them.

The app loads each image and colour set by its generated symbol,
`NSImage(resource:)` and `NSColor(resource:)`, and tints each glyph with its
colour. When a row is selected and focused, the
glyph turns white, like the title.
