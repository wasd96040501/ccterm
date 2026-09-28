# Sidebar icons

The sidebar's own glyphs: a conversation, a subagent, a workflow run. Folders
stay the system folder icon. Open `index.html` for the sheet: each glyph on
its construction grid, and both appearances in a sidebar.

- **Geometry.** Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt
  grid. The bodies are squircles (n = 4), the family of the system's shapes.
  The subagent is a four-cusped star, n = 0.8, between the astroid (n = ⅔)
  and the rhombus (n = 1).
- **Colour.** Anchored on the system folder icon, the colour every row sits
  beside. The folder is the same in light and dark, so each glyph keeps one
  colour in both appearances too, at the folder's lightness (OKLCH L 0.70).
  Its chroma matches the folder's *relative* chroma: the share of the most
  sRGB can show at that lightness and hue, 84% for the folder. At equal
  absolute chroma a hue with a wide gamut reads greyed, or muddy, beside the
  folder. The hues come from where the gamut is as narrow as the folder's,
  mint to indigo, so a clean colour there is no louder than the folder
  either:
  - the conversation is indigo, 275: the folder's cool family, clearly not
    its blue;
  - the workflow is mint, 160;
  - the subagent is coral, 50, the folder's complement and the one warm note.
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
becomes two assets:

- `Sidebar<Name>.imageset`: a template SVG with its vector data preserved.
- `Sidebar<Name>Tint.colorset`: its colour, one for both appearances.

It also rewrites `index.html`. Don't edit the generated files by hand; the
next build overwrites them.

The app loads them by their generated symbols, `NSImage(resource:)` and
`NSColor(resource:)`. A row tints its glyph with that colour, and white when
it is selected and focused, as it does the title.
