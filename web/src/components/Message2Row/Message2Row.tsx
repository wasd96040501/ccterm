import React, { memo, useState, useCallback, useRef, useEffect } from 'react'
import type { Message2 } from '../../generated/types.generated.ts'
import type { Message2User } from '../../generated/types.generated.ts'
import {
  isMessage2Assistant, isMessage2User, isMessage2Result, isMessage2System,
  isResultSuccess, isResultErrorDuringExecution,
  isSystemTurnDuration,
} from '../../generated/parsers.generated.ts'
import { extractUserText, extractPlanTitle, timestampMs } from '../../utils/messageUtils.ts'
import { AssistantRow } from '../AssistantRow/AssistantRow.tsx'
import { PlanBlock } from '../PlanBlock/PlanBlock.tsx'
import { TurnResultDivider } from '../TurnResultDivider/TurnResultDivider.tsx'
import { MessageActions } from '../MessageActions/MessageActions.tsx'
import { postToNative } from '../../bridge.ts'
import { truncateFromIndex } from '../../stores/conversationStore.ts'

interface Message2RowProps {
  message: Message2
  conversationId: string
  isIncremental: boolean
  /** True for the most recent user/assistant turn — always show actions */
  isMostRecent?: boolean
  /** Index in the messages array, used for truncation on edit */
  messageIndex: number
}

export const Message2Row = memo(function Message2Row({
  message, conversationId, isIncremental, isMostRecent, messageIndex,
}: Message2RowProps) {
  if (isMessage2Assistant(message)) {
    return (
      <AssistantRow
        message={message}
        conversationId={conversationId}
        isIncremental={isIncremental}
        isMostRecent={isMostRecent}
      />
    )
  }

  if (isMessage2User(message)) {
    // tool_result messages — skip (rendered via ToolUseRenderer)
    if (message.sourceToolUseId || hasToolResult(message)) {
      return null
    }

    const fadeClass = isIncremental ? ' message-fade-in' : ''

    // plan
    if (message.planContent) {
      return (
        <div className={`chat-message chat-message--assistant message-item${fadeClass}`}>
          <PlanBlock
            title={extractPlanTitle(message.planContent)}
            content={message.planContent}
          />
        </div>
      )
    }

    // plain user text
    const text = extractUserText(message)
    if (text) {
      return <UserBubble message={message} text={text} fadeClass={fadeClass} isMostRecent={isMostRecent} conversationId={conversationId} messageIndex={messageIndex} />
    }
    return null
  }

  if (isMessage2Result(message)) {
    const result = message as any
    let durationMs = 0
    let inputTokens = 0
    let outputTokens = 0
    if (isResultSuccess(result) || isResultErrorDuringExecution(result)) {
      durationMs = result.durationMs ?? 0
      inputTokens = result.usage?.inputTokens ?? 0
      outputTokens = result.usage?.outputTokens ?? 0
    }
    return (
      <TurnResultDivider
        durationMs={durationMs}
        inputTokens={inputTokens}
        outputTokens={outputTokens}
      />
    )
  }

  if (isMessage2System(message)) {
    const sys = message as any
    if (isSystemTurnDuration(sys)) {
      return (
        <TurnResultDivider
          durationMs={sys.durationMs ?? 0}
          inputTokens={0}
          outputTokens={0}
        />
      )
    }
    return null
  }

  return null
})

// --- UserBubble: extracted so we can use hooks (useState for editing) ---

interface UserBubbleProps {
  message: Message2User
  text: string
  fadeClass: string
  isMostRecent?: boolean
  conversationId: string
  messageIndex: number
}

const UserBubble = memo(function UserBubble({ message, text, fadeClass, isMostRecent, conversationId, messageIndex }: UserBubbleProps) {
  const [isEditing, setIsEditing] = useState(false)
  const [editText, setEditText] = useState(text)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  const userTs = message.timestamp ?? (message.message as any)?.timestamp
  const messageUuid = (message as any).uuid ?? ''

  const handleEdit = useCallback(() => {
    setEditText(text)
    setIsEditing(true)
  }, [text])

  const handleCancel = useCallback(() => {
    setIsEditing(false)
  }, [])

  const handleSend = useCallback(() => {
    const trimmed = editText.trim()
    if (!trimmed || trimmed === text) {
      setIsEditing(false)
      return
    }
    // Truncate: remove this message and everything after it from the store
    truncateFromIndex(conversationId, messageIndex)
    // Send edited text as new message
    postToNative({ type: 'editMessage', messageUuid, newText: trimmed })
    setIsEditing(false)
  }, [editText, text, messageUuid, conversationId, messageIndex])

  const handleFork = useCallback(() => {
    postToNative({ type: 'forkMessage', messageUuid })
  }, [messageUuid])

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      handleCancel()
    } else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      handleSend()
    }
  }, [handleCancel, handleSend])

  // Auto-resize textarea and focus
  useEffect(() => {
    if (isEditing && textareaRef.current) {
      const el = textareaRef.current
      el.focus()
      el.style.height = 'auto'
      el.style.height = el.scrollHeight + 'px'
      // Move cursor to end
      el.setSelectionRange(el.value.length, el.value.length)
    }
  }, [isEditing])

  if (isEditing) {
    return (
      <div className={`chat-message chat-message--user message-item${fadeClass}`}>
        <div className="user-edit-container">
          <textarea
            ref={textareaRef}
            className="user-edit-textarea"
            value={editText}
            onChange={e => {
              setEditText(e.target.value)
              e.target.style.height = 'auto'
              e.target.style.height = e.target.scrollHeight + 'px'
            }}
            onKeyDown={handleKeyDown}
            rows={2}
          />
          <div className="user-edit-buttons">
            <button className="user-edit-btn user-edit-btn--cancel" onClick={handleCancel}>Cancel</button>
            <button className="user-edit-btn user-edit-btn--send" onClick={handleSend}>Send</button>
          </div>
        </div>
      </div>
    )
  }

  const alwaysShowClass = isMostRecent ? ' message-actions--always-show' : ''

  return (
    <div className={`chat-message chat-message--user message-item${fadeClass} message-actions-wrapper${alwaysShowClass}`}>
      <div className="chat-bubble chat-bubble--user">{text}</div>
      <MessageActions
        timestamp={userTs}
        align="user"
        copyText={text}
        showFork
        showEdit
        onEdit={handleEdit}
        onFork={handleFork}
      />
    </div>
  )
})

function hasToolResult(msg: any): boolean {
  const content = msg.message?.content
  if (!Array.isArray(content)) return false
  return content.some((item: any) => item?.type === 'tool_result')
}
