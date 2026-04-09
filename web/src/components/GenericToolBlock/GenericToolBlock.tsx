import React, { memo } from 'react'
import { Wrench } from 'lucide-react'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'

interface GenericToolBlockProps {
  toolName: string
  description: string
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
}

export const GenericToolBlock = memo(function GenericToolBlock({
  toolName, description, isRunning, isError, errorMessage,
}: GenericToolBlockProps) {
  const label = description || toolName

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<Wrench size={12} strokeWidth={1.75} />}
        label={label}
        isRunning={isRunning}
        isError={isError}
        canExpand={false}
        expanded={false}
        onToggle={() => {}}
      />
    </div>
  )
})
