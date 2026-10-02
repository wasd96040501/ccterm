// Build the sidebar's glyphs: the geometry below → SVG image sets in
// macos/ccterm/Assets.xcassets/Sidebar, plus index.html, the design sheet,
// drawn from the same paths. The subagent and the workflow are template glyphs
// tinted by the system's colours; the conversation is a full-colour document
// icon (white paper, the app's prompt on it) that is never tinted.
//
//   bun run build

import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/ccterm/Assets.xcassets/Sidebar")
const SHEET = resolve(import.meta.dir, "../index.html")

// MARK: - Colour: as Xcode colours its file types
//
// Xcode's navigator tints each file type's glyph with a colour set from its
// DVTUserInterfaceKit catalog, made to sit beside the system folder in both
// appearances: mostly system colours (doc-gray and doc-purple are systemGray
// and systemIndigo), plus a few of its own (doc-swift). Its navigator reads
// blue folders and orange Swift files, complements, with the rest quieter.
// So here: a conversation, the row there is most of, is a coral of our own —
// systemOrange is too bright for so many rows — the way Swift has its own;
// a subagent, nested and secondary, is grey; a workflow, rare, is the one
// cool accent. A system colour is named by the app (`NSColor.systemGray`)
// and resolved per appearance; the values here are only for the sheet,
// macOS 26's. A colour of our own becomes a colour set, `asset`.

type Colour = { name: string; light: string; dark: string; asset?: string }

const COLOURS = {
  // oklch(0.70 0.155 50): the folder's tab lightness, clean.
  coral: { name: "coral", light: "#e97d39", dark: "#e97d39", asset: "SidebarCoral" },
  gray: { name: "systemGray", light: "#8e8e93", dark: "#98989d" },
  // The title's secondary ink, a step down: what the design's `--tertiary` is.
  tertiary: { name: "tertiaryLabelColor", light: "#b4b4b6", dark: "#6c6c70" },
  indigo: { name: "systemIndigo", light: "#6155f5", dark: "#6d7cff" },
} satisfies Record<string, Colour>

// MARK: - Geometry: Lamé curves |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt grid, y down

const num = (v: number) => String(Math.round(v * 1000) / 1000)

/** The curve around (cx, cy), sampled; clockwise on screen. */
function lame(cx: number, cy: number, a: number, b: number, n: number, steps = 144): string {
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
  /** A glyph drawn as it is in the design: strokes in `ink`, on its own
   *  `size` box rather than the 16-pt grid. */
  markup?: (ink: string) => string
  size?: [number, number]
  colour: Colour
}

const GLYPHS: Glyph[] = [
  {
    asset: "SidebarAgent",
    name: "Subagent",
    role: "an agent run",
    geometry:
      "Lamé star n = 0.8, radius 7.5: four cusps on the axes, sides concave, between the astroid (n = ⅔) and the rhombus (n = 1).",
    fill: lame(8, 8, 7.5, 7.5, 0.8),
    colour: COLOURS.gray,
  },
  {
    asset: "SidebarWorkflow",
    name: "Workflow",
    role: "a workflow run",
    geometry:
      "Two squircle nodes n = 4, 5.5 wide, on the diagonal 8 pt apart; one 1.5-pt connector turning through a 2.5-pt arc.",
    fill: lame(4, 4, 2.75, 2.75, 4) + lame(12, 12, 2.75, 2.75, 4),
    stroke: "M4 6.75V9.5A2.5 2.5 0 0 0 6.5 12H9.25",
    colour: COLOURS.indigo,
  },
  {
    // design/transcript/preview-live.js `LV.branch`, verbatim: the sidebar row's
    // mark after a worktree session's title. 1:1 with the design, so not a Lamé
    // shape — three small rings and the line that joins them.
    asset: "SidebarWorktree",
    name: "Worktree",
    role: "a session in a worktree",
    geometry:
      "The design's branch glyph as drawn there, 9 × 10: three 1.2-pt-radius rings, two stacked and one up and to the right, a 1-pt line from the lower ring past the upper to the third ring. Shown after the title, in the tertiary ink.",
    fill: "",
    markup: (ink) =>
      `<g fill="none" stroke="${ink}" stroke-width="1">` +
      `<circle cx="2.2" cy="2" r="1.2"/><circle cx="2.2" cy="8" r="1.2"/><circle cx="6.8" cy="3.4" r="1.2"/>` +
      `<path d="M2.2 3.2v3.6M6.8 4.6c0 1.6-4.6 1-4.6 2.2"/></g>`,
    size: [9, 10],
    colour: COLOURS.tertiary,
  },
]

// MARK: - The conversation icon: white paper with the app's prompt
//
// A Mac document is white with its kind's emblem, the way a Swift file is white
// paper with an orange bird (design/transcript 08-live.md). One squircle bubble
// (n = 4, 13 × 10) with a tail to the lower left; the app icon's prompt on it,
// small — the chevron in system grey, the cursor one solid block in the middle
// of the icon's coral ramp. Full colour, not a template, so it stays itself on a
// selected row, as Finder's icons do. The edge is drawn twice as wide *under*
// the fill, so only its outer half shows and the tail joins the body with no seam.

const BUBBLE =
  lame(8, 7.2, 6.6, 5.1, 4, 96) + "M3.5 10.8L8.2 11.6L3.7 14.7Q3.2 15 3.2 14.4Z"
const CHEVRON = "M5.1 5.3l1.9 1.9-1.9 1.9"
const CURSOR = { x: 8.6, y: 5.3, width: 2.1, height: 3.8, rx: 0.35 }
const INK = "#6E6E73"
const CORAL = "#FF6E7C"
const PAPER = {
  light: { fill: "#FFFFFF", edge: 0.34 },
  dark: { fill: "#F5F5F7", edge: 0.5 },
}

const DOCUMENT = {
  asset: "SidebarSession",
  name: "Conversation",
  role: "a session",
  geometry:
    "Squircle bubble n = 4, 13 × 10 about (8, 7.2), a tail from its lower left; white paper with a 0.55-pt edge at 34 % black (50 % in Dark, on #F5F5F7). The prompt: a 1.15-pt chevron in #6E6E73 and the cursor as one coral block, #FF6E7C.",
}

function documentSvg(mode: "light" | "dark"): string {
  const { fill, edge } = PAPER[mode]
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
    `<path d="${BUBBLE}" fill="none" stroke="#000000" stroke-opacity="${edge}" stroke-width="1.1" stroke-linejoin="round"/>` +
    `<path d="${BUBBLE}" fill="${fill}"/>` +
    `<path d="${CHEVRON}" fill="none" stroke="${INK}" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<rect x="${CURSOR.x}" y="${CURSOR.y}" width="${CURSOR.width}" height="${CURSOR.height}" rx="${CURSOR.rx}" fill="${CORAL}"/>` +
    `</svg>`
  )
}

// MARK: - Asset catalog

const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

function svg(glyph: Glyph, colour = "#000000"): string {
  if (glyph.markup) {
    const [w, h] = glyph.size ?? [16, 16]
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${glyph.markup(colour)}</svg>`
  }
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
{
  const images = join(ASSETS, `${DOCUMENT.asset}.imageset`)
  mkdirSync(images)
  writeFileSync(join(images, `${DOCUMENT.asset}.svg`), `${documentSvg("light")}\n`)
  writeFileSync(join(images, `${DOCUMENT.asset}-dark.svg`), `${documentSvg("dark")}\n`)
  writeFileSync(
    join(images, "Contents.json"),
    json({
      images: [
        { filename: `${DOCUMENT.asset}.svg`, idiom: "universal" },
        {
          appearances: [{ appearance: "luminosity", value: "dark" }],
          filename: `${DOCUMENT.asset}-dark.svg`,
          idiom: "universal",
        },
      ],
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": "original" },
    }),
  )
}
for (const colour of Object.values(COLOURS) as Colour[]) {
  if (!colour.asset) continue
  const set = join(ASSETS, `${colour.asset}.colorset`)
  mkdirSync(set)
  const components = (hex: string) => {
    const [red, green, blue] = [1, 3, 5].map((i) => `0x${hex.slice(i, i + 2).toUpperCase()}`)
    return { "color-space": "srgb", components: { alpha: "1.000", red, green, blue } }
  }
  writeFileSync(
    join(set, "Contents.json"),
    json({
      colors: [
        { color: components(colour.light), idiom: "universal" },
        { appearances: [{ appearance: "luminosity", value: "dark" }], color: components(colour.dark), idiom: "universal" },
      ],
      info: INFO,
    }),
  )
}
console.log(`wrote ${ASSETS}`)

// MARK: - Design sheet

const grid = Array.from({ length: 17 }, (_, i) => `M0 ${i}H16M${i} 0V16`).join("")

/** What a glyph draws, centred on the 16-pt grid. */
function drawn(glyph: Glyph, c: string): string {
  if (glyph.markup) {
    const [w, h] = glyph.size ?? [16, 16]
    return `<g transform="translate(${(16 - w) / 2} ${(16 - h) / 2})">${glyph.markup(c)}</g>`
  }
  const stroke = glyph.stroke
    ? `<path d="${glyph.stroke}" fill="none" stroke="${c}" stroke-width="1.5" stroke-linecap="round"/>`
    : ""
  return `<path d="${glyph.fill}" fill="${c}"/>${stroke}`
}

function construction(glyph: Glyph, c: string): string {
  return (
    `<svg width="192" height="192" viewBox="0 0 16 16">` +
    `<path d="${grid}" stroke="var(--grid)" stroke-width="0.04"/>` +
    `<g fill="none" stroke="var(--key)" stroke-width="0.05" stroke-dasharray="0.25 0.2">` +
    `<circle cx="8" cy="8" r="7.5"/><path d="M8 0V16M0 8H16"/></g>` +
    `${drawn(glyph, c)}</svg>`
  )
}

const documentIcon = (dark: boolean) => {
  const { fill, edge } = PAPER[dark ? "dark" : "light"]
  return (
    `<path d="${BUBBLE}" fill="none" stroke="#000" stroke-opacity="${edge}" stroke-width="1.1" stroke-linejoin="round"/>` +
    `<path d="${BUBBLE}" fill="${fill}"/>` +
    `<path d="${CHEVRON}" fill="none" stroke="${INK}" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<rect x="${CURSOR.x}" y="${CURSOR.y}" width="${CURSOR.width}" height="${CURSOR.height}" rx="${CURSOR.rx}" fill="${CORAL}"/>`
  )
}

function documentConstruction(): string {
  return (
    `<svg width="192" height="192" viewBox="0 0 16 16" style="background:#e9e9eb;border-radius:12px">` +
    `<path d="${grid}" stroke="var(--grid)" stroke-width="0.04"/>` +
    documentIcon(false) +
    `</svg>`
  )
}

type Row = {
  level: number
  open?: boolean
  kind: "folder" | Glyph["asset"] | "SidebarSession"
  title: string
  selected?: boolean
  /** A worktree session: the branch mark after its title. */
  worktree?: boolean
}
const ROWS: Row[] = [
  { level: 0, open: true, kind: "folder", title: "ccterm" },
  { level: 1, open: true, kind: "SidebarSession", title: "Sidebar and session preview", selected: true },
  { level: 2, open: true, kind: "folder", title: "Subagents" },
  { level: 3, kind: "SidebarAgent", title: "Explore the transcript parser" },
  { level: 2, open: true, kind: "SidebarWorkflow", title: "review-changes" },
  { level: 3, kind: "SidebarAgent", title: "review: bugs" },
  { level: 1, open: false, kind: "SidebarSession", title: "Squash merge admin" },
  { level: 1, open: false, kind: "SidebarSession", title: "Fix the gutter overflow", worktree: true },
]

// Xcode's navigator geometry: 22-pt rows, 14-pt indent, the icon 13 pt past
// the chevron, the title 34.
function sidebar(dark: boolean): string {
  const W = 282
  const rows = ROWS.map((row, i) => {
    const x = 14 + row.level * 14
    const y = 8 + i * 22
    const isDocument = row.kind === "SidebarSession"
    const glyph = GLYPHS.find((g) => g.asset === row.kind)
    const ink = row.selected ? "#ffffff" : glyph ? (dark ? glyph.colour.dark : glyph.colour.light) : ""
    const chevron =
      row.open === undefined
        ? ""
        : `<path d="${row.open ? `M${x + 1} ${y + 9}L${x + 4} ${y + 12}L${x + 7} ${y + 9}` : `M${x + 2.5} ${y + 7.5}L${x + 5.5} ${y + 10.5}L${x + 2.5} ${y + 13.5}`}" fill="none" stroke="${row.selected ? "#fff" : dark ? "#98989d" : "#8a8a8e"}" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/>`
    const icon = isDocument
      ? documentIcon(dark)
      : glyph
      ? drawn(glyph, ink)
      : `<path d="M1 4.2Q1 3 2.2 3H6L7.4 4.4H13.8Q15 4.4 15 5.6V6H1Z" fill="#5aa8ec"/><path d="M1 5.6H15V12.8Q15 14 13.8 14H2.2Q1 14 1 12.8Z" fill="#7cc0f6"/>`
    const highlight = row.selected ? `<rect x="10" y="${y}" width="${W - 20}" height="22" rx="5" fill="#2f6fdf"/>` : ""
    const text = row.selected ? "#ffffff" : dark ? "#e8e8ea" : "#1d1d1f"
    const mark = row.worktree ? GLYPHS.find((g) => g.asset === "SidebarWorktree") : undefined
    // The title's width is the sheet's estimate; the app lays it out for real.
    const wt = mark?.markup
      ? `<g transform="translate(${x + 34 + row.title.length * 6.5 + 5} ${y + 6})">${mark.markup(row.selected ? "#fff" : dark ? mark.colour.dark : mark.colour.light)}</g>`
      : ""
    return (
      highlight +
      chevron +
      `<g transform="translate(${x + 13} ${y + 3})">${icon}</g>` +
      `<text x="${x + 34}" y="${y + 15.5}" font-size="13" fill="${text}">${row.title}</text>` +
      wt
    )
  }).join("")
  return (
    `<svg width="${W * 2}" height="${(ROWS.length * 22 + 16) * 2}" viewBox="0 0 ${W} ${ROWS.length * 22 + 16}" ` +
    `style="background:${dark ? "#2a2a2d" : "#e9e9eb"}">${rows}</svg>`
  )
}

const documentCard = `<section class="card">
  ${documentConstruction()}
  <div class="title"><h2>${DOCUMENT.name}</h2><span>${DOCUMENT.role} · <code>${DOCUMENT.asset}</code></span></div>
  <p>${DOCUMENT.geometry}</p>
  <div class="swatch"><i style="background:${PAPER.light.fill};box-shadow:inset 0 0 0 1px #ccc"></i><i style="background:${PAPER.dark.fill};box-shadow:inset 0 0 0 1px #ccc"></i><code>full colour, not a template · white ${PAPER.light.fill} · ${PAPER.dark.fill} in Dark</code></div>
</section>`

const cards = documentCard + GLYPHS.map((glyph) => {
  const { name, light, dark } = glyph.colour
  return `<section class="card">
  ${construction(glyph, light)}
  <div class="title"><h2>${glyph.name}</h2><span>${glyph.role} · <code>${glyph.asset}</code></span></div>
  <p>${glyph.geometry}</p>
  <div class="swatch"><i style="background:${light}"></i><i style="background:${dark}"></i><code>${name} · ${light === dark ? light : `${light} light · ${dark} dark`}</code></div>
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
<p class="lede">Every outline is a Lamé curve |x/a|ⁿ + |y/b|ⁿ = 1 on the 16-pt grid · the conversation is white paper with the app's prompt, as a Mac document is; the others are tinted like Xcode's file types</p>
</header>
<div class="cards">
${cards}
</div>
<div class="mocks">${sidebar(false)}${sidebar(true)}</div>
<p class="note">Sidebars at 2×, in Xcode's navigator geometry. Folders are the system icon, drawn approximately here. On a selected, focused row the subagent and workflow glyphs turn white, like the title; the conversation stays itself, as Finder's icons do.</p>
</main>
</body>
</html>
`,
)
console.log(`wrote ${SHEET}`)
