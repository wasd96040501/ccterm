import React, { memo, useState, useMemo } from 'react'
import { Terminal } from 'lucide-react'
import hljs from 'highlight.js/lib/common'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { parseAnsiToSpans, ansiStyleToCss } from '../../utils/ansiParser.ts'
import type { ToolUseBash, ToolUseResultObjectBash } from '../../generated/types.generated.ts'

function renderAnsi(text: string): React.ReactNode[] {
  const spans = parseAnsiToSpans(text)
  return spans.map((span, i) => {
    const css = ansiStyleToCss(span.style)
    return css ? <span key={i} style={css}>{span.text}</span> : <React.Fragment key={i}>{span.text}</React.Fragment>
  })
}

interface BashBlockProps {
  toolUse: ToolUseBash
  result: ToolUseResultObjectBash | undefined
  isRunning: boolean
  isError: boolean
  isIncremental: boolean
}

export const BashBlock = memo(function BashBlock({
  toolUse, result, isRunning, isError, isIncremental,
}: BashBlockProps) {
  const command = toolUse.input?.command ?? ''

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    setExpanded((prev) => !prev)
  }

  const truncatedCommand = command.length > 80
    ? command.slice(0, 80) + '...'
    : command

  const stdout = result?.stdout ?? null
  const stderr = result?.stderr ?? null

  const mergedOutput = useMemo(() => {
    return [stdout, stderr].filter(Boolean).join('\n')
  }, [stdout, stderr])

  const commandHtml = useMemo(() => {
    try {
      return hljs.highlight(command, { language: 'bash', ignoreIllegals: true }).value
    } catch {
      return command
    }
  }, [command])

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<Terminal size={12} strokeWidth={1.75} />}
        label={truncatedCommand}
        isRunning={isRunning}
        isError={isError}
        canExpand={true}
        expanded={expanded}
        onToggle={handleToggle}
      />

      <CollapsibleMotion open={expanded}>
        <div className="file-edit-clip">
          <div className="file-edit-body">
            <div className="bash-output">
              <pre className="bash-stdout"><span className="bash-command-line"><span className="bash-prompt">$ </span><code dangerouslySetInnerHTML={{ __html: commandHtml }} /></span>{mergedOutput && '\n'}{mergedOutput && renderAnsi(mergedOutput)}</pre>
            </div>
          </div>
        </div>
      </CollapsibleMotion>
    </div>
  )
})
