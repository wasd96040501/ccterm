// Build the New view's glyphs: the design's own paths (design/transcript/
// preview-live.js) → template SVG image sets in
// macos/Components/Sources/Components/Resources/Assets.xcassets/NewView. Tinted by the view, sized there to the
// design's CSS box (the chevron at 11 pt beside the folder, 10 in the branch
// pop-up; the worktree mark at 14). The branch mark is the sidebar's
// `SidebarWorktree`, the same `LV.branch`.
//
//   bun run build

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/NewView")

type Glyph = { asset: string; source: string; size: number; markup: string }

const GLYPHS: Glyph[] = [
  {
    // `LV.chev2`: a 1.6-pt open chevron, round caps, on a 12-pt box.
    asset: "NewViewChevron",
    source: "LV.chev2",
    size: 12,
    markup:
      '<path d="M3 4.8L6 7.8l3-3" fill="none" stroke="#000" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
  },
  {
    // `WT_GLYPH`: two 1.2-pt squares, the back one only its top-right corner.
    asset: "NewViewWorktree",
    source: "WT_GLYPH",
    size: 14,
    markup:
      '<path d="M4.2 3.2V2.6c0-.6.4-1 1-1h6.2c.6 0 1 .4 1 1v6.2c0 .6-.4 1-1 1h-.6" fill="none" stroke="#000" stroke-width="1.2"/>' +
      '<rect x="1.6" y="4.2" width="8.2" height="8.2" rx="1.6" fill="none" stroke="#000" stroke-width="1.2"/>',
  },
]

const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`
const INFO = { author: "xcode", version: 1 }

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))
for (const glyph of GLYPHS) {
  const set = join(ASSETS, `${glyph.asset}.imageset`)
  mkdirSync(set, { recursive: true })
  const { size } = glyph
  writeFileSync(
    join(set, `${glyph.asset}.svg`),
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">${glyph.markup}</svg>\n`,
  )
  writeFileSync(
    join(set, "Contents.json"),
    json({
      images: [{ filename: `${glyph.asset}.svg`, idiom: "universal" }],
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
    }),
  )
}
console.log(`wrote ${GLYPHS.length} glyphs to ${ASSETS}`)
