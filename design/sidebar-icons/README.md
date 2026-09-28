# Sidebar icons

The sidebar's own glyphs: a conversation, a subagent, a workflow run. Folders
stay the system folder icon. Open `index.html` for the sheet: each glyph on
its construction grid, and both appearances in a sidebar.

- **Geometry.** Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt
  grid. The bodies are squircles (n = 4), the family of the system's shapes.
  The subagent is a four-cusped star, n = 0.8, between the astroid (n = ⅔)
  and the rhombus (n = 1).
- **Colour.** The system's, the way Xcode colours its file types. Xcode's
  navigator tints each file type's glyph with a system colour; its colour
  sets `doc-green`, `doc-orange` and `doc-purple` are `systemGreen`,
  `systemOrange` and `systemIndigo`. Those colours are made to sit beside the
  system folder, in both appearances. So the conversation is `systemGreen`,
  the subagent is `systemOrange` (Swift's family), and the workflow is
  `systemIndigo`. None of them is a near-miss of the folder's blue.
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
preserved. The colours aren't assets: the app names the system colour.

It also rewrites `index.html`. Don't edit the generated files by hand; the
next build overwrites them.

The app loads each image by its generated symbol, `NSImage(resource:)`, and
tints it with its system colour. When a row is selected and focused, the
glyph turns white, like the title.
