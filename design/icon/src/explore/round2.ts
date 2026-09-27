// Round 2 exploration: proportion / cursor variants of the prompt concept.
import type { Concept } from "./concepts"
import type { Palette } from "./palettes"
import { CANVAS, type Paint, type Sprite } from "../pixel"

const p2 = (p: Palette, angle = 90): Record<string, Paint> => ({
  "#": { kind: "solid", color: p.ink },
  "@": { kind: "ramp", stops: p.accent, angle, mode: "stepped" },
  "~": { kind: "ramp", stops: p.accent, angle, mode: "smooth" },
})
const CHEV = ["##...", ".##..", "..##.", "...##", "..##.", ".##..", "##..."]
const THIN = ["#...", ".#..", "..#.", "...#", "..#.", ".#..", "#..."]

type Part = { grid: string[]; paints: Record<string, Paint>; gap?: number }

/** Lay parts left→right, bottom-aligned, and centre the group on the canvas. */
export function row(cell: number, parts: Part[], dy = 0): Sprite[] {
  const width = (g: string[]) => Math.max(...g.map((r) => r.length))
  const w = parts.reduce((s, x, i) => s + width(x.grid) + (i ? (x.gap ?? 1) : 0), 0)
  const h = Math.max(...parts.map((x) => x.grid.length))
  const x0 = (CANVAS - w * cell) / 2
  const y0 = (CANVAS - h * cell) / 2 + dy * cell
  let x = 0
  return parts.map((pt, i) => {
    if (i) x += pt.gap ?? 1
    const s: Sprite = { grid: pt.grid, paints: pt.paints, cell, origin: [x0 + x * cell, y0 + (h - pt.grid.length) * cell] }
    x += width(pt.grid)
    return s
  })
}
const block = (w: number, h: number, ch = "@") => Array.from({ length: h }, () => ch.repeat(w))

export const prompt: Concept = {
  id: "cursor",
  note: "cell 56, > + 3x5 stepped cursor",
  sprites: (p) => row(56, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 5), paints: p2(p), gap: 2 }]),
}

export const round2: Concept[] = [
  { id: "a 3x5", note: "block 3x5", sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 5), paints: p2(p), gap: 2 }]) },
  { id: "b 2x5", note: "narrow block 2x5", sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: block(2, 5), paints: p2(p), gap: 2 }]) },
  { id: "c 3x7", note: "full-height block", sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 7), paints: p2(p), gap: 2 }]) },
  { id: "d 3x3", note: "square cursor", sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 3), paints: p2(p, 45), gap: 2 }]) },
  { id: "e thin", note: "thin chevron + 2x5", sprites: (p) => row(64, [{ grid: THIN, paints: p2(p) }, { grid: block(2, 5), paints: p2(p), gap: 2 }]) },
  { id: "f small", note: "cell 56, 3x5", sprites: (p) => row(56, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 5), paints: p2(p), gap: 2 }]) },
  {
    id: "g spark-cursor",
    note: "5x5 plus-sparkle as cursor",
    sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: ["..@..", "..@..", "@@@@@", "..@..", "..@.."], paints: p2(p, 45), gap: 2 }]),
  },
  {
    id: "h gem-cursor",
    note: "diamond cursor",
    sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: ["..@..", ".@@@.", "@@@@@", ".@@@.", "..@.."], paints: p2(p, 45), gap: 2 }]),
  },
  {
    id: "i spark-7",
    note: "7x7 sparkle, cell 48",
    sprites: (p) =>
      row(48, [
        { grid: CHEV, paints: p2(p) },
        { grid: ["...@...", "...@...", "..@@@..", "@@@@@@@", "..@@@..", "...@...", "...@..."], paints: p2(p, 45), gap: 2 },
      ]),
  },
  { id: "j smooth", note: "3x5 smooth ramp", sprites: (p) => row(64, [{ grid: CHEV, paints: p2(p) }, { grid: block(3, 5, "~"), paints: p2(p), gap: 2 }]) },
]
