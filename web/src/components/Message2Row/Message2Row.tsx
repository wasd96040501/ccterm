import React, { memo } from 'react'
import type { Message2 } from '../../generated/types.generated.ts'
import {
  isMessage2Assistant, isMessage2User, isMessage2Result, isMessage2System,
  isResultSuccess, isResultErrorDuringExecution,
  isSystemTurnDuration,
} from '../../generated/parsers.generated.ts'
import { extractUserText, extractPlanTitle, timestampMs } from '../../utils/messageUtils.ts'
import { AssistantRow } from '../AssistantRow/AssistantRow.tsx'
import { PlanBlock } from '../PlanBlock/PlanBlock.tsx'
import { TurnResultDivider } from '../TurnResultDivider/TurnResultDivider.tsx'

interface Message2RowProps {
  message: Message2
  conversationId: string
  isIncremental: boolean
}

export const Message2Row = memo(function Message2Row({
  message, conversationId, isIncremental,
}: Message2RowProps) {
  if (isMessage2Assistant(message)) {
    return (
      <AssistantRow
        message={message}
        conversationId={conversationId}
        isIncremental={isIncremental}
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
      return (
        <div className={`chat-message chat-message--user message-item${fadeClass}`}>
          <div className="chat-bubble chat-bubble--user">{text}</div>
        </div>
      )
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
    // taskProgress, taskNotification — handled via store indexes, not rendered directly
    return null
  }

  return null
})

function hasToolResult(msg: any): boolean {
  const content = msg.message?.content
  if (!Array.isArray(content)) return false
  return content.some((item: any) => item?.type === 'tool_result')
}
