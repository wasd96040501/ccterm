// Composed design → Icon Composer document (.icon), and → system renders via
// Xcode's `ictool`, which draws the document exactly as macOS does (squircle
// mask, Liquid Glass rim, dark / clear / tinted appearances).

import { spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { Resvg } from "@resvg/resvg-js"
import { iconJsonColor } from "./color"
import type { Composed } from "./design"
import { backgroundSVG, spriteSVG, svgDoc } from "./pixel"

export const ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
export const RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"] as const
export type Rendition = (typeof RENDITIONS)[number]

/**
 * Write `dir` (…/Name.icon) from scratch.
 *
 * The background is the document fill — a linear gradient — not a layer, so
 * the system owns it for the dark / clear / tinted renditions. Layers opt out
 * of glass: the art is flat pixels, and refraction would soften exactly the
 * edges that make it read as pixel art.
 */
export function writeIconDoc(dir: string, c: Composed): void {
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(join(dir, "Assets"), { recursive: true })
  for (const l of c.layers) writeFileSync(join(dir, "Assets", `${l.name}.svg`), svgDoc(spriteSVG(l.sprite)) + "\n")

  const bg = c.params.background
  const json = {
    fill: {
      "linear-gradient": [iconJsonColor(bg[0].color), iconJsonColor(bg.at(-1)!.color)],
      orientation: { start: { x: 0.5, y: 0 }, stop: { x: 0.5, y: 1 } },
    },
    groups: [
      {
        layers: c.layers.map((l) => ({ "image-name": `${l.name}.svg`, name: l.name, glass: false })),
        shadow: { kind: "neutral", opacity: 0.5 },
        translucency: { enabled: false, value: 0.5 },
      },
    ],
    "supported-platforms": { squares: "shared" },
  }
  writeFileSync(join(dir, "icon.json"), JSON.stringify(json, null, 2) + "\n")
}

/** Flat, full-bleed PNG of the art (no mask, no glass) — handy for docs. */
export function flatPNG(c: Composed, px = 1024): Buffer {
  const inner = backgroundSVG(c.background) + c.layers.map((l) => spriteSVG(l.sprite)).join("")
  return new Resvg(svgDoc(inner), { fitTo: { mode: "width", value: px } }).render().asPng()
}

export const hasIctool = () => existsSync(ICTOOL)

export function ictoolRender(doc: string, out: string, rendition: Rendition = "Default", px = 1024): void {
  const r = spawnSync(
    ICTOOL,
    [doc, "--export-image", "--output-file", out, "--platform", "macOS", "--rendition", rendition,
     "--width", String(px), "--height", String(px), "--scale", "1"],
    { encoding: "utf8" },
  )
  if (r.status !== 0) throw new Error(`ictool ${rendition}: ${r.stderr || r.stdout}`)
}

/** `<image>` element embedding a PNG file, for composing review sheets. */
export const imageEl = (file: string, x: number, y: number, s: number) =>
  `<image x="${x}" y="${y}" width="${s}" height="${s}" href="data:image/png;base64,${readFileSync(file).toString("base64")}"/>`
