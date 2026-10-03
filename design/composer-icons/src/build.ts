// Build the composer's glyphs: the design sheet's own geometry
// (design/transcript/preview-live.js `MODE_GLYPH`, `LV`, `OCTAGON`; preview.js
// `GLYPHS`) → SVG image sets in macos/ccterm/Assets.xcassets/Composer, which
// `ComposerGlyph` loads by symbol. Template glyphs are tinted by the view;
// the failure octagon is full colour, light and dark.
//
//   bun run build        (make composer-icons)

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/ccterm/Assets.xcassets/Composer")
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
const dot = (x: number, y: number) => `<circle cx="${x}" cy="${y}" r=".55" fill="currentColor" stroke="none"/>`
const SHIELD = "M8 2.8l-4.3 1.7v3.2c0 2.6 1.8 4.4 4.3 5.4 2.5-1 4.3-2.8 4.3-5.4V4.5z"

/** The permission modes (`MODE_GLYPH`) and the model panel's marks, drawn by
 *  `svg16`: optically sized, one stroke weight. */
const OPTICAL: Record<string, string> = {
  ComposerModeDefault: `<path d="${SHIELD}"/>`,
  ComposerModeAcceptEdits: '<path d="M5 11l.5-2.1 4.4-4.4 1.6 1.6-4.4 4.4zM8.9 5.5l1.6 1.6"/>',
  ComposerModePlan: '<rect x="5" y="4.8" width="6" height="6.8" rx="1.2"/><path d="M6.8 7.2h2.4M6.8 9.2h2.4"/>',
  ComposerModeAuto:
    `<path d="${lame(7, 9, 3.6, 3.6, 0.75, 48)}" fill="currentColor" stroke="none"/>` +
    `<path d="${lame(12, 4.2, 1.7, 1.7, 0.75, 32)}" fill="currentColor" stroke="none"/>`,
  ComposerModeDontAsk: '<circle cx="8" cy="8" r="4.6"/><path d="M4.9 11.1l6.2-6.2"/>',
  ComposerModeBypass: `<path d="${SHIELD}"/><path d="M8 5.6v3"/>${dot(8, 10.6)}`,
  ComposerRestart: '<path d="M11.6 6.2A4 4 0 1 0 12 9"/><path d="M12 3.6v2.8H9.2"/>',
  ComposerProvider:
    '<rect x="3" y="3.2" width="10" height="4" rx="1.2"/><rect x="3" y="8.8" width="10" height="4" rx="1.2"/><path d="M5.2 5.2h.01M5.2 10.8h.01"/>',
}

/** Glyphs drawn on their own box, as `LV` has them. */
const BOXED: Record<string, { box: [number, number]; body: string }> = {
  ComposerChevron: {
    box: [8, 8],
    body: '<path d="M1.5 3l2.5 2.5L6.5 3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
  },
  ComposerClock: {
    box: [10, 10],
    body:
      '<circle cx="5" cy="5" r="4" fill="none" stroke="currentColor" stroke-width="1.1"/>' +
      '<path d="M5 2.8V5l1.5 1" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/>',
  },
  ComposerBolt: { box: [10, 12], body: '<path d="M6.2.8L1.4 7h3.1l-.8 4.2L8.6 5H5.4z" fill="currentColor"/>' },
  ComposerSend: {
    box: [14, 14],
    body: '<path d="M7 11.5V3M3.2 6.6L7 2.8l3.8 3.8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  },
  ComposerStop: { box: [10, 10], body: '<rect x="0.5" y="0.5" width="9" height="9" rx="2" fill="currentColor"/>' },
  ComposerCheck: {
    box: [10, 10],
    body: '<path d="M1.5 5.4l2.3 2.3L8.6 2.4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
  },
}

/** `OCTAGON`: the failure's mark, red (systemRed per appearance) with a white bang. */
const octagon = (red: string) =>
  `<path d="M5.3 1.5h5.4l3.8 3.8v5.4l-3.8 3.8H5.3l-3.8-3.8V5.3z" fill="${red}"/>` +
  '<path d="M8 4.6v4.2" stroke="#ffffff" stroke-width="1.6" stroke-linecap="round"/>' +
  '<circle cx="8" cy="11.2" r=".95" fill="#ffffff"/>'

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
      case "A": {
        const [rx0, ry0, phi, large, sweep] = [number(), number(), number(), number(), number()]
        const x2 = ox + number()
        const y2 = oy + number()
        arc(box, x, y, rx0, ry0, phi, large, sweep, x2, y2)
        x = x2
        y = y2
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

/** An elliptical arc's points (SVG implementation notes F.6.5), sampled into `box`. */
function arc(box: Box, x1: number, y1: number, rx: number, ry: number, phiDeg: number, large: number, sweep: number, x2: number, y2: number) {
  const phi = (phiDeg * Math.PI) / 180
  const cos = Math.cos(phi)
  const sin = Math.sin(phi)
  const dx = (x1 - x2) / 2
  const dy = (y1 - y2) / 2
  const x1p = cos * dx + sin * dy
  const y1p = -sin * dx + cos * dy
  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
  if (lambda > 1) {
    rx *= Math.sqrt(lambda)
    ry *= Math.sqrt(lambda)
  }
  const sign = large === sweep ? -1 : 1
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
  const coef = sign * Math.sqrt(Math.max(0, num / (rx * rx * y1p * y1p + ry * ry * x1p * x1p)))
  const cxp = (coef * rx * y1p) / ry
  const cyp = (-coef * ry * x1p) / rx
  const cx = cos * cxp - sin * cyp + (x1 + x2) / 2
  const cy = sin * cxp + cos * cyp + (y1 + y2) / 2
  const angle = (ux: number, uy: number, vx: number, vy: number) => {
    const a = Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    return a
  }
  const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
  let delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
  if (!sweep && delta > 0) delta -= 2 * Math.PI
  if (sweep && delta < 0) delta += 2 * Math.PI
  for (let s = 0; s <= 400; s++) {
    const t = theta1 + (delta * s) / 400
    add(box, cx + rx * Math.cos(t) * cos - ry * Math.sin(t) * sin, cy + rx * Math.cos(t) * sin + ry * Math.sin(t) * cos)
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

function imageSet(name: string, files: { file: string; svg: string; dark?: boolean }[], template: boolean) {
  const dir = join(ASSETS, `${name}.imageset`)
  mkdirSync(dir)
  for (const { file, svg } of files) writeFileSync(join(dir, file), `${svg}\n`)
  writeFileSync(
    join(dir, "Contents.json"),
    json({
      images: files.map(({ file, dark }) =>
        dark
          ? { appearances: [{ appearance: "luminosity", value: "dark" }], filename: file, idiom: "universal" }
          : { filename: file, idiom: "universal" },
      ),
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": template ? "template" : "original" },
    }),
  )
}

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))
for (const [name, body] of Object.entries(OPTICAL)) imageSet(name, [{ file: `${name}.svg`, svg: svg16(body) }], true)
for (const [name, { box, body }] of Object.entries(BOXED)) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${box[0]}" height="${box[1]}" viewBox="0 0 ${box[0]} ${box[1]}">${ink(body)}</svg>`
  imageSet(name, [{ file: `${name}.svg`, svg }], true)
}
const octagonSvg = (red: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">${octagon(red)}</svg>`
imageSet(
  "ComposerFailure",
  [
    { file: "ComposerFailure.svg", svg: octagonSvg("#ff3b30") },
    { file: "ComposerFailure-dark.svg", svg: octagonSvg("#ff453a"), dark: true },
  ],
  false,
)
console.log(`wrote ${ASSETS}`)
