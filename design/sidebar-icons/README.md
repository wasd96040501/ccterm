# Sidebar icons

The sidebar's own glyphs: a conversation, a subagent, a workflow run. Folders
stay the system folder icon. Open `index.html` for the sheet: each glyph on
its construction grid, and both appearances in a sidebar.

- **Geometry.** Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt
  grid. The bodies are squircles (n = 4), the family of the system's shapes.
  The subagent is a four-cusped star, n = 0.8, between the astroid (n = ⅔)
  and the rhombus (n = 1).
- **Colour.** One OKLCH lightness and chroma for all three, the hues apart:
  `oklch(0.60 0.10 h)` in light, `oklch(0.74 0.09 h)` in dark. They differ in
  hue only, never in weight, so no row shouts.
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
- `Sidebar<Name>Tint.colorset`: its light and dark colours.

It also rewrites `index.html`. Don't edit the generated files by hand; the
next build overwrites them.

The app loads them by their generated symbols, `NSImage(resource:)` and
`NSColor(resource:)`. A row tints its glyph with that colour, and white when
it is selected and focused, as it does the title.
