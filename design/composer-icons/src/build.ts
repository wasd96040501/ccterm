// Build the composer's glyphs that SF Symbols has no shape for — the design
// sheet's own geometry (design/transcript/preview-live.js `MODE_GLYPH`;
// preview.js `GLYPHS`) → template SVG image sets in
// macos/Components/Sources/Components/Resources/Assets.xcassets/Composer, which
// `ComposerGlyph` loads by name; and the effort meter at each level. Every other composer glyph is an SF Symbol (design 08 *Glyphs match
// by eye*), sized in `ComposerGlyph` to the sheet's ink.
//
//   bun run build        (make composer-icons)

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/Composer")
const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

// MARK: - Geometry, as the sheet draws it (16-pt grid, y down)

const r3 = (v: number) => Math.round(v * 1000) / 1000

/** preview.js `lame`: the curve |x/a|ⁿ + |y/b|ⁿ = 1 around (cx, cy), sampled. */
function lame(cx: number, cy: number, a: number, b: number, n: number, steps = 96): string {
  const points: string[] = []
  for (let i = 0; i < steps; i++) {
    const t = (2 * Math.PI * i) / steps
    const c = Math.cos(t)
    const s = Math.sin(t)
    points.push(`${r3(cx + a * Math.sign(c) * Math.abs(c) ** (2 / n))} ${r3(cy + b * Math.sign(s) * Math.abs(s) ** (2 / n))}`)
  }
  return `M${points.join("L")}Z`
}
/** The permission modes SF Symbols has no shape for (`MODE_GLYPH`), drawn by
 *  `svg16`: optically sized, one stroke weight. Measured against their nearest
 *  symbols: `pencil` is a thin stroke at 63 % of the sheet's ink, the
 *  clipboard adds a clip and bullets, `sparkle` is one star where the sheet
 *  draws two, and `nosign` slants its bar the other way. */
const OPTICAL: Record<string, string> = {
  ComposerModeAcceptEdits: '<path d="M5 11l.5-2.1 4.4-4.4 1.6 1.6-4.4 4.4zM8.9 5.5l1.6 1.6"/>',
  ComposerModePlan: '<rect x="5" y="4.8" width="6" height="6.8" rx="1.2"/><path d="M6.8 7.2h2.4M6.8 9.2h2.4"/>',
  ComposerModeAuto:
    `<path d="${lame(7, 9, 3.6, 3.6, 0.75, 48)}" fill="currentColor" stroke="none"/>` +
    `<path d="${lame(12, 4.2, 1.7, 1.7, 0.75, 32)}" fill="currentColor" stroke="none"/>`,
  ComposerModeDontAsk: '<circle cx="8" cy="8" r="4.6"/><path d="M4.9 11.1l6.2-6.2"/>',
}

// MARK: - Optical size: preview-live.js `optical`, with the browser's getBBox done here

type Box = { x0: number; y0: number; x1: number; y1: number }
const empty = (): Box => ({ x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity })
const add = (b: Box, x: number, y: number) => {
  b.x0 = Math.min(b.x0, x)
  b.y0 = Math.min(b.y0, y)
  b.x1 = Math.max(b.x1, x)
  b.y1 = Math.max(b.y1, y)
}

/** The geometric bounds of an SVG path (no stroke), as getBBox gives them. */
function pathBox(d: string, box: Box) {
  const tokens = d.match(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/g) ?? []
  let i = 0
  let command = ""
  let x = 0
  let y = 0
  let startX = 0
  let startY = 0
  const number = () => Number(tokens[i++])
  while (i < tokens.length) {
    if (/[a-zA-Z]/.test(tokens[i])) command = tokens[i++]
    const relative = command === command.toLowerCase()
    const ox = relative ? x : 0
    const oy = relative ? y : 0
    switch (command.toUpperCase()) {
      case "M":
        x = ox + number()
        y = oy + number()
        startX = x
        startY = y
        add(box, x, y)
        command = relative ? "l" : "L"
        break
      case "L":
        x = ox + number()
        y = oy + number()
        add(box, x, y)
        break
      case "H":
        x = ox + number()
        add(box, x, y)
        break
      case "V":
        y = oy + number()
        add(box, x, y)
        break
      case "C": {
        const p = [ox + number(), oy + number(), ox + number(), oy + number(), ox + number(), oy + number()]
        for (let s = 0; s <= 200; s++) {
          const t = s / 200
          const u = 1 - t
          add(
            box,
            u * u * u * x + 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t * t * t * p[4],
            u * u * u * y + 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t * t * t * p[5],
          )
        }
        x = p[4]
        y = p[5]
        break
      }
      case "Z":
        x = startX
        y = startY
        break
      default:
        throw new Error(`path command ${command}`)
    }
  }
}

/** The bounds of a glyph's elements (path, rect, circle), as getBBox on their group. */
function bodyBox(body: string): Box {
  const box = empty()
  for (const [, tag, attrs] of body.matchAll(/<(path|rect|circle)\b([^>]*)\/>/g)) {
    const attr = (name: string) => Number(attrs.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1] ?? 0)
    if (tag === "path") pathBox(attrs.match(/\bd="([^"]*)"/)![1], box)
    if (tag === "rect") {
      add(box, attr("x"), attr("y"))
      add(box, attr("x") + attr("width"), attr("y") + attr("height"))
    }
    if (tag === "circle") {
      add(box, attr("cx") - attr("r"), attr("cy") - attr("r"))
      add(box, attr("cx") + attr("r"), attr("cy") + attr("r"))
    }
  }
  return box
}

/** `svg16`: the glyph scaled so its ink covers √(w·h) = 11.5 of the 16 grid
 *  (long side ≤ 14), centred, its stroke divided by the scale so every glyph
 *  keeps the 1.3 weight. */
function svg16(body: string): string {
  const b = bodyBox(body)
  const filledOnly = /stroke="none"/.test(body) && !/<(path|circle|rect)(?![^>]*stroke="none")/.test(body)
  const pad = filledOnly ? 0 : 1.3
  const w = b.x1 - b.x0 + pad
  const h = b.y1 - b.y0 + pad
  const k = Math.min(11.5 / Math.sqrt(w * h), 14 / Math.max(w, h))
  const transform = `translate(8 8) scale(${k.toFixed(3)}) translate(${(-(b.x0 + (b.x1 - b.x0) / 2)).toFixed(2)} ${(-(b.y0 + (b.y1 - b.y0) / 2)).toFixed(2)})`
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
    `<g transform="${transform}" fill="none" stroke="#000000" stroke-width="${(1.3 / k).toFixed(2)}" stroke-linecap="round" stroke-linejoin="round">` +
    `${ink(body)}</g></svg>`
  )
}

const ink = (body: string) => body.replaceAll("currentColor", "#000000")

// MARK: - The asset catalog

/** A template image set holding `svg`. */
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
for (const [name, body] of Object.entries(OPTICAL)) imageSet(name, svg16(body))

/** preview-live.js `bars`: five bars rising on the 16 grid, `level` of them
 *  filled and the rest at 28 % ink, scaled 0.956 about (7.8, 7) onto the
 *  centre — thin and wide, so sized by its width, not by `svg16`'s area. */
function bars(level: number): string {
  let rects = ""
  for (let i = 0; i < 5; i++) {
    const h = 3 + i * 2.25
    rects += `<rect x="${r3(1 + i * 2.9)}" y="${r3(13 - h)}" width="2" height="${h}" rx=".8" fill="#000000" fill-opacity="${i < level ? 1 : 0.28}"/>`
  }
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
    `<g transform="translate(8 8) scale(0.956) translate(-7.8 -7)">${rects}</g></svg>`
  )
}
for (let level = 0; level <= 5; level++) imageSet(`ComposerEffort${level}`, bars(level))
console.log(`wrote ${ASSETS}`)
