import React, { useMemo } from 'react'
import hljs from 'highlight.js/lib/common'
import type { StructuredPatch } from '../../generated/types.generated.ts'

const EXT_TO_LANG: Record<string, string> = {
  ts: 'typescript', tsx: 'typescript',
  js: 'javascript', jsx: 'javascript',
  py: 'python', rb: 'ruby',
  swift: 'swift', rs: 'rust',
  go: 'go', java: 'java',
  kt: 'kotlin', scala: 'scala',
  css: 'css', scss: 'scss', less: 'less',
  html: 'xml', xml: 'xml', svg: 'xml',
  json: 'json', yaml: 'yaml', yml: 'yaml', toml: 'ini',
  md: 'markdown', sh: 'bash', zsh: 'bash', bash: 'bash',
  c: 'c', cpp: 'cpp', h: 'c', hpp: 'cpp', m: 'objectivec',
  sql: 'sql', graphql: 'graphql',
  php: 'php', pl: 'perl',
  r: 'r', lua: 'lua',
  makefile: 'makefile', dockerfile: 'dockerfile',
}

export function getLang(filePath: string): string | undefined {
  const name = filePath.split('/').pop()?.toLowerCase() ?? ''
  if (name === 'makefile') return 'makefile'
  if (name === 'dockerfile') return 'dockerfile'
  const ext = name.split('.').pop()
  return ext ? EXT_TO_LANG[ext] : undefined
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

export function highlightLine(content: string, lang: string | undefined): string {
  if (!content) return '\n'
  if (!lang) return escapeHtml(content)
  try {
    return hljs.highlight(content, { language: lang, ignoreIllegals: true }).value
  } catch {
    return escapeHtml(content)
  }
}

interface DiffLine {
  type: ' ' | '+' | '-'
  content: string
  lineNo: number | null
}

function parseHunkLines(hunk: StructuredPatch): DiffLine[] {
  const result: DiffLine[] = []
  let oldLine = hunk.oldStart ?? 0
  let newLine = hunk.newStart ?? 0
  const lines = hunk.lines ?? []

  for (const line of lines) {
    const prefix = line[0] as ' ' | '+' | '-'
    const content = line.slice(1)

    switch (prefix) {
      case ' ':
        result.push({ type: ' ', content, lineNo: newLine })
        oldLine++
        newLine++
        break
      case '+':
        result.push({ type: '+', content, lineNo: newLine })
        newLine++
        break
      case '-':
        result.push({ type: '-', content, lineNo: oldLine })
        oldLine++
        break
    }
  }

  return result
}

export function DiffView({ hunks, filePath }: { hunks: StructuredPatch[]; filePath: string }) {
  const lang = useMemo(() => getLang(filePath), [filePath])

  let maxLineNo = 0
  for (const hunk of hunks) {
    let oldLine = hunk.oldStart ?? 0
    let newLine = hunk.newStart ?? 0
    const lines = hunk.lines ?? []
    for (const line of lines) {
      const prefix = line[0]
      if (prefix === ' ') { oldLine++; newLine++ }
      else if (prefix === '+') { newLine++ }
      else if (prefix === '-') { oldLine++ }
    }
    maxLineNo = Math.max(maxLineNo, oldLine - 1, newLine - 1)
  }
  const lineNoChars = String(maxLineNo).length

  return (
    <table className="diff-table">
      <colgroup>
        <col style={{ width: `${lineNoChars + 2}ch` }} />
        <col style={{ width: '2ch' }} />
        <col />
      </colgroup>
      <tbody>
        {hunks.map((hunk, hunkIdx) => {
          const lines = parseHunkLines(hunk)
          return (
            <React.Fragment key={hunkIdx}>
              {hunkIdx > 0 && (
                <tr className="diff-hunk-sep">
                  <td colSpan={3}></td>
                </tr>
              )}
              {lines.map((line, lineIdx) => {
                const cls = line.type === '+' ? 'add' : line.type === '-' ? 'del' : 'ctx'
                const html = highlightLine(line.content, lang)
                return (
                  <tr key={lineIdx} className={`diff-line diff-line--${cls}`}>
                    <td className={`diff-gutter diff-gutter--${cls}`} data-line-no={line.lineNo ?? ''} />
                    <td className={`diff-sign diff-sign--${cls}`} data-sign={line.type !== ' ' ? line.type : ''} />
                    <td className="diff-content"><pre dangerouslySetInnerHTML={{ __html: html }} /></td>
                  </tr>
                )
              })}
            </React.Fragment>
          )
        })}
      </tbody>
    </table>
  )
}
