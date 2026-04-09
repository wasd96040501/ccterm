import React, { memo, useState } from 'react'
import { FolderSearch } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { displayPath } from '../../utils/displayPath.ts'
import type { ToolUseGlob, ToolUseResultObjectGlob } from '../../generated/types.generated.ts'

interface GlobBlockProps {
  toolUse: ToolUseGlob
  result: ToolUseResultObjectGlob | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const GlobBlock = memo(function GlobBlock({
  toolUse, result, isRunning, isError, errorMessage, isIncremental,
}: GlobBlockProps) {
  const pattern = toolUse.input?.pattern ?? ''
  const filenames = result?.filenames?.map(f => displayPath(f, null)) ?? null
  const truncated = result?.truncated ?? false
  const hasFiles = filenames != null && filenames.length > 0
  const canExpand = hasFiles || (isError && !!errorMessage)

  const [expanded, setExpanded] = useState(false)

  const handleToggle = () => {
    if (canExpand) setExpanded((prev) => !prev)
  }

  const fileCount = filenames?.length ?? 0
  const label = fileCount > 0
    ? `${pattern} (${fileCount} files${truncated ? ', truncated' : ''})`
    : pattern

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<FolderSearch size={12} strokeWidth={1.75} />}
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
                <div className="file-list">
                  {filenames!.map((f, i) => (
                    <div key={i} className="file-list-item">{f}</div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
