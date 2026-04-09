import React, { memo, useState } from 'react'
import { FileText } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { displayPath } from '../../utils/displayPath.ts'
import type { ToolUseRead, ToolUseResultObject } from '../../generated/types.generated.ts'

interface FileReadBlockProps {
  toolUse: ToolUseRead
  result: ToolUseResultObject | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const FileReadBlock = memo(function FileReadBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: FileReadBlockProps) {
  const filePath = displayPath(toolUse.input?.filePath ?? '', null)
  const canExpand = isError && !!errorMessage

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<FileText size={12} strokeWidth={1.75} />}
        label={filePath}
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
              <div className="file-edit-error-content">{errorMessage}</div>
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
