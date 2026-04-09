import React, { memo, useState } from 'react'
import { FileText } from 'lucide-react'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'

interface ExitPlanModeBlockProps {
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
}

export const ExitPlanModeBlock = memo(function ExitPlanModeBlock({
  isRunning, isError, errorMessage,
}: ExitPlanModeBlockProps) {
  const [expanded, setExpanded] = useState(false)

  // Accept (non-error) → don't render
  if (!isError && !isRunning) return null

  const canExpand = isError && !!errorMessage
  const handleToggle = () => { if (canExpand) setExpanded((prev) => !prev) }

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<FileText size={12} strokeWidth={1.75} />}
        label="Plan"
        isRunning={isRunning}
        isError={isError}
        canExpand={canExpand}
        expanded={expanded}
        onToggle={handleToggle}
      />
      {canExpand && (
        <CollapsibleMotion open={expanded} keepMounted={false}>
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
