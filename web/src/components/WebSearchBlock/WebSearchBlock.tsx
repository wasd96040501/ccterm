import React, { memo, useState } from 'react'
import { SearchCode } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import type { ToolUseWebSearch, ToolUseResultObjectWebSearch } from '../../generated/types.generated.ts'

interface WebSearchBlockProps {
  toolUse: ToolUseWebSearch
  result: ToolUseResultObjectWebSearch | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const WebSearchBlock = memo(function WebSearchBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: WebSearchBlockProps) {
  const query = result?.query ?? toolUse.input?.query ?? ''
  const results = result?.results ? JSON.stringify(result.results) : null
  const canExpand = !!results || (isError && !!errorMessage)

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<SearchCode size={12} strokeWidth={1.75} />}
        label={query}
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
                <div className="bash-output">
                  <pre className="bash-stdout">{results}</pre>
                </div>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
