// THE icon. Single source of truth for what ships: `bun run build` turns
// `SHIP` into macos/ccterm/AppIcon.icon. `compose()` is parameterised so
// variants.ts can render alternatives through the same path.
//
//   ██             A prompt and a cursor — "a terminal, waiting for you".
//    ██   ▄▄▄      The chevron is quiet warm white; the cursor is the only
//     ██  ▀▀▀      colour in the icon, a peach → coral → violet ramp laid
//      ██ ▄▄▄      down one pixel row at a time, so the gradient itself is
//     ██  ▀▀▀      made of pixels.
//    ██   ▄▄▄
//   ██
//
// Units: Icon Composer's 1024 canvas (the squircle fills it; macOS insets it
// on the Dock grid itself).

import type { Stop } from "./color"
import { CANVAS, type Paint, type Sprite } from "./pixel"

const ramp = (...colors: string[]): Stop[] => colors.map((color, i) => ({ at: i / (colors.length - 1), color }))

export interface DesignParams {
  /** Edge of one art pixel, in canvas units. */
  cell: number
  /** Pixels between chevron and cursor. */
  gap: number
  /** Optical lift of the whole group, in pixels (positive = up). */
  lift: number
  chevron: string[]
  cursor: string[]
  /** Background, top → bottom. */
  background: Stop[]
  /** Chevron colour. */
  ink: string
  /** Cursor ramp, top → bottom. */
  accent: Stop[]
}

export const CHEVRON = [
  "##...", //
  ".##..",
  "..##.",
  "...##",
  "..##.",
  ".##..",
  "##...",
]

export const block = (w: number, h: number) => Array.from({ length: h }, () => "@".repeat(w))

export const SHIP: DesignParams = {
  cell: 48,
  gap: 2,
  lift: 0.25,
  chevron: CHEVRON,
  cursor: block(3, 5),
  background: ramp("#2D2A38", "#141218"), // near-black with a whisper of plum
  ink: "#F4F2EE",
  accent: ramp("#FFB86B", "#FF6B7D", "#B65CFF"), // peach → coral → violet
}

export interface Composed {
  background: Paint
  /** Back to front. */
  layers: { name: string; sprite: Sprite }[]
  params: DesignParams
}

export function compose(p: DesignParams): Composed {
  const cw = Math.max(...p.chevron.map((r) => r.length))
  const w = cw + p.gap + p.cursor[0].length
  const h = p.chevron.length
  const x0 = (CANVAS - w * p.cell) / 2
  const y0 = (CANVAS - h * p.cell) / 2 - p.lift * p.cell
  return {
    params: p,
    background: { kind: "ramp", stops: p.background, angle: 90, mode: "smooth" },
    layers: [
      {
        name: "cursor",
        sprite: {
          grid: p.cursor,
          paints: { "@": { kind: "ramp", stops: p.accent, angle: 90, mode: "stepped" } },
          cell: p.cell,
          origin: [x0 + (cw + p.gap) * p.cell, y0 + (h - p.cursor.length) * p.cell],
        },
      },
      {
        name: "chevron",
        sprite: { grid: p.chevron, paints: { "#": { kind: "solid", color: p.ink } }, cell: p.cell, origin: [x0, y0] },
      },
    ],
  }
}
