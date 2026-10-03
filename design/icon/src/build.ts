// Build the shipping icon: design.ts `SHIP` → macos/ccterm/AppIcon.icon, then
// (when Xcode's ictool is present) render every system appearance and a size
// ladder into out/review.png for a look before committing.
//
//   bun run build            write AppIcon.icon + review sheet
//   bun run build --no-render

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { Resvg } from "@resvg/resvg-js"
import { compose, SHIP } from "./design"
import { flatPNG, hasIctool, ictoolRender, imageEl, RENDITIONS, writeIconDoc } from "./icon-doc"
import { SOCIAL, socialPNG } from "./social"

const ROOT = resolve(import.meta.dir, "../../..")
const ICON = join(ROOT, "macos/ccterm/AppIcon.icon")
const OUT = resolve(import.meta.dir, "../out")

const design = compose(SHIP)
writeIconDoc(ICON, design)
console.log(`wrote ${ICON}`)

mkdirSync(OUT, { recursive: true })
writeFileSync(join(OUT, "flat-1024.png"), flatPNG(design))

if (process.argv.includes("--no-render")) process.exit(0)
if (!hasIctool()) {
  console.log("ictool not found (needs Xcode 26+) — skipping system renders")
  process.exit(0)
}

for (const r of RENDITIONS) ictoolRender(ICON, join(OUT, `render-${r}.png`), r)
writeArtSet()
// Tracked, for the README.
ictoolRender(ICON, resolve(import.meta.dir, "../preview.png"), "Default", 512)
// Tracked; uploaded by hand as the GitHub social preview.
writeFileSync(SOCIAL, socialPNG())

// Review sheet. Rows 1–2: every rendition on a light and a dark desktop.
// Row 3: Default downsampled to where the icon is actually seen — Dock
// (128/64), Finder list (32), menus (16). A pixel icon lives or dies there.
const S = 220
const P = 28
const W = RENDITIONS.length * (S + P) + P
const parts = [
  `<rect width="${W}" height="${S + P * 2}" fill="#DCDCE0"/>`,
  `<rect y="${S + P * 2}" width="${W}" height="${S + P * 2}" fill="#2A2A2E"/>`,
]
RENDITIONS.forEach((r, i) => {
  const f = join(OUT, `render-${r}.png`)
  parts.push(imageEl(f, P + i * (S + P), P, S), imageEl(f, P + i * (S + P), S + P * 3, S))
})
const ladderY = (S + P * 2) * 2
parts.push(`<rect y="${ladderY}" width="${W}" height="${256 + P * 2}" fill="#ECECEE"/>`)
let x = P
for (const s of [256, 128, 64, 32, 16]) {
  parts.push(imageEl(join(OUT, "render-Default.png"), x, ladderY + P + 256 - s, s))
  x += s + P
}
const H = ladderY + 256 + P * 2
const sheet = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${parts.join("")}</svg>`
writeFileSync(join(OUT, "review.png"), new Resvg(sheet).render().asPng())
console.log(`review → ${join(OUT, "review.png")}`)

// The icon as an image the app draws (the New view's hero): Default, and the
// Dark rendition under the Dark appearance — the app can't ask the system for
// the rendition of a view's appearance (`NSApp.applicationIconImage` is the
// one the Dock shows). Rendered by ictool, full bleed, so the hero is the
// pixels the Dock shows and its cursor rows sit at `x / 1024` of the width.
function writeArtSet() {
  const dir = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/AppIconArt.imageset")
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  const images: object[] = []
  for (const [rendition, suffix] of [["Default", ""], ["Dark", "-dark"]] as const) {
    for (const scale of [1, 2]) {
      const file = `AppIconArt${suffix}@${scale}x.png`
      ictoolRender(ICON, join(dir, file), rendition, 128 * scale)
      images.push({
        filename: file,
        idiom: "universal",
        scale: `${scale}x`,
        ...(rendition === "Dark" ? { appearances: [{ appearance: "luminosity", value: "dark" }] } : {}),
      })
    }
  }
  writeFileSync(join(dir, "Contents.json"), JSON.stringify({ images, info: { author: "xcode", version: 1 } }, null, 2) + "\n")
  console.log(`wrote ${dir}`)
}
