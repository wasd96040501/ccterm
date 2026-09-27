// Colour math. Gradients are interpolated in OKLab so a ramp between two
// saturated hues stays saturated through the middle instead of greying out
// the way an sRGB lerp does — the difference is most visible on a stepped
// (per-pixel) ramp, where every step is a flat colour you can see.

export type RGB = [number, number, number] // 0…1, sRGB-encoded

export function hex(h: string): RGB {
  const s = h.replace("#", "")
  return [0, 2, 4].map((i) => parseInt(s.slice(i, i + 2), 16) / 255) as RGB
}

export function toHex([r, g, b]: RGB): string {
  const c = (v: number) =>
    Math.round(Math.min(1, Math.max(0, v)) * 255)
      .toString(16)
      .padStart(2, "0")
  return `#${c(r)}${c(g)}${c(b)}`
}

const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
const enc = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055)

function toOklab([r, g, b]: RGB): RGB {
  const [R, G, B] = [lin(r), lin(g), lin(b)]
  const l = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
  const m = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
  const s = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ]
}

function fromOklab([L, a, b]: RGB): RGB {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3
  return [
    enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    enc(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ]
}

export interface Stop {
  at: number // 0…1
  color: string // #rrggbb
}

/** Sample a multi-stop ramp at t ∈ [0,1], interpolating in OKLab. */
export function sample(stops: Stop[], t: number): string {
  t = Math.min(1, Math.max(0, t))
  let i = 0
  while (i < stops.length - 2 && t > stops[i + 1].at) i++
  const a = stops[i]
  const b = stops[i + 1]
  const u = b.at === a.at ? 0 : (t - a.at) / (b.at - a.at)
  const A = toOklab(hex(a.color))
  const B = toOklab(hex(b.color))
  return toHex(fromOklab([0, 1, 2].map((k) => A[k] + (B[k] - A[k]) * u) as RGB))
}

/** Densify a ramp into many OKLab-correct sRGB stops, for SVG's sRGB-lerping gradients. */
export function densify(stops: Stop[], n = 16): Stop[] {
  return Array.from({ length: n + 1 }, (_, i) => ({ at: i / n, color: sample(stops, i / n) }))
}

/** "display-p3:r,g,b,a" / "srgb:…" string used by Icon Composer's icon.json. */
export function iconJsonColor(h: string, alpha = 1): string {
  const [r, g, b] = hex(h)
  return `srgb:${r.toFixed(5)},${g.toFixed(5)},${b.toFixed(5)},${alpha.toFixed(5)}`
}
