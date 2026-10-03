# Composer icons

The composer glyphs SF Symbols has no shape for, generated from the design
sheet's own geometry (`design/transcript/preview-live.js` `MODE_GLYPH`,
`preview.js` `GLYPHS`) into `macos/ccterm/Assets.xcassets/Composer`, which
`ComposerGlyph` loads by symbol.

    make composer-icons

Design 08 (*Glyphs match by eye*) asks for an SF Symbol wherever one exists;
each composer glyph was measured against its nearest symbol (ink box and area,
at the symbol size that fits best). Four have none:

| Mode | Nearest symbol | Why not |
|---|---|---|
| Accept Edits | `pencil` | a thin stroke, 63 % of the sheet's ink |
| Plan | `list.bullet.clipboard` | a clip and bullets the sheet doesn't draw |
| Auto | `sparkle` | one star; the sheet draws two |
| Don't Ask | `nosign` | its bar slants the other way |

They are drawn as the sheet's `svg16` does: optically sized (the ink covers
√(w·h) = 11.5 of the 16 grid, long side ≤ 14), centred, the stroke divided by
the scale so every glyph keeps the 1.3 weight — the bounds the browser's
`getBBox` gives are computed here. Every other composer glyph is an SF Symbol
at its measured size and weight (`ComposerGlyph.Symbol`). The effort meter is
neither: it is a measured shape, drawn in `ComposerGlyph.meter`.
