# Composer icons

The composer's glyphs, generated from the design sheet's own geometry
(`design/transcript/preview-live.js` `MODE_GLYPH`, `LV`, `OCTAGON`;
`preview.js` `GLYPHS`) into `macos/ccterm/Assets.xcassets/Composer`, which
`ComposerGlyph` loads by symbol.

    make composer-icons

- **Modes and the model panel's marks** are drawn as the sheet's `svg16` does:
  optically sized (the ink covers √(w·h) = 11.5 of the 16 grid, long side ≤ 14),
  centred, the stroke divided by the scale so every glyph keeps the 1.3 weight.
  The bounds the browser's `getBBox` gives are computed here.
- **Boxed glyphs** (chevron, clock, bolt, the send arrow, stop, check) keep the
  sheet's own box.
- **The failure octagon** is full colour, `systemRed` per appearance.

Template glyphs are tinted by the view. The effort meter is not here: it is a
measured shape, drawn in `ComposerGlyph.meter`.
