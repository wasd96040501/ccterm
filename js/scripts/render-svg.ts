// Rasterize an SVG file to a PNG at a given pixel width, preserving alpha.
// Usage: bun run scripts/render-svg.ts <in.svg> <out.png> <px>
// Uses @resvg/resvg-js (already a devDependency) — unlike qlmanage, it keeps
// transparency, which Icon Composer's foreground layer requires.
import { readFileSync, writeFileSync } from "node:fs"
import { Resvg } from "@resvg/resvg-js"

const [, , inPath, outPath, pxArg] = process.argv
const px = Number(pxArg) || 1024
const svg = readFileSync(inPath, "utf8")
const png = new Resvg(svg, { fitTo: { mode: "width", value: px } }).render().asPng()
writeFileSync(outPath, png)
console.log(`rendered ${inPath} → ${outPath} (${px}px, alpha preserved)`)
