import React, { memo } from 'react'
import './TurnResultDivider.css'

interface TurnResultDividerProps {
  durationMs: number
  inputTokens: number
  outputTokens: number
}

function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000)
  if (totalSeconds < 60) return `${totalSeconds}s`
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  if (minutes < 60) return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`
  const hours = Math.floor(minutes / 60)
  const remainMinutes = minutes % 60
  return remainMinutes > 0 ? `${hours}h ${remainMinutes}m` : `${hours}h`
}

function formatTokens(count: number): string {
  if (count < 1000) return `${count}`
  return `${(count / 1000).toFixed(1)}k`
}

export const TurnResultDivider = memo(function TurnResultDivider({ durationMs, inputTokens, outputTokens }: TurnResultDividerProps) {
  const duration = formatDuration(durationMs)
  const input = formatTokens(inputTokens)
  const output = formatTokens(outputTokens)

  return (
    <div className="turn-result-divider">
      <div className="turn-result-divider__line" />
      <span className="turn-result-divider__label">
        {duration}
        <span className="turn-result-divider__sep">·</span>
        ↑{input}
        <span className="turn-result-divider__sep">·</span>
        ↓{output}
      </span>
      <div className="turn-result-divider__line" />
    </div>
  )
})
