// IIFE bundle for JavaScriptCore — exposes globalThis.tokenize(code, lang)
// Produces [[text, scope], ...] JSON from highlight.js HTML output.

import hljs from 'highlight.js/lib/common'

interface Token {
  text: string
  scope: string | null
}

const ENTITY_MAP: Record<string, string> = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#x27;': "'",
  '&#39;': "'",
}

function decodeEntities(s: string): string {
  return s.replace(/&(?:amp|lt|gt|quot|#x27|#39);/g, m => ENTITY_MAP[m] ?? m)
}

/**
 * Parse highlight.js HTML output into flat [text, scope] tokens.
 * Handles nested <span class="hljs-..."> by maintaining a scope stack.
 */
function parseHTML(html: string): Token[] {
  const tokens: Token[] = []
  const scopeStack: string[] = []
  let i = 0

  while (i < html.length) {
    if (html[i] === '<') {
      const closeTag = html.indexOf('>', i)
      if (closeTag === -1) break

      const tag = html.substring(i, closeTag + 1)
      if (tag.startsWith('</')) {
        // closing tag — pop scope
        scopeStack.pop()
      } else {
        // opening tag — extract class
        const classMatch = tag.match(/class="([^"]*)"/)
        const scope = classMatch ? classMatch[1] : null
        scopeStack.push(scope ?? '')
      }
      i = closeTag + 1
    } else {
      // text node — find next '<' or end
      const nextTag = html.indexOf('<', i)
      const end = nextTag === -1 ? html.length : nextTag
      const raw = html.substring(i, end)
      if (raw.length > 0) {
        const text = decodeEntities(raw)
        // current scope is the innermost non-empty scope on the stack
        let scope: string | null = null
        for (let j = scopeStack.length - 1; j >= 0; j--) {
          if (scopeStack[j]) {
            scope = scopeStack[j]
            break
          }
        }
        tokens.push({ text, scope })
      }
      i = end
    }
  }

  return tokens
}

/**
 * Tokenize code using highlight.js and return JSON string of [[text, scope], ...]
 * @param code - source code to highlight
 * @param lang - language name (e.g. "bash", "swift") or null for auto-detect
 * @returns JSON string
 */
function tokenize(code: string, lang?: string | null): string {
  try {
    let result
    if (lang && hljs.getLanguage(lang)) {
      result = hljs.highlight(code, { language: lang })
    } else {
      result = hljs.highlightAuto(code)
    }

    const tokens = parseHTML(result.value)

    // Merge adjacent tokens with same scope for efficiency
    const merged: [string, string | null][] = []
    for (const t of tokens) {
      const last = merged.length > 0 ? merged[merged.length - 1] : null
      if (last && last[1] === t.scope) {
        last[0] += t.text
      } else {
        merged.push([t.text, t.scope])
      }
    }

    return JSON.stringify(merged)
  } catch {
    // Fallback: return entire code as plain text
    return JSON.stringify([[code, null]])
  }
}

/**
 * Batch variant: tokenize multiple code blocks in a single JSCore round-trip.
 * Input: JSON string of `[[code, lang|null], ...]`.
 * Output: JSON string of `[[[text, scope], ...], ...]` — preserving order.
 *
 * Saves (N-1) JSCore-boundary crossings + JSON (de)serialisations when a
 * single assistant message has multiple code blocks.
 */
function tokenizeBatch(requestsJson: string): string {
  let requests: [string, string | null][]
  try {
    requests = JSON.parse(requestsJson)
  } catch {
    return '[]'
  }
  const out: [string, string | null][][] = []
  for (const req of requests) {
    const code = typeof req?.[0] === 'string' ? req[0] : ''
    const lang = typeof req?.[1] === 'string' ? req[1] : null
    try {
      const single = tokenize(code, lang)
      out.push(JSON.parse(single))
    } catch {
      out.push([[code, null]])
    }
  }
  return JSON.stringify(out)
}

;(globalThis as any).tokenize = tokenize
;(globalThis as any).tokenizeBatch = tokenizeBatch
