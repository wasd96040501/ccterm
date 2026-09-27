// Contact sheets: many concept × palette cells on one PNG so they can be
// compared side by side, each shown large on a light and a dark desktop plus
// at the small sizes where an icon actually lives (Dock, Finder list, menu).
//
//   bun run sheet                       round-1 concepts (+ the chosen one), default palette
//   bun run sheet --set r2              round-2 proportion variants
//   bun run sheet --concept cursor      one concept across every palette
//   bun run sheet --palette ink/sunset  every concept in one palette

import { mkdirSync, writeFileSync } from "node:fs"
import { Resvg } from "@resvg/resvg-js"
import { concepts as base, type Concept } from "./concepts"
import { prompt, round2 } from "./round2"
import { mockIcon } from "./mock"
import { accents, backgrounds, palette, type Palette } from "./palettes"
import { backgroundSVG, spriteSVG } from "../pixel"

export function art(c: Concept, p: Palette): string {
  return backgroundSVG(p.background) + c.sprites(p).map(spriteSVG).join("")
}

const args = process.argv.slice(2)
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? args[i + 1] : undefined
}

const sets: Record<string, Concept[]> = { base: [...base, prompt], r2: round2 }
const setName = flag("set") ?? "base"
const concepts = sets[setName]

const allPalettes = (Object.keys(backgrounds) as (keyof typeof backgrounds)[]).flatMap((bg) =>
  (Object.keys(accents) as (keyof typeof accents)[]).map((a) => palette(bg, a)),
)

type Cell = { label: string; concept: Concept; palette: Palette }
let cells: Cell[]
let name: string
const onlyConcept = flag("concept")
const onlyPalette = flag("palette")
if (onlyConcept) {
  const c = concepts.find((x) => x.id === onlyConcept)!
  cells = allPalettes.map((p) => ({ label: p.id, concept: c, palette: p }))
  name = `concept-${onlyConcept}`
} else {
  const [bg, ac] = (onlyPalette ?? "ink/sunset").split("/") as [keyof typeof backgrounds, keyof typeof accents]
  const p = palette(bg, ac)
  cells = concepts.map((c) => ({ label: `${c.id} — ${c.note}`, concept: c, palette: p }))
  name = `${setName}-${bg}-${ac}`
}

if (onlyConcept) {
  // Compact palette matrix: rows = backgrounds, columns = accents, each cell
  // one large icon plus its 32 px rendition.
  const S = 280
  const P = 20
  const cols = Object.keys(accents).length
  const W = cols * (S + P) + P
  const H = Math.ceil(cells.length / cols) * (S + 30 + P) + P
  const out: string[] = [`<rect width="${W}" height="${H}" fill="#E9E9EC"/>`]
  cells.forEach((cell, i) => {
    const x = P + (i % cols) * (S + P)
    const y = P + Math.floor(i / cols) * (S + 30 + P)
    const a = art(cell.concept, cell.palette)
    out.push(mockIcon(a, x, y, S))
    out.push(mockIcon(a, x + S - 40, y + S - 10, 32))
    out.push(`<text x="${x + 20}" y="${y + S + 16}" font-family="Menlo" font-size="14" fill="#555">${cell.label}</text>`)
  })
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${out.join("")}</svg>`
  mkdirSync("out", { recursive: true })
  writeFileSync(`out/${name}.png`, new Resvg(svg, { font: { loadSystemFonts: true } }).render().asPng())
  console.log(`out/${name}.png  (${cells.length} cells)`)
  process.exit(0)
}

// Layout per cell: [large on light][large on dark][128][64][32][16]
const BIG = 300
const PAD = 24
const CELL_W = BIG * 2 + 128 + 64 + 32 + 16 + PAD * 7
const CELL_H = BIG + 40
const COLS = 2
const rows = Math.ceil(cells.length / COLS)
const W = CELL_W * COLS
const H = CELL_H * rows + PAD

const parts: string[] = [`<rect width="${W}" height="${H}" fill="#E9E9EC"/>`]
cells.forEach((cell, i) => {
  const x0 = (i % COLS) * CELL_W
  const y0 = Math.floor(i / COLS) * CELL_H + PAD
  const a = art(cell.concept, cell.palette)
  parts.push(`<rect x="${x0 + PAD + BIG}" y="${y0}" width="${BIG + PAD}" height="${BIG}" fill="#1E1F24"/>`)
  parts.push(mockIcon(a, x0 + PAD, y0, BIG))
  parts.push(mockIcon(a, x0 + PAD * 2 + BIG, y0, BIG))
  let x = x0 + PAD * 3 + BIG * 2
  for (const s of [128, 64, 32, 16]) {
    parts.push(mockIcon(a, x, y0 + BIG - s, s))
    x += s + PAD
  }
  parts.push(
    `<text x="${x0 + PAD}" y="${y0 + BIG + 22}" font-family="Menlo" font-size="14" fill="#555">${cell.label}</text>`,
  )
})

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${parts.join("")}</svg>`
mkdirSync("out", { recursive: true })
const png = new Resvg(svg, { font: { loadSystemFonts: true } }).render().asPng()
writeFileSync(`out/${name}.png`, png)
console.log(`out/${name}.png  (${cells.length} cells)`)
