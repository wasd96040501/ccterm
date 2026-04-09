import type { CSSProperties } from 'react'

export interface AnsiStyle {
  bold?: boolean
  dim?: boolean
  italic?: boolean
  underline?: boolean
  fg?: string
  bg?: string
}

export interface AnsiSpan {
  text: string
  style: AnsiStyle | null
}

const STANDARD_COLORS = [
  '#000000', '#c23621', '#25bc24', '#adad27',
  '#492ee1', '#d338d3', '#33bbc8', '#cbcccd',
]

const BRIGHT_COLORS = [
  '#666666', '#ff6456', '#4ae94a', '#ffff52',
  '#7d7dff', '#ff79ff', '#60fdff', '#ffffff',
]

let palette256: string[] | null = null

function getPalette256(): string[] {
  if (palette256) return palette256
  palette256 = [...STANDARD_COLORS, ...BRIGHT_COLORS]
  // 216 color cube (16-231)
  const levels = [0, 95, 135, 175, 215, 255]
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++) {
        palette256.push(`#${levels[r].toString(16).padStart(2, '0')}${levels[g].toString(16).padStart(2, '0')}${levels[b].toString(16).padStart(2, '0')}`)
      }
    }
  }
  // 24 grayscale (232-255)
  for (let i = 0; i < 24; i++) {
    const v = (8 + i * 10).toString(16).padStart(2, '0')
    palette256.push(`#${v}${v}${v}`)
  }
  return palette256
}

function parseSgrCodes(params: string, style: AnsiStyle): AnsiStyle {
  const codes = params === '' ? [0] : params.split(';').map(Number)
  const s = { ...style }
  let i = 0
  while (i < codes.length) {
    const c = codes[i]
    if (c === 0) {
      return {}
    } else if (c === 1) {
      s.bold = true
    } else if (c === 2) {
      s.dim = true
    } else if (c === 3) {
      s.italic = true
    } else if (c === 4) {
      s.underline = true
    } else if (c === 22) {
      s.bold = undefined; s.dim = undefined
    } else if (c === 23) {
      s.italic = undefined
    } else if (c === 24) {
      s.underline = undefined
    } else if (c >= 30 && c <= 37) {
      s.fg = STANDARD_COLORS[c - 30]
    } else if (c === 39) {
      s.fg = undefined
    } else if (c >= 40 && c <= 47) {
      s.bg = STANDARD_COLORS[c - 40]
    } else if (c === 49) {
      s.bg = undefined
    } else if (c >= 90 && c <= 97) {
      s.fg = BRIGHT_COLORS[c - 90]
    } else if (c >= 100 && c <= 107) {
      s.bg = BRIGHT_COLORS[c - 100]
    } else if (c === 38 || c === 48) {
      const isFg = c === 38
      if (codes[i + 1] === 5 && i + 2 < codes.length) {
        const idx = codes[i + 2]
        const pal = getPalette256()
        if (idx >= 0 && idx < 256) {
          if (isFg) s.fg = pal[idx]; else s.bg = pal[idx]
        }
        i += 2
      } else if (codes[i + 1] === 2 && i + 4 < codes.length) {
        const r = codes[i + 2], g = codes[i + 3], b = codes[i + 4]
        const color = `rgb(${r},${g},${b})`
        if (isFg) s.fg = color; else s.bg = color
        i += 4
      }
    }
    i++
  }
  return s
}

function isEmptyStyle(s: AnsiStyle): boolean {
  return !s.bold && !s.dim && !s.italic && !s.underline && !s.fg && !s.bg
}

export function parseAnsiToSpans(text: string): AnsiSpan[] {
  const spans: AnsiSpan[] = []
  let currentStyle: AnsiStyle = {}
  const re = /\x1b\[([0-9;]*)m|\x1b\[[^a-zA-Z]*[a-zA-Z]/g
  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = re.exec(text)) !== null) {
    if (match.index > lastIndex) {
      const t = text.slice(lastIndex, match.index)
      spans.push({ text: t, style: isEmptyStyle(currentStyle) ? null : { ...currentStyle } })
    }
    if (match[1] !== undefined) {
      currentStyle = parseSgrCodes(match[1], currentStyle)
    }
    lastIndex = re.lastIndex
  }

  if (lastIndex < text.length) {
    const t = text.slice(lastIndex)
    spans.push({ text: t, style: isEmptyStyle(currentStyle) ? null : { ...currentStyle } })
  }

  return spans
}

export function ansiStyleToCss(style: AnsiStyle | null): CSSProperties | undefined {
  if (!style) return undefined
  const css: CSSProperties = {}
  if (style.bold) css.fontWeight = 'bold'
  if (style.dim) css.opacity = 0.5
  if (style.italic) css.fontStyle = 'italic'
  if (style.underline) css.textDecoration = 'underline'
  if (style.fg) css.color = style.fg
  if (style.bg) css.backgroundColor = style.bg
  return Object.keys(css).length > 0 ? css : undefined
}
