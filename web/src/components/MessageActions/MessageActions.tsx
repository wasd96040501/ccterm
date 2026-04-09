import React, { memo, useCallback, useState } from 'react'
import './MessageActions.css'

interface MessageActionsProps {
  timestamp?: string
  /** 'user' = right-aligned, 'assistant' = left-aligned */
  align: 'user' | 'assistant'
  /** Text content to copy. If not provided, copy button is hidden. */
  copyText?: string
  /** Show fork button (user messages only) */
  showFork?: boolean
  /** Show edit button (user messages only) */
  showEdit?: boolean
  onFork?: () => void
  onEdit?: () => void
}

function formatTime(ts?: string): string {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ''
  return new Intl.DateTimeFormat(undefined, { timeStyle: 'short' }).format(d)
}

const CopyIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
    <path d="M10.5 5.5V3.5a1.5 1.5 0 0 0-1.5-1.5H3.5A1.5 1.5 0 0 0 2 3.5V9a1.5 1.5 0 0 0 1.5 1.5h2" />
  </svg>
)

const CheckIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 8.5l3.5 3.5 6.5-7" />
  </svg>
)

const ForkIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="5" cy="3.5" r="1.5" />
    <circle cx="11" cy="3.5" r="1.5" />
    <circle cx="8" cy="12.5" r="1.5" />
    <path d="M5 5v2a3 3 0 0 0 3 3m3-5v2a3 3 0 0 1-3 3" />
  </svg>
)

const EditIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M11.5 2.5l2 2-8 8H3.5v-2z" />
    <path d="M9.5 4.5l2 2" />
  </svg>
)

export const MessageActions = memo(function MessageActions({
  timestamp,
  align,
  copyText,
  showFork,
  showEdit,
  onFork,
  onEdit,
}: MessageActionsProps) {
  const [copied, setCopied] = useState(false)
  const time = formatTime(timestamp)

  const handleCopy = useCallback(() => {
    if (!copyText) return
    navigator.clipboard.writeText(copyText).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    })
  }, [copyText])

  return (
    <div className={`message-actions message-actions--${align}`}>
      {time && <span className="message-actions__time">{time}</span>}
      <div className="message-actions__buttons">
        {copyText && (
          <button
            className="message-actions__btn"
            onClick={handleCopy}
            disabled={copied}
            title={copied ? 'Copied' : 'Copy'}
          >
            {copied ? <CheckIcon /> : <CopyIcon />}
          </button>
        )}
        {showFork && (
          <button
            className="message-actions__btn"
            onClick={onFork}
            title="Fork"
          >
            <ForkIcon />
          </button>
        )}
        {showEdit && (
          <button
            className="message-actions__btn"
            onClick={onEdit}
            title="Edit"
          >
            <EditIcon />
          </button>
        )}
      </div>
    </div>
  )
})
