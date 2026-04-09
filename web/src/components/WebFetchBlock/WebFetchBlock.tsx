import React, { memo, useState } from 'react'
import { Globe } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import type { ToolUseWebFetch, ToolUseResultObjectWebFetch } from '../../generated/types.generated.ts'

interface WebFetchBlockProps {
  toolUse: ToolUseWebFetch
  result: ToolUseResultObjectWebFetch | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const WebFetchBlock = memo(function WebFetchBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: WebFetchBlockProps) {
  const url = result?.url ?? toolUse.input?.url ?? ''
  const statusCode = result?.code ?? null
  const statusText = result?.codeText ?? null
  const fetchResult = result?.result ?? null
  const hasResult = !!fetchResult
  const canExpand = hasResult || (isError && !!errorMessage)

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  const label = statusCode != null
    ? `${url} (${statusCode} ${statusText ?? ''})`
    : url

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<Globe size={12} strokeWidth={1.75} />}
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
                <div className="bash-output">
                  <pre className="bash-stdout">{fetchResult}</pre>
                </div>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
