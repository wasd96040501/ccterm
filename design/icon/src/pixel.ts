// Pixel grid → SVG.
//
// Art is authored as ASCII grids: one character per pixel, `.` is empty, any
// other character names a paint. A paint is either a flat colour or a linear
// ramp. A ramp can be *stepped* — every pixel is filled with the one colour
// sampled at its centre, so the gradient itself is made of pixels — or
// *smooth*, a continuous gradient clipped to the pixel silhouette.
//
// Everything is emitted on Icon Composer's 1024 × 1024 canvas.

import { densify, sample, type Stop } from "./color"

export const CANVAS = 1024

export type Paint =
  | { kind: "solid"; color: string; opacity?: number }
  | {
      kind: "ramp"
      stops: Stop[]
      /** Direction of travel in degrees; 0 = left→right, 90 = top→bottom. */
      angle: number
      mode: "stepped" | "smooth"
      /** Ramp extent: the paint's own pixels (default) or the whole canvas. */
      span?: "shape" | "canvas"
    }

export interface Sprite {
  grid: string[]
  paints: Record<string, Paint>
  /** Pixel edge in canvas units. */
  cell: number
  /** Top-left of the grid on the canvas; default centres the grid. */
  origin?: [number, number]
  /** Nudge in whole cells after centring (optical correction). */
  shift?: [number, number]
}

interface Cell {
  x: number
  y: number
  ch: string
}

function cells(s: Sprite): Cell[] {
  const out: Cell[] = []
  s.grid.forEach((row, y) =>
    [...row].forEach((ch, x) => {
      if (ch !== "." && ch !== " ") out.push({ x, y, ch })
    }),
  )
  return out
}

export function spriteOrigin(s: Sprite): [number, number] {
  const cols = Math.max(...s.grid.map((r) => r.length))
  const rows = s.grid.length
  const [ox, oy] = s.origin ?? [(CANVAS - cols * s.cell) / 2, (CANVAS - rows * s.cell) / 2]
  const [dx, dy] = s.shift ?? [0, 0]
  return [ox + dx * s.cell, oy + dy * s.cell]
}

let gradientSeq = 0

/** SVG fragment (defs + shapes) for one sprite. */
export function spriteSVG(s: Sprite): string {
  const [ox, oy] = spriteOrigin(s)
  const all = cells(s)
  const defs: string[] = []
  const body: string[] = []

  for (const [ch, paint] of Object.entries(s.paints)) {
    const mine = all.filter((c) => c.ch === ch)
    if (!mine.length) continue
    const px = (c: Cell) => [ox + c.x * s.cell, oy + c.y * s.cell] as const

    if (paint.kind === "solid") {
      const op = paint.opacity !== undefined ? ` fill-opacity="${paint.opacity}"` : ""
      body.push(`<path fill="${paint.color}"${op} d="${runsPath(mine, px, s.cell)}"/>`)
      continue
    }

    // Ramp axis, projected over the paint's pixel bbox (or the canvas).
    const rad = (paint.angle * Math.PI) / 180
    const dir = [Math.cos(rad), Math.sin(rad)]
    const box =
      paint.span === "canvas"
        ? { x0: 0, y0: 0, x1: CANVAS, y1: CANVAS }
        : {
            x0: Math.min(...mine.map((c) => px(c)[0])),
            y0: Math.min(...mine.map((c) => px(c)[1])),
            x1: Math.max(...mine.map((c) => px(c)[0])) + s.cell,
            y1: Math.max(...mine.map((c) => px(c)[1])) + s.cell,
          }
    const corners = [
      [box.x0, box.y0],
      [box.x1, box.y0],
      [box.x0, box.y1],
      [box.x1, box.y1],
    ]
    const proj = corners.map(([x, y]) => x * dir[0] + y * dir[1])
    const pMin = Math.min(...proj)
    const pMax = Math.max(...proj)

    if (paint.mode === "stepped") {
      // Sample at pixel centres, but stretch so the first and last pixel
      // along the axis land exactly on the end colours.
      const centreProj = mine.map((c) => {
        const [x, y] = px(c)
        return (x + s.cell / 2) * dir[0] + (y + s.cell / 2) * dir[1]
      })
      const cMin = paint.span === "canvas" ? pMin : Math.min(...centreProj)
      const cMax = paint.span === "canvas" ? pMax : Math.max(...centreProj)
      // Underlay the whole silhouette in the mid colour: where two differently
      // coloured pixels abut, anti-aliasing at small sizes then leaks this
      // colour through the seam instead of the background.
      body.push(`<path fill="${sample(paint.stops, 0.5)}" d="${runsPath(mine, px, s.cell)}"/>`)
      const byColor = new Map<string, Cell[]>()
      mine.forEach((c, i) => {
        const t = cMax === cMin ? 0 : (centreProj[i] - cMin) / (cMax - cMin)
        const col = sample(paint.stops, t)
        byColor.set(col, [...(byColor.get(col) ?? []), c])
      })
      for (const [col, cs] of byColor) body.push(`<path fill="${col}" d="${runsPath(cs, px, s.cell)}"/>`)
    } else {
      const id = `g${gradientSeq++}`
      const cx = (box.x0 + box.x1) / 2
      const cy = (box.y0 + box.y1) / 2
      const half = (pMax - pMin) / 2
      const stops = densify(paint.stops)
        .map((st) => `<stop offset="${st.at.toFixed(4)}" stop-color="${st.color}"/>`)
        .join("")
      defs.push(
        `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" ` +
          `x1="${cx - dir[0] * half}" y1="${cy - dir[1] * half}" ` +
          `x2="${cx + dir[0] * half}" y2="${cy + dir[1] * half}">${stops}</linearGradient>`,
      )
      body.push(`<path fill="url(#${id})" d="${runsPath(mine, px, s.cell)}"/>`)
    }
  }
  return (defs.length ? `<defs>${defs.join("")}</defs>` : "") + body.join("")
}

/** Merge horizontally adjacent pixels into runs → one compact path. */
function runsPath(cs: Cell[], px: (c: Cell) => readonly [number, number], cell: number): string {
  const rows = new Map<number, number[]>()
  for (const c of cs) rows.set(c.y, [...(rows.get(c.y) ?? []), c.x])
  const d: string[] = []
  for (const [y, xs] of rows) {
    xs.sort((a, b) => a - b)
    let start = xs[0]
    for (let i = 1; i <= xs.length; i++) {
      if (i < xs.length && xs[i] === xs[i - 1] + 1) continue
      const [x0, y0] = px({ x: start, y, ch: "" })
      const w = (xs[i - 1] - start + 1) * cell
      d.push(`M${x0} ${y0}h${w}v${cell}h${-w}z`)
      if (i < xs.length) start = xs[i]
    }
  }
  return d.join("")
}

/** A full-canvas background rect in the given paint. */
export function backgroundSVG(p: Paint): string {
  if (p.kind === "solid") return `<rect width="${CANVAS}" height="${CANVAS}" fill="${p.color}"/>`
  if (p.mode === "stepped") {
    // Stepped background: one band per 1/16 of the canvas along the axis.
    const n = 16
    return spriteSVG({
      grid: Array.from({ length: n }, () => "#".repeat(n)),
      paints: { "#": { ...p, span: "canvas" } },
      cell: CANVAS / n,
      origin: [0, 0],
    })
  }
  return spriteSVG({
    grid: ["#"],
    paints: { "#": { ...p, span: "shape" } },
    cell: CANVAS,
    origin: [0, 0],
  })
}

export function svgDoc(inner: string, size = CANVAS): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" ` +
    `viewBox="0 0 ${CANVAS} ${CANVAS}">${inner}</svg>`
  )
}
