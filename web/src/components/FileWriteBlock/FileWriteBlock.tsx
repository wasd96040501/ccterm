import React, { memo, useState, useEffect, useMemo } from 'react'
import { FilePlus } from 'lucide-react'
import hljs from 'highlight.js/lib/common'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { DiffView, getLang } from '../DiffView/DiffView.tsx'
import { displayPath } from '../../utils/displayPath.ts'
import type { ToolUseWrite, ToolUseResultObjectWrite } from '../../generated/types.generated.ts'

interface FileWriteBlockProps {
  toolUse: ToolUseWrite
  result: ToolUseResultObjectWrite | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const FileWriteBlock = memo(function FileWriteBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: FileWriteBlockProps) {
  const filePath = displayPath(result?.filePath ?? toolUse.input?.filePath ?? '', null)
  const patches = result?.structuredPatch ?? null
  const content = result?.content ?? null
  const isNewFile = result?.originalFile == null
  const hasDiff = patches != null && patches.length > 0
  const canExpand = hasDiff || !!content || (isError && !!errorMessage)
  const shouldAutoExpand = isIncremental && !filePath.includes('/.claude/plans/')

  const [expanded, setExpanded] = useState(canExpand && shouldAutoExpand)

  useEffect(() => {
    if (canExpand && shouldAutoExpand) {
      setExpanded(true)
    }
  }, [canExpand, shouldAutoExpand])

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  const label = isNewFile && !isRunning ? `${filePath} (new file)` : filePath

  const highlightedHtml = useMemo(() => {
    if (hasDiff || !content) return ''
    const lang = getLang(filePath)
    if (lang) {
      try {
        return hljs.highlight(content, { language: lang, ignoreIllegals: true }).value
      } catch { /* fallback */ }
    }
    return hljs.highlightAuto(content).value
  }, [content, filePath, hasDiff])

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<FilePlus size={12} strokeWidth={1.75} />}
        label={label}
        isRunning={isRunning}
        isError={isError}
        canExpand={canExpand}
        expanded={expanded}
        onToggle={handleToggle}
      />

      {canExpand && (
        <CollapsibleMotion open={expanded}>
          <div className="file-edit-clip">
            <div className="file-edit-body">
              {isError && errorMessage ? (
                <div className="file-edit-error-content">{errorMessage}</div>
              ) : hasDiff ? (
                <DiffView hunks={patches!} filePath={filePath} />
              ) : (
                <div className="read-content">
                  <pre><code dangerouslySetInnerHTML={{ __html: highlightedHtml }} /></pre>
                </div>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
