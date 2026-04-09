import React from 'react'
import { ChevronRight, CircleAlert } from 'lucide-react'

interface ToolBlockHeaderProps {
  icon: React.ReactNode
  label: string
  isRunning: boolean
  isError: boolean
  canExpand: boolean
  expanded: boolean
  onToggle: () => void
}

export function ToolBlockHeader({
  icon,
  label,
  isRunning,
  isError,
  canExpand,
  expanded,
  onToggle,
}: ToolBlockHeaderProps) {
  return (
    <div
      className={`file-edit-header${canExpand ? ' file-edit-header--expandable' : ''}`}
      onClick={onToggle}
    >
      <span className="file-edit-icon">{icon}</span>

      <span className="file-edit-path" title={label}>
        {label}
      </span>

      {isError && <CircleAlert size={14} strokeWidth={1.75} className="file-edit-error-icon" />}

      {canExpand && (
        <div className={`file-edit-chevron${expanded ? ' file-edit-chevron--expanded' : ''}`}>
          <ChevronRight size={14} strokeWidth={2} />
        </div>
      )}

      {isRunning && <span className="file-edit-spinner"><span /><span /><span /></span>}
    </div>
  )
}
