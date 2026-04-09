import React, { memo, useState } from 'react'
import { Search } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { displayPath } from '../../utils/displayPath.ts'
import type { ToolUseGrep, ToolUseResultObjectGrep } from '../../generated/types.generated.ts'

interface GrepBlockProps {
  toolUse: ToolUseGrep
  result: ToolUseResultObjectGrep | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const GrepBlock = memo(function GrepBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: GrepBlockProps) {
  const pattern = toolUse.input?.pattern ?? ''
  const filenames = result?.filenames?.map(f => displayPath(f, null)) ?? null
  const numMatches = result?.numMatches ?? null
  const content = result?.content ?? null
  const hasResults = (filenames != null && filenames.length > 0) || !!content
  const canExpand = hasResults || (isError && !!errorMessage)

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  const fileCount = filenames?.length ?? 0
  const parts: string[] = []
  if (fileCount > 0) parts.push(`${fileCount} files`)
  if (numMatches != null) parts.push(`${numMatches} matches`)
  const label = parts.length > 0
    ? `${pattern} (${parts.join(', ')})`
    : pattern

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<Search size={12} strokeWidth={1.75} />}
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
              ) : (
                <>
                  {filenames && filenames.length > 0 && (
                    <div className="file-list">
                      {filenames.map((f, i) => (
                        <div key={i} className="file-list-item">{f}</div>
                      ))}
                    </div>
                  )}
                  {content && (
                    <div className="bash-output">
                      <pre className="bash-stdout">{content}</pre>
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
