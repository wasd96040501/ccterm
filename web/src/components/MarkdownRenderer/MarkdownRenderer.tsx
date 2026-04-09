import React, { memo } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'
import rehypeHighlight from 'rehype-highlight'
import rehypeKatex from 'rehype-katex'
import 'katex/dist/katex.min.css'
import { CodeBlock } from '../CodeBlock/CodeBlock'

interface MarkdownRendererProps {
  content: string
}

const remarkPlugins = [remarkGfm, remarkMath]
const rehypePlugins = [rehypeHighlight, rehypeKatex]

const markdownComponents = {
  table: ({ children, ...props }: React.ComponentPropsWithoutRef<'table'>) => (
    <div className="table-wrapper">
      <table {...props}>{children}</table>
    </div>
  ),
  pre: ({ children, ...props }: React.ComponentPropsWithoutRef<'pre'>) => (
    <CodeBlock {...props}>{children}</CodeBlock>
  ),
}

export const MarkdownRenderer = memo(function MarkdownRenderer({ content }: MarkdownRendererProps) {
  return (
    <div className="markdown-body">
      <ReactMarkdown
        remarkPlugins={remarkPlugins}
        rehypePlugins={rehypePlugins}
        components={markdownComponents}
      >
        {content}
      </ReactMarkdown>
    </div>
  )
})
