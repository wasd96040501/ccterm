// Export the macOS app icon.
//
// The geometry lives in `design/icon/icon-art.js` — the single source of truth
// shared with the design page (icon-capsule.html). Here we ask that module for
// a standalone vector (full-bleed squircle, NO baked shadow) and rasterise it to
// every macOS size with @resvg/resvg-js, a real SVG rasteriser shipped as a
// prebuilt binary. No system libraries, no browser, no screenshots.
//
// Run with `make appicon`. Edit icon-art.js (or the design page) and re-run; the
// vector and all PNGs follow from the same code.

import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { mkdirSync, writeFileSync, readdirSync, rmSync } from "node:fs"
import { Resvg } from "@resvg/resvg-js"
import "../../design/icon/icon-art.js"

const IconArt = (globalThis as { IconArt: { svg: (p: object) => string } }).IconArt

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, "../..")
const DESIGN_DIR = resolve(REPO_ROOT, "design/icon")
const ICONSET = resolve(REPO_ROOT, "macos/ccterm/Assets.xcassets/AppIcon.appiconset")

// Standard macOS app-icon ladder: [size, scale, pixels = size · scale].
const ENTRIES: Array<[string, "1x" | "2x", number]> = [
  ["16x16", "1x", 16],
  ["16x16", "2x", 32],
  ["32x32", "1x", 32],
  ["32x32", "2x", 64],
  ["128x128", "1x", 128],
  ["128x128", "2x", 256],
  ["256x256", "1x", 256],
  ["256x256", "2x", 512],
  ["512x512", "1x", 512],
  ["512x512", "2x", 1024],
]

const fileFor = (size: string, scale: string) =>
  scale === "1x" ? `icon_${size}.png` : `icon_${size}@${scale}.png`

mkdirSync(ICONSET, { recursive: true })

// 1) Emit the canonical vector (default state) — this is the human-readable
//    "矢量图" the PNGs are exported from.
const svg = IconArt.svg({})
const svgPath = resolve(DESIGN_DIR, "AppIcon.svg")
writeFileSync(svgPath, svg)
console.log(`vector : ${svgPath.slice(REPO_ROOT.length + 1)}`)

// 2) Drop stale PNGs, then rasterise each distinct pixel size once.
for (const f of readdirSync(ICONSET)) {
  if (f.startsWith("icon_") && f.endsWith(".png")) rmSync(resolve(ICONSET, f))
}
const pngForPx = new Map<number, Buffer>()
for (const px of [...new Set(ENTRIES.map(([, , p]) => p))].sort((a, b) => b - a)) {
  const png = new Resvg(svg, { fitTo: { mode: "width", value: px } }).render().asPng()
  pngForPx.set(px, png)
  console.log(`raster : ${px}×${px}`)
}

// 3) Write each catalogue entry + Contents.json.
const images = ENTRIES.map(([size, scale, px]) => {
  const name = fileFor(size, scale)
  writeFileSync(resolve(ICONSET, name), pngForPx.get(px)!)
  return { filename: name, idiom: "mac", scale, size }
})
writeFileSync(
  resolve(ICONSET, "Contents.json"),
  JSON.stringify({ images, info: { author: "xcode", version: 1 } }, null, 2) + "\n",
)
console.log(`wrote ${images.length} PNGs + Contents.json → ${ICONSET.slice(REPO_ROOT.length + 1)}`)
