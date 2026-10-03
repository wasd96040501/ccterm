// Build the transcript's glyphs: the design sheet's own paths → template SVG
// image sets in macos/Components/Sources/Components/Resources/Assets.xcassets/Transcript.
// Nothing is retyped: the sheet's source files are read and the objects it
// draws from — `GLYPHS` and `ICON` in design/transcript/preview.js, `LV` in
// preview-live.js — are evaluated here, so the app and the sheet can't differ.
//
//   TranscriptTile<Key>   GLYPHS[Key]: a tile's glyph, 16-pt grid, 1.3-pt stroke at SF Symbol weight
//   TranscriptIcon<Key>   ICON[Key]:   a row's small mark, at the size the sheet's markup gives it
//   TranscriptLive<Key>   LV[Key]:     the live parts' marks (chips, menus, the composer's send)
//
// Every set is a template image: the app tints it, as the sheet's `currentColor`.
//
//   bun run build        (make transcript-icons)

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { svg16 } from "./optical.ts"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/Transcript")
const DESIGN = join(ROOT, "design/transcript")
const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

// MARK: - The sheet's own objects

const source = (file: string) => readFileSync(join(DESIGN, file), "utf8")

/** The text from `from` up to (not including) the first `to` after it. */
function between(text: string, from: string, to: string): string {
  const start = text.indexOf(from)
  const end = text.indexOf(to, start)
  if (start < 0 || end < 0) throw new Error(`design source changed: no "${from}" … "${to}"`)
  return text.slice(start, end)
}

const preview = source("preview.js")
// `GLYPHS` needs the sheet's geometry helpers (`lame`, `dot`, `STAR`), which sit just above it.
const GLYPHS: Record<string, string> = new Function(
  `${between(preview, "const r3", "/** A kind's tile")}; return GLYPHS`,
)()
const ICON: Record<string, string> = new Function(
  `${between(preview, "const ICON = {", "\n};")}\n}; return ICON`,
)()
const LV: Record<string, string> = new Function(
  `${between(source("preview-live.js"), "const LV = {", "\n};")}\n}; return LV`,
)()

// MARK: - SVG

const INK = "#000000"
const ink = (markup: string) => markup.replaceAll("currentColor", INK)

/** A tile's glyph, as `tile()` draws it: a `<g>` of 1.3-pt round strokes on the 16-pt grid. */
const tileSvg = (body: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
  `<g fill="none" stroke="${INK}" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">${ink(body)}</g></svg>`

/** The sheet's own `<svg>` mark made a standalone file: no class or style, its drawn size. */
function standalone(markup: string): string {
  const open = markup.match(/^<svg\b([^>]*)>/)
  if (!open) throw new Error(`not an svg: ${markup}`)
  const viewBox = open[1].match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/)
  if (!viewBox) throw new Error(`no viewBox: ${markup}`)
  const width = open[1].match(/\bwidth="([\d.]+)"/)?.[1] ?? viewBox[1]
  const height = open[1].match(/\bheight="([\d.]+)"/)?.[1] ?? viewBox[2]
  return ink(
    markup.replace(
      open[0],
      `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${viewBox[1]} ${viewBox[2]}">`,
    ),
  )
}

const cap = (key: string) => key[0].toUpperCase() + key.slice(1)

// MARK: - The asset catalog

function imageSet(name: string, svg: string) {
  const dir = join(ASSETS, `${name}.imageset`)
  mkdirSync(dir)
  writeFileSync(join(dir, `${name}.svg`), `${svg}\n`)
  writeFileSync(
    join(dir, "Contents.json"),
    json({
      images: [{ filename: `${name}.svg`, idiom: "universal" }],
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
    }),
  )
}

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))

for (const [key, body] of Object.entries(GLYPHS)) imageSet(`TranscriptTile${cap(key)}`, tileSvg(body))
for (const [key, markup] of Object.entries(ICON)) imageSet(`TranscriptIcon${cap(key)}`, standalone(markup))
for (const [key, markup] of Object.entries(LV)) {
  // `branch` is the sidebar's worktree mark (design/sidebar-icons), already a set.
  if (key === "branch") continue
  // `folder` is a bare path body the sheet draws through `svg16`, optically sized.
  imageSet(`TranscriptLive${cap(key)}`, markup.startsWith("<svg") ? standalone(markup) : svg16(markup))
}
console.log(`wrote ${ASSETS}`)
