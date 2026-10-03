// MARK: - Optical size: preview-live.js `optical`, with the browser's getBBox done here

type Box = { x0: number; y0: number; x1: number; y1: number }
const empty = (): Box => ({ x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity })
const add = (b: Box, x: number, y: number) => {
  b.x0 = Math.min(b.x0, x)
  b.y0 = Math.min(b.y0, y)
  b.x1 = Math.max(b.x1, x)
  b.y1 = Math.max(b.y1, y)
}

/** The geometric bounds of an SVG path (no stroke), as getBBox gives them. */
function pathBox(d: string, box: Box) {
  const tokens = d.match(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/g) ?? []
  let i = 0
  let command = ""
  let x = 0
  let y = 0
  let startX = 0
  let startY = 0
  const number = () => Number(tokens[i++])
  while (i < tokens.length) {
    if (/[a-zA-Z]/.test(tokens[i])) command = tokens[i++]
    const relative = command === command.toLowerCase()
    const ox = relative ? x : 0
    const oy = relative ? y : 0
    switch (command.toUpperCase()) {
      case "M":
        x = ox + number()
        y = oy + number()
        startX = x
        startY = y
        add(box, x, y)
        command = relative ? "l" : "L"
        break
      case "L":
        x = ox + number()
        y = oy + number()
        add(box, x, y)
        break
      case "H":
        x = ox + number()
        add(box, x, y)
        break
      case "V":
        y = oy + number()
        add(box, x, y)
        break
      case "C": {
        const p = [ox + number(), oy + number(), ox + number(), oy + number(), ox + number(), oy + number()]
        for (let s = 0; s <= 200; s++) {
          const t = s / 200
          const u = 1 - t
          add(
            box,
            u * u * u * x + 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t * t * t * p[4],
            u * u * u * y + 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t * t * t * p[5],
          )
        }
        x = p[4]
        y = p[5]
        break
      }
      case "Z":
        x = startX
        y = startY
        break
      default:
        throw new Error(`path command ${command}`)
    }
  }
}

/** The bounds of a glyph's elements (path, rect, circle), as getBBox on their group. */
function bodyBox(body: string): Box {
  const box = empty()
  for (const [, tag, attrs] of body.matchAll(/<(path|rect|circle)\b([^>]*)\/>/g)) {
    const attr = (name: string) => Number(attrs.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1] ?? 0)
    if (tag === "path") pathBox(attrs.match(/\bd="([^"]*)"/)![1], box)
    if (tag === "rect") {
      add(box, attr("x"), attr("y"))
      add(box, attr("x") + attr("width"), attr("y") + attr("height"))
    }
    if (tag === "circle") {
      add(box, attr("cx") - attr("r"), attr("cy") - attr("r"))
      add(box, attr("cx") + attr("r"), attr("cy") + attr("r"))
    }
  }
  return box
}

/** `svg16`: the glyph scaled so its ink covers √(w·h) = 11.5 of the 16 grid
 *  (long side ≤ 14), centred, its stroke divided by the scale so every glyph
 *  keeps the 1.3 weight. */
export function svg16(body: string): string {
  const b = bodyBox(body)
  const filledOnly = /stroke="none"/.test(body) && !/<(path|circle|rect)(?![^>]*stroke="none")/.test(body)
  const pad = filledOnly ? 0 : 1.3
  const w = b.x1 - b.x0 + pad
  const h = b.y1 - b.y0 + pad
  const k = Math.min(11.5 / Math.sqrt(w * h), 14 / Math.max(w, h))
  const transform = `translate(8 8) scale(${k.toFixed(3)}) translate(${(-(b.x0 + (b.x1 - b.x0) / 2)).toFixed(2)} ${(-(b.y0 + (b.y1 - b.y0) / 2)).toFixed(2)})`
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` +
    `<g transform="${transform}" fill="none" stroke="#000000" stroke-width="${(1.3 / k).toFixed(2)}" stroke-linecap="round" stroke-linejoin="round">` +
    `${ink(body)}</g></svg>`
  )
}

const ink = (body: string) => body.replaceAll("currentColor", "#000000")
