// Render design variants through the real pipeline (.icon → ictool) and lay
// them side by side, each at 300 px and at Dock-ish 64 px. Use it to settle
// proportions: the mock in sheet.ts is fine for concepts, but final tuning
// wants the system's own rendering.
//
//   bun run variants

import { mkdirSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { Resvg } from "@resvg/resvg-js"
import { block, compose, SHIP, type DesignParams } from "./design"
import { hasIctool, ictoolRender, imageEl, writeIconDoc } from "./icon-doc"

const OUT = resolve(import.meta.dir, "../out/variants")

const ramp = (...colors: string[]) => colors.map((color, i) => ({ at: i / (colors.length - 1), color }))

// Edit freely — this list is a scratch space; SHIP in design.ts is what ships.
const variants: [string, Partial<DesignParams>][] = [
  ["ship", {}],
  ["lift 0", { lift: 0 }],
  ["lift .25", { lift: 0.25 }],
  ["lift .5", { lift: 0.5 }],
  ["dusk", { accent: ramp("#FFC46E", "#FF7474", "#E0539A", "#9A5CFF") }],
  ["warmer violet", { accent: ramp("#FFBE6E", "#FF6F7C", "#C45AF5") }],
  ["brighter ink", { ink: "#FFFFFF" }],
  ["deeper bg", { background: ramp("#26232F", "#0F0E13") }],
]
void block

if (!hasIctool()) throw new Error("variants needs ictool (Xcode 26+)")
mkdirSync(OUT, { recursive: true })

const S = 300
const P = 28
const COLS = 4
const cellW = S + P
const cellH = S + 64 + P * 2 + 20
const W = COLS * cellW + P
const H = Math.ceil(variants.length / COLS) * cellH + P
const parts = [`<rect width="${W}" height="${H}" fill="#E4E4E8"/>`]

variants.forEach(([label, patch], i) => {
  const slug = label.replace(/[^a-z0-9]+/gi, "-")
  const doc = join(OUT, `${slug}.icon`)
  const png = join(OUT, `${slug}.png`)
  writeIconDoc(doc, compose({ ...SHIP, ...patch }))
  ictoolRender(doc, png)
  const x = P + (i % COLS) * cellW
  const y = P + Math.floor(i / COLS) * cellH
  parts.push(imageEl(png, x, y, S), imageEl(png, x, y + S + P, 64), imageEl(png, x + 64 + P, y + S + P + 32, 32))
  parts.push(`<text x="${x + 130}" y="${y + S + P + 40}" font-family="Menlo" font-size="15" fill="#444">${label}</text>`)
})

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${parts.join("")}</svg>`
writeFileSync(join(OUT, "..", "variants.png"), new Resvg(svg, { font: { loadSystemFonts: true } }).render().asPng())
console.log(`out/variants.png  (${variants.length} variants)`)
