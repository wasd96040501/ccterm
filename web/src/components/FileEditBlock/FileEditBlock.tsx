import React, { memo, useState, useEffect } from 'react'
import { Pencil } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { DiffView } from '../DiffView/DiffView.tsx'
import { displayPath } from '../../utils/displayPath.ts'
import type { ToolUseEdit, ToolUseResultObjectEdit } from '../../generated/types.generated.ts'

interface FileEditBlockProps {
  toolUse: ToolUseEdit
  result: ToolUseResultObjectEdit | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const FileEditBlock = memo(function FileEditBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: FileEditBlockProps) {
  const filePath = displayPath(result?.filePath ?? toolUse.input?.filePath ?? '', null)
  const patches = result?.structuredPatch ?? null
  const hasPatch = patches != null && patches.length > 0
  const canExpand = hasPatch || (isError && !!errorMessage)
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

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<Pencil size={12} strokeWidth={1.75} />}
        label={filePath}
        isRunning={isRunning}
        isError={result?.structuredPatch == null && !isRunning}
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
                <DiffView hunks={patches!} filePath={filePath} />
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
