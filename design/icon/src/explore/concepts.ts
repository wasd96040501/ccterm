// Icon concepts. Each concept is a function of a palette → sprites, so the
// same composition can be tried across colour sets on one contact sheet.
//
// Grid: the 1024 canvas is 16 × 16 pixels of 64. Coordinates below are in
// those pixels. `#` = ink, `@` = accent (stepped ramp), `~` = accent (smooth).

import type { Palette } from "./palettes"
import type { Paint, Sprite } from "../pixel"

export const CELL = 64

export interface Concept {
  id: string
  note: string
  sprites: (p: Palette) => Sprite[]
}

const at = (x: number, y: number): [number, number] => [x * CELL, y * CELL]

function paints(p: Palette, angle = 0): Record<string, Paint> {
  return {
    "#": { kind: "solid", color: p.ink },
    "@": { kind: "ramp", stops: p.accent, angle, mode: "stepped" },
    "~": { kind: "ramp", stops: p.accent, angle, mode: "smooth" },
  }
}

const CHEVRON = [
  "##...", //
  ".##..",
  "..##.",
  "...##",
  "..##.",
  ".##..",
  "##...",
]

export const concepts: Concept[] = [
  {
    id: "prompt",
    note: "> + underscore cursor; cursor carries the colour",
    sprites: (p) => [
      { grid: CHEVRON, paints: paints(p), cell: CELL, origin: at(3, 4) },
      { grid: ["@@@@"], paints: paints(p), cell: CELL, origin: at(9, 10) },
    ],
  },
  {
    id: "prompt-block",
    note: "> + block cursor, vertical ramp",
    sprites: (p) => [
      { grid: CHEVRON, paints: paints(p), cell: CELL, origin: at(3, 4) },
      { grid: ["@@@", "@@@", "@@@", "@@@", "@@@"], paints: paints(p, 90), cell: CELL, origin: at(10, 6) },
    ],
  },
  {
    id: "spark",
    note: "> with a pixel sparkle rising off it",
    sprites: (p) => [
      { grid: CHEVRON, paints: paints(p), cell: CELL, origin: at(3, 5) },
      {
        grid: [
          "...@...", //
          "...@...",
          "..@@@..",
          "@@@@@@@",
          "..@@@..",
          "...@...",
          "...@...",
        ],
        paints: paints(p, 45),
        cell: CELL,
        origin: at(8, 2),
      },
    ],
  },
  {
    id: "bubble",
    note: "speech bubble with a lone cursor inside",
    sprites: (p) => [
      {
        grid: [
          ".##########.", //
          "############",
          "############",
          "############",
          "############",
          "############",
          "############",
          ".##########.",
          "..##........",
          "..#.........",
        ],
        paints: paints(p),
        cell: CELL,
        origin: at(2, 3),
      },
      {
        grid: ["#..", ".#.", "..#", ".#.", "#.."].map((r) => r.replaceAll("#", "B")),
        paints: { B: { kind: "solid", color: bgInk(p) } },
        cell: CELL,
        origin: at(4, 5),
      },
      { grid: ["@@@"], paints: paints(p), cell: CELL, origin: at(8, 9) },
    ],
  },
  {
    id: "bubble-ramp",
    note: "the bubble is the colour; >_ is cut out of it",
    sprites: (p) => [
      {
        grid: [
          ".@@@@@@@@@@.", //
          "@@@@@@@@@@@@",
          "@@#@@@@@@@@@",
          "@@@#@@@@@@@@",
          "@@@@#@@@@@@@",
          "@@@#@@@@@@@@",
          "@@#@@@###@@@",
          ".@@@@@@@@@@.",
          "..@@........",
          "..@.........",
        ].map((r) => r.replaceAll("#", "o")),
        paints: { ...paints(p, 60), o: { kind: "solid", color: bgInk(p) } },
        cell: CELL,
        origin: at(2, 3),
      },
    ],
  },
  {
    id: "window",
    note: "terminal window; three title-bar pixels are the colour",
    sprites: (p) => [
      {
        grid: [
          "############", //
          "#..........#",
          "############",
          "#..........#",
          "#.#........#",
          "#..#.......#",
          "#.#..###...#",
          "#..........#",
          "############",
        ],
        paints: paints(p),
        cell: CELL,
        origin: at(2, 3),
      },
      { grid: ["@.@.@"], paints: paints(p), cell: CELL, origin: at(8, 4) },
    ],
  },
  {
    id: "caret",
    note: "one big stepped caret; nothing else",
    sprites: (p) => [
      {
        grid: [
          "@@@.....", //
          ".@@@....",
          "..@@@...",
          "...@@@..",
          "....@@@.",
          "...@@@..",
          "..@@@...",
          ".@@@....",
          "@@@.....",
        ],
        paints: paints(p, 45),
        cell: CELL,
        origin: at(4, 3.5),
      },
    ],
  },
]

/** A colour that reads as "hole" — the background's mid tone. */
function bgInk(p: Palette): string {
  if (p.background.kind === "solid") return p.background.color
  return p.background.stops[Math.floor(p.background.stops.length / 2)].color
}
