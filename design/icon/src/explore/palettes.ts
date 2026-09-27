// Named colour sets. A palette is a background, an "ink" for the quiet
// foreground glyph, and one accent ramp — the only loud colour in the icon.

import type { Stop } from "../color"
import type { Paint } from "../pixel"

export interface Palette {
  id: string
  background: Paint
  ink: string
  accent: Stop[]
}

const ramp = (...colors: string[]): Stop[] =>
  colors.map((color, i) => ({ at: i / (colors.length - 1), color }))

const vertical = (top: string, bottom: string): Paint => ({
  kind: "ramp",
  stops: ramp(top, bottom),
  angle: 90,
  mode: "smooth",
})

export const accents = {
  sunset: ramp("#FFB86B", "#FF6B7D", "#B65CFF"),
  dusk: ramp("#FFC46E", "#FF7474", "#E0539A", "#9A5CFF"),
  apricot: ramp("#FFCF7A", "#FF8A6B", "#D95CD8"),
  peach: ramp("#FFC48A", "#FF7F6B", "#F2557C"),
  aurora: ramp("#6BF2C8", "#52A8FF", "#9C7CFF"),
}

export const backgrounds = {
  ink: vertical("#2C2E36", "#15161B"),
  plum: vertical("#2D2A38", "#141218"),
  indigo: vertical("#2A2548", "#131124"),
  night: vertical("#262A3A", "#101219"),
}

export function palette(
  bg: keyof typeof backgrounds,
  accent: keyof typeof accents,
  ink?: string,
): Palette {
  return {
    id: `${bg}/${accent}`,
    background: backgrounds[bg],
    ink: ink ?? "#F4F2EE",
    accent: accents[accent],
  }
}
