// Build the window chrome the design sheets' window mocks draw: the traffic
// lights. The sheets draw them as CSS circles, not paths, so the numbers —
// diameter, colours, the hairline ring — are read from the sheets' own rules
// (design/settings/index.html `.traffic`, design/transcript/preview.css
// `.lights`), never retyped here. → SVG image sets in
// macos/Components/Sources/Components/Resources/Assets.xcassets/WindowChrome.
//
//   WindowChromeClose / Minimize / Zoom   Settings window: 14 pt, full colour, never tinted
//   WindowChromeInactive                  Settings window, not key: one grey light (template, tertiary ink)
//   WindowChromeLight                     transcript window: 12 pt, tertiary ink at 60 % (template)
//
//   bun run build        (make window-chrome)

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(import.meta.dir, "../../..")
const ASSETS = join(ROOT, "macos/Components/Sources/Components/Resources/Assets.xcassets/WindowChrome")
const INFO = { author: "xcode", version: 1 }
const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`

// MARK: - The sheets' rules

const settings = readFileSync(join(ROOT, "design/settings/index.html"), "utf8")
const transcript = readFileSync(join(ROOT, "design/transcript/preview.css"), "utf8")

function rule(text: string, selector: string): string {
  const match = text.match(new RegExp(`${selector.replaceAll(/[.()]/g, "\\$&")} \\{([^}]*)\\}`))
  if (!match) throw new Error(`design source changed: no rule ${selector}`)
  return match[1]
}
const px = (declarations: string, property: string) => {
  const match = declarations.match(new RegExp(`${property}: ([\\d.]+)px`))
  if (!match) throw new Error(`design source changed: no ${property} in ${declarations}`)
  return Number(match[1])
}

const light = rule(settings, ".traffic i")
const size = px(light, "width")
// `inset 0 0 0 .5px rgba(0,0,0,.12)`: a ring drawn inside the edge.
const ring = light.match(/inset 0 0 0 ([\d.]+)px rgba\(0,\s*0,\s*0,\s*([\d.]+)\)/)
if (!ring) throw new Error("design source changed: no inset ring on .traffic i")
const COLOURS = {
  Close: rule(settings, ".traffic i:nth-child(1)").match(/background: (#\w+)/)![1],
  Minimize: rule(settings, ".traffic i:nth-child(2)").match(/background: (#\w+)/)![1],
  Zoom: rule(settings, ".traffic i:nth-child(3)").match(/background: (#\w+)/)![1],
}
const mock = rule(transcript, ".lights i")
const mockSize = px(mock, "width")
const mockOpacity = Number(mock.match(/opacity: ([\d.]+)/)![1])

// MARK: - SVG

const circle = (d: number, extra: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${d}" height="${d}" viewBox="0 0 ${d} ${d}">${extra}</svg>`

const SETS: { name: string; svg: string; template: boolean }[] = [
  ...Object.entries(COLOURS).map(([part, colour]) => ({
    name: `WindowChrome${part}`,
    template: false,
    svg: circle(
      size,
      `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="${colour}"/>` +
        `<circle cx="${size / 2}" cy="${size / 2}" r="${(size - Number(ring[1])) / 2}" fill="none" stroke="#000000" stroke-opacity="${ring[2]}" stroke-width="${ring[1]}"/>`,
    ),
  })),
  // `.window.inactive .traffic i`: the colours go to the tertiary label, the ring is dropped.
  {
    name: "WindowChromeInactive",
    template: true,
    svg: circle(size, `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="#000000"/>`),
  },
  {
    name: "WindowChromeLight",
    template: true,
    svg: circle(mockSize, `<circle cx="${mockSize / 2}" cy="${mockSize / 2}" r="${mockSize / 2}" fill="#000000" fill-opacity="${mockOpacity}"/>`),
  },
]

// MARK: - The asset catalog

rmSync(ASSETS, { recursive: true, force: true })
mkdirSync(ASSETS, { recursive: true })
writeFileSync(join(ASSETS, "Contents.json"), json({ info: INFO }))
for (const { name, svg, template } of SETS) {
  const dir = join(ASSETS, `${name}.imageset`)
  mkdirSync(dir)
  writeFileSync(join(dir, `${name}.svg`), `${svg}\n`)
  writeFileSync(
    join(dir, "Contents.json"),
    json({
      images: [{ filename: `${name}.svg`, idiom: "universal" }],
      info: INFO,
      properties: {
        "preserves-vector-representation": true,
        "template-rendering-intent": template ? "template" : "original",
      },
    }),
  )
}
console.log(`wrote ${ASSETS}`)
