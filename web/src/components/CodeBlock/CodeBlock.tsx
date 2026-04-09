import React, { memo, useCallback, useRef, useState } from 'react'
import './CodeBlock.css'

const CopyIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
    <path d="M10.5 5.5V3.5a1.5 1.5 0 0 0-1.5-1.5H3.5A1.5 1.5 0 0 0 2 3.5V9a1.5 1.5 0 0 0 1.5 1.5h2" />
  </svg>
)

const CheckIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 8.5l3.5 3.5 6.5-7" />
  </svg>
)

/** Extract the language name from the <code> child's className (e.g. "hljs language-python" → "python") */
function extractLanguage(children: React.ReactNode): string | null {
  const child = React.Children.toArray(children)[0]
  if (!React.isValidElement(child) || child.type !== 'code') return null
  const className: string = (child.props as { className?: string }).className ?? ''
  const match = className.match(/language-(\S+)/)
  return match ? match[1] : null
}

/** Extract the plain text content from a <code> element tree */
function extractTextContent(node: React.ReactNode): string {
  if (typeof node === 'string') return node
  if (typeof node === 'number') return String(node)
  if (!node) return ''
  if (Array.isArray(node)) return node.map(extractTextContent).join('')
  if (React.isValidElement(node)) {
    return extractTextContent((node.props as { children?: React.ReactNode }).children)
  }
  return ''
}

interface CodeBlockProps {
  children?: React.ReactNode
  [key: string]: unknown
}

export const CodeBlock = memo(function CodeBlock({ children, ...props }: CodeBlockProps) {
  const [copied, setCopied] = useState(false)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const language = extractLanguage(children)

  const handleCopy = useCallback(() => {
    const text = extractTextContent(children)
    if (!text) return
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true)
      if (timerRef.current) clearTimeout(timerRef.current)
      timerRef.current = setTimeout(() => setCopied(false), 1500)
    })
  }, [children])

  return (
    <div className="code-block-wrapper">
      <div className="code-block-header">
        {language && <span className="code-block-lang">{language}</span>}
        <button
          className="code-block-copy-btn"
          onClick={handleCopy}
          disabled={copied}
          title={copied ? 'Copied' : 'Copy'}
        >
          {copied ? <CheckIcon /> : <CopyIcon />}
        </button>
      </div>
      <pre {...props}>{children}</pre>
    </div>
  )
})
