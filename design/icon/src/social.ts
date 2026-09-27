// GitHub social preview (Settings → General → Social preview): 1280 × 640,
// the shipping icon render beside the wordmark, on the icon's own background.
// `bun run build` regenerates it along with preview.png, which it embeds.
//
//   bun run social           rewrite social-preview.png from the current preview.png
//
// GitHub has no API for the social preview; upload the PNG by hand.

import { writeFileSync } from "node:fs"
import { resolve } from "node:path"
import { Resvg } from "@resvg/resvg-js"
import { SHIP } from "./design"
import { imageEl } from "./icon-doc"

const W = 1280
const H = 640
const ICON = 400
const PREVIEW = resolve(import.meta.dir, "../preview.png")
export const SOCIAL = resolve(import.meta.dir, "../social-preview.png")

export function socialPNG(): Buffer {
  const [top, bottom] = [SHIP.background[0].color, SHIP.background.at(-1)!.color]
  const iconX = 200
  const iconY = (H - ICON) / 2
  const textX = iconX + ICON + 64
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">` +
    `<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">` +
    `<stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient></defs>` +
    `<rect width="${W}" height="${H}" fill="url(#bg)"/>` +
    imageEl(PREVIEW, iconX, iconY, ICON) +
    `<text x="${textX}" y="${H / 2 - 4}" font-family="Helvetica Neue" font-weight="700" font-size="104" ` +
    `letter-spacing="-2" fill="${SHIP.ink}">CCTerm</text>` +
    `<text x="${textX + 4}" y="${H / 2 + 64}" font-family="Helvetica Neue" font-size="36" ` +
    `fill="${SHIP.ink}" fill-opacity="0.6">A native macOS client</text>` +
    `<text x="${textX + 4}" y="${H / 2 + 112}" font-family="Helvetica Neue" font-size="36" ` +
    `fill="${SHIP.ink}" fill-opacity="0.6">for Claude Code</text>` +
    `</svg>`
  return new Resvg(svg, { font: { loadSystemFonts: true } }).render().asPng()
}

if (import.meta.main) {
  writeFileSync(SOCIAL, socialPNG())
  console.log(`social preview → ${SOCIAL}`)
}
