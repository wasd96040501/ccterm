// Build the sidebar's glyphs: the geometry below → template SVG image sets in
// macos/ccterm/Assets.xcassets/Sidebar, plus index.html, the design sheet,
// drawn from the same paths. The colours are the system's, not ours.
//
//   bun run build

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/ccterm/Assets.xcassets/Sidebar")
const SHEET = resolve(import.meta.dir, "../index.html")

// MARK: - Colour: the system's, as Xcode colours its file types
//
// Xcode's navigator tints each file type's glyph with a system colour (its
// DVTUserInterfaceKit colour sets doc-orange, doc-gray and doc-purple are
// systemOrange, systemGray and systemIndigo), made to sit beside the system
// folder in both appearances. Its navigator reads blue folders and orange
// Swift files, complements, with the rest quieter. So here: a conversation,
// the row there is most of, is orange; a subagent, nested and secondary, is
// grey; a workflow, rare, is the one cool accent. The app names them
// (`NSColor.systemOrange`, …) and the system resolves each per appearance.
// The values here are only for the sheet: macOS 26's.

type SystemColour = { name: string; light: string; dark: string }

const SYSTEM = {
  orange: { name: "systemOrange", light: "#ff8d28", dark: "#ff9230" },
  gray: { name: "systemGray", light: "#8e8e93", dark: "#98989d" },
  indigo: { name: "systemIndigo", light: "#6155f5", dark: "#6d7cff" },
} satisfies Record<string, SystemColour>

// MARK: - Geometry: Lamé curves |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt grid, y down

const num = (v: number) => String(Math.round(v * 1000) / 1000)

/** The curve around (cx, cy), sampled; clockwise on screen. */
function lame(cx: number, cy: number, a: number, b: number, n: number): string {
  const steps = 144
  const points: string[] = []
  for (let i = 0; i < steps; i++) {
    const t = (2 * Math.PI * i) / steps
    const c = Math.cos(t)
    const s = Math.sin(t)
    const x = cx + a * Math.sign(c) * Math.abs(c) ** (2 / n)
    const y = cy + b * Math.sign(s) * Math.abs(s) ** (2 / n)
    points.push(`${num(x)} ${num(y)}`)
  }
  return `M${points.join("L")}Z`
}

/** A stadium from (x1, y) to (x2, y), `w` wide; counter-clockwise, so under
 *  the non-zero rule it cuts out of a clockwise body. */
function slot(x1: number, x2: number, y: number, w: number): string {
  const r = w / 2
  return `M${x1} ${y - r}A${r} ${r} 0 0 0 ${x1} ${y + r}H${x2}A${r} ${r} 0 0 0 ${x2} ${y - r}Z`
}

type Glyph = {
  asset: string
  name: string
  role: string
  geometry: string
  fill: string
  stroke?: string
  colour: SystemColour
}

const GLYPHS: Glyph[] = [
  {
    asset: "SidebarSession",
    name: "Conversation",
    role: "a session",
    geometry:
      "Squircle body n = 4, 13 × 10 about (8, 7); a tail from its lower left; two 1.5-pt slots at y 5.5 and 8.5, 6.5 and 4 long.",
    fill:
      lame(8, 7, 6.5, 5, 4) +
      "M3.4 10.6L8.4 11.4L3.6 14.6Q3.1 14.9 3.1 14.3Z" +
      slot(4.75, 11.25, 5.5, 1.5) +
      slot(4.75, 8.75, 8.5, 1.5),
    colour: SYSTEM.orange,
  },
  {
    asset: "SidebarAgent",
    name: "Subagent",
    role: "an agent run",
    geometry:
      "Lamé star n = 0.8, radius 7.5: four cusps on the axes, sides concave, between the astroid (n = ⅔) and the rhombus (n = 1).",
    fill: lame(8, 8, 7.5, 7.5, 0.8),
    colour: SYSTEM.gray,
  },
  {
    asset: "SidebarWorkflow",
    name: "Workflow",
    role: "a workflow run",
    geometry:
      "Two squircle nodes n = 4, 5.5 wide, on the diagonal 8 pt apart; one 1.5-pt connector turning through a 2.5-pt arc.",
    fill: lame(4, 4, 2.75, 2.75, 4) + lame(12, 12, 2.75, 2.75, 4),
    stroke: "M4 6.75V9.5A2.5 2.5 0 0 0 6.5 12H9.25",
    colour: SYSTEM.indigo,
  },
]

// MARK: - Asset catalog

const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

function svg(glyph: Glyph, colour = "#000000"): string {
  const stroke = glyph.stroke
    ? `<path d="${glyph.stroke}" fill="none" stroke="${colour}" stroke-width="1.5" stroke-linecap="round"/>`
    : ""
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
    `<path d="${glyph.fill}" fill="${colour}"/>${stroke}</svg>`
  )
}

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))
for (const glyph of GLYPHS) {
  const images = join(ASSETS, `${glyph.asset}.imageset`)
  mkdirSync(images)
  const file = `${glyph.asset}.svg`
  writeFileSync(join(images, file), `${svg(glyph)}\n`)
  writeFileSync(
    join(images, "Contents.json"),
    json({
      images: [{ filename: file, idiom: "universal" }],
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
    }),
  )
}
console.log(`wrote ${ASSETS}`)

// MARK: - Design sheet

const grid = Array.from({ length: 17 }, (_, i) => `M0 ${i}H16M${i} 0V16`).join("")

function construction(glyph: Glyph, c: string): string {
  const stroke = glyph.stroke
    ? `<path d="${glyph.stroke}" fill="none" stroke="${c}" stroke-width="1.5" stroke-linecap="round"/>`
    : ""
  return (
    `<svg width="192" height="192" viewBox="0 0 16 16">` +
    `<path d="${grid}" stroke="var(--grid)" stroke-width="0.04"/>` +
    `<g fill="none" stroke="var(--key)" stroke-width="0.05" stroke-dasharray="0.25 0.2">` +
    `<circle cx="8" cy="8" r="7.5"/><path d="M8 0V16M0 8H16"/></g>` +
    `<path d="${glyph.fill}" fill="${c}"/>${stroke}</svg>`
  )
}

type Row = { level: number; open?: boolean; kind: "folder" | Glyph["asset"]; title: string; selected?: boolean }
const ROWS: Row[] = [
  { level: 0, open: true, kind: "folder", title: "ccterm" },
  { level: 1, open: true, kind: "SidebarSession", title: "Sidebar and session preview", selected: true },
  { level: 2, open: true, kind: "folder", title: "Subagents" },
  { level: 3, kind: "SidebarAgent", title: "Explore the transcript parser" },
  { level: 2, open: true, kind: "SidebarWorkflow", title: "review-changes" },
  { level: 3, kind: "SidebarAgent", title: "review: bugs" },
  { level: 1, open: false, kind: "SidebarSession", title: "Squash merge admin" },
]

// Xcode's navigator geometry: 22-pt rows, 14-pt indent, the icon 13 pt past
// the chevron, the title 34.
function sidebar(dark: boolean): string {
  const W = 282
  const rows = ROWS.map((row, i) => {
    const x = 14 + row.level * 14
    const y = 8 + i * 22
    const glyph = GLYPHS.find((g) => g.asset === row.kind)
    const ink = row.selected ? "#ffffff" : glyph ? (dark ? glyph.colour.dark : glyph.colour.light) : ""
    const chevron =
      row.open === undefined
        ? ""
        : `<path d="${row.open ? `M${x + 1} ${y + 9}L${x + 4} ${y + 12}L${x + 7} ${y + 9}` : `M${x + 2.5} ${y + 7.5}L${x + 5.5} ${y + 10.5}L${x + 2.5} ${y + 13.5}`}" fill="none" stroke="${row.selected ? "#fff" : dark ? "#98989d" : "#8a8a8e"}" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/>`
    const icon = glyph
      ? `<path d="${glyph.fill}" fill="${ink}"/>` +
        (glyph.stroke ? `<path d="${glyph.stroke}" fill="none" stroke="${ink}" stroke-width="1.5" stroke-linecap="round"/>` : "")
      : `<path d="M1 4.2Q1 3 2.2 3H6L7.4 4.4H13.8Q15 4.4 15 5.6V6H1Z" fill="#5aa8ec"/><path d="M1 5.6H15V12.8Q15 14 13.8 14H2.2Q1 14 1 12.8Z" fill="#7cc0f6"/>`
    const highlight = row.selected ? `<rect x="10" y="${y}" width="${W - 20}" height="22" rx="5" fill="#2f6fdf"/>` : ""
    const text = row.selected ? "#ffffff" : dark ? "#e8e8ea" : "#1d1d1f"
    return (
      highlight +
      chevron +
      `<g transform="translate(${x + 13} ${y + 3})">${icon}</g>` +
      `<text x="${x + 34}" y="${y + 15.5}" font-size="13" fill="${text}">${row.title}</text>`
    )
  }).join("")
  return (
    `<svg width="${W * 2}" height="${(ROWS.length * 22 + 16) * 2}" viewBox="0 0 ${W} ${ROWS.length * 22 + 16}" ` +
    `style="background:${dark ? "#2a2a2d" : "#e9e9eb"}">${rows}</svg>`
  )
}

const cards = GLYPHS.map((glyph) => {
  const { name, light, dark } = glyph.colour
  return `<section class="card">
  ${construction(glyph, light)}
  <div class="title"><h2>${glyph.name}</h2><span>${glyph.role} · <code>${glyph.asset}</code></span></div>
  <p>${glyph.geometry}</p>
  <div class="swatch"><i style="background:${light}"></i><i style="background:${dark}"></i><code>${name} · ${light} light · ${dark} dark</code></div>
</section>`
}).join("\n")

writeFileSync(
  SHEET,
  `<!doctype html>
<!-- Generated by src/build.ts — edit that, then \`make sidebar-icons\`. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sidebar Icons</title>
<style>
:root { --bg: #f4f4f2; --card: #fff; --line: #e3e3e0; --text: #1d1d1f; --muted: #6e6e73; --grid: #e6e6e3; --key: #c9c9c4; }
body { margin: 0; padding: 48px 16px; background: var(--bg); color: var(--text); font: 13px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
main { max-width: 1152px; margin: 0 auto; display: flex; flex-direction: column; gap: 32px; }
h1 { margin: 0; font-size: 28px; font-weight: 600; }
.lede { margin: 6px 0 0; color: var(--muted); font-size: 15px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 24px; display: flex; flex-direction: column; gap: 12px; }
.card > svg { align-self: center; overflow: visible; }
.title { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; flex-wrap: wrap; }
h2 { margin: 0; font-size: 17px; font-weight: 600; }
.title span, .note { color: var(--muted); font-size: 12px; }
p { margin: 0; }
code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
.swatch { display: flex; align-items: center; gap: 10px; }
.swatch i { width: 20px; height: 20px; border-radius: 5px; flex: none; }
.mocks { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
.mocks svg { width: 100%; height: auto; border-radius: 14px; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
</style>
</head>
<body>
<main>
<header>
<h1>Sidebar icons</h1>
<p class="lede">Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt grid · every colour is a system colour, the ones Xcode gives its file types</p>
</header>
<div class="cards">
${cards}
</div>
<div class="mocks">${sidebar(false)}${sidebar(true)}</div>
<p class="note">Sidebars at 2×, in Xcode's navigator geometry. Folders are the system icon, drawn approximately here. On a selected, focused row the glyphs turn white, like the title.</p>
</main>
</body>
</html>
`,
)
console.log(`wrote ${SHEET}`)
