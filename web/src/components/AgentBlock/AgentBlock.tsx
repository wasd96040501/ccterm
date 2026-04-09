import React, { memo, useState } from 'react'
import { Bot, ChevronRight } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import type { ToolUse, ToolUseResultObjectTask } from '../../generated/types.generated.ts'
import type { AgentProgressEntry } from '../../types/toolIndex.ts'

interface AgentBlockProps {
  toolUse: ToolUse
  result: ToolUseResultObjectTask | undefined
  agentEntry: AgentProgressEntry | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
  isIncremental: boolean
}

export const AgentBlock = memo(function AgentBlock({
  toolUse, result, agentEntry, isRunning, isError, errorMessage, isIncremental,
}: AgentBlockProps) {
  const [expanded, setExpanded] = useState(false)

  const description = result?.description ?? (toolUse as any).input?.description ?? 'Agent'
  const progressEntries = agentEntry?.progress ?? []
  const notification = agentEntry?.notification

  // Derive status from notification or result
  const status = notification?.status ?? result?.status ?? null
  const effectiveIsRunning = isRunning && !notification
  const effectiveIsError = notification
    ? notification.status !== 'completed'
    : isError
  const effectiveErrorMessage = effectiveIsError
    ? (notification?.summary ?? errorMessage)
    : null

  const latestEntry = progressEntries.length > 0 ? progressEntries[progressEntries.length - 1] : null

  const toolUses = notification?.usage?.toolUses
    ?? (agentEntry && progressEntries.length > 0 ? progressEntries[progressEntries.length - 1]?.usage?.toolUses : null)
    ?? result?.totalToolUseCount
    ?? null

  const canExpand = progressEntries.length > 0 || (effectiveIsError && !!effectiveErrorMessage)

  const toolCallsSuffix = toolUses ? `${toolUses} tool calls` : null
  const subtitle = latestEntry
    ? `${latestEntry.description ?? ''}${toolCallsSuffix ? `  ·  ${toolCallsSuffix}` : ''}`
    : toolCallsSuffix

  return (
    <div className={`agent-block${expanded ? ' agent-block--expanded' : ''}`}>
      <div
        className="agent-header"
        onClick={() => canExpand && setExpanded((prev) => !prev)}
      >
        <div className="agent-header-top">
          <Bot size={14} strokeWidth={1.75} className="agent-header-icon" />
          <span className="agent-header-label">Agent</span>
          {effectiveIsRunning && (
            <span className="file-edit-spinner">
              <span />
              <span />
              <span />
            </span>
          )}
          {canExpand && (
            <div className={`agent-header-chevron${expanded ? ' agent-header-chevron--expanded' : ''}`}>
              <ChevronRight size={14} strokeWidth={2} />
            </div>
          )}
        </div>
        <div className="agent-header-title">{description}</div>
        {subtitle && (
          <div className="agent-header-subtitle">{subtitle}</div>
        )}
      </div>

      {canExpand && (
        <CollapsibleMotion open={expanded}>
          <div className="agent-body">
            {effectiveIsError && effectiveErrorMessage ? (
              <div className="agent-error">{effectiveErrorMessage}</div>
            ) : (
              <div className="agent-progress-list">
                {progressEntries.map((entry, i) => (
                  <div key={i} className="agent-progress-item">
                    {entry.lastToolName && (
                      <span className="agent-progress-tool">
                        {entry.lastToolName}
                      </span>
                    )}
                    <span className="agent-progress-desc">
                      {entry.description ?? ''}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
