// Build Settings' glyphs: the design sheet's own paths → template SVG image sets
// in macos/Components/Sources/Components/Resources/Assets.xcassets/Settings.
// Nothing is retyped: design/settings/index.html is read and its `G` object —
// every glyph the window draws — is evaluated here, plus the toolbar's back and
// forward chevrons, which the sheet draws inline in its markup. The app and the
// sheet can't differ.
//
//   Settings<Key>   G[Key], at the size the sheet's markup gives it
//   SettingsProviderMark   the Accounts row's rack mark for an API provider (`PROVIDER_MARK`)
//   SettingsBack / SettingsForward   the toolbar's history chevrons
//
// Every set is a template image: the app tints it, as the sheet's `currentColor`.
//
//   bun run build        (make settings-icons)

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/Settings")
const SHEET = readFileSync(join(ROOT, "design/settings/index.html"), "utf8")
const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

// MARK: - The sheet's own objects

const start = SHEET.indexOf("const G = {")
const end = SHEET.indexOf("\n}\n", start)
if (start < 0 || end < 0) throw new Error("design source changed: no `const G = {` … `}`")
const G: Record<string, string> = new Function(`${SHEET.slice(start, end)}\n}; return G`)()

/** The Accounts row's mark for an API provider: a 28-pt rack, drawn on its own line of the sheet. */
const providerMark = SHEET.match(/const PROVIDER_MARK = `(<svg[^`]*<\/svg>)`/)?.[1]
if (!providerMark) throw new Error("design source changed: no `const PROVIDER_MARK`")

/** The toolbar's history button `id`: its inline `<svg>`. */
function history(id: string): string {
  const match = SHEET.match(new RegExp(`<button id="${id}"[^>]*>(<svg[\\s\\S]*?</svg>)`))
  if (!match) throw new Error(`design source changed: no <button id="${id}"> with an svg`)
  return match[1]
}

// MARK: - SVG

const INK = "#000000"
const cap = (key: string) => key[0].toUpperCase() + key.slice(1)

/** The sheet's `<svg>` as a standalone file: no class or style, its drawn size, ink black. */
function standalone(markup: string): string {
  const open = markup.match(/^<svg\b([^>]*)>/)
  const viewBox = open?.[1].match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/)
  if (!open || !viewBox) throw new Error(`not an svg with a viewBox: ${markup}`)
  // The attributes the glyph draws with stay; the sheet's layout (class, style) goes.
  const kept = open[1]
    .replace(/\s(?:class|style|width|height|xmlns)="[^"]*"/g, "")
    .replace(/\sviewBox="[^"]*"/, "")
  const width = open[1].match(/\swidth="([\d.]+)"/)?.[1] ?? viewBox[1]
  const height = open[1].match(/\sheight="([\d.]+)"/)?.[1] ?? viewBox[2]
  return markup
    .replace(
      open[0],
      `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${viewBox[1]} ${viewBox[2]}"${kept}>`,
    )
    .replaceAll("currentColor", INK)
}

/** The warning triangle. The sheet knocks its bar and dot out in white; a
 *  template image has no white, so the same bar and dot are cut out of the
 *  triangle (even-odd), the bar as the stroke's round-capped outline. */
function warning(markup: string): string {
  const triangle = markup.match(/<path d="([^"]+)"\/>/)?.[1]
  const bar = markup.match(/<path d="M([\d.]+) ([\d.]+)v([\d.]+)" stroke="#fff" stroke-width="([\d.]+)"/)
  const dot = markup.match(/<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)" fill="#fff"\/>/)
  if (!triangle || !bar || !dot) throw new Error(`design source changed: warn is ${markup}`)
  const [x, y, length, width] = bar.slice(1).map(Number)
  const r = width / 2
  const cut =
    `M${x - r} ${y}A${r} ${r} 0 0 1 ${x + r} ${y}V${y + length}A${r} ${r} 0 0 1 ${x - r} ${y + length}Z` +
    `M${Number(dot[1]) - Number(dot[3])} ${dot[2]}A${dot[3]} ${dot[3]} 0 1 0 ${Number(dot[1]) + Number(dot[3])} ${dot[2]}` +
    `A${dot[3]} ${dot[3]} 0 1 0 ${Number(dot[1]) - Number(dot[3])} ${dot[2]}Z`
  const open = markup.match(/^<svg\b[^>]*>/)![0]
  return standalone(`${open}<path fill-rule="evenodd" d="${triangle}${cut}"/></svg>`)
}

// MARK: - The asset catalog

function imageSet(name: string, svg: string) {
  const dir = join(ASSETS, `${name}.imageset`)
  mkdirSync(dir)
  writeFileSync(join(dir, `${name}.svg`), `${svg}\n`)
  writeFileSync(
    join(dir, "Contents.json"),
    json({
      images: [{ filename: `${name}.svg`, idiom: "universal" }],
      info: INFO,
      properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
    }),
  )
}

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))

for (const [key, markup] of Object.entries(G)) {
  imageSet(`Settings${cap(key)}`, key === "warn" ? warning(markup) : standalone(markup))
}
imageSet("SettingsProviderMark", standalone(providerMark))
imageSet("SettingsBack", standalone(history("back")))
imageSet("SettingsForward", standalone(history("fwd")))
console.log(`wrote ${ASSETS}`)
