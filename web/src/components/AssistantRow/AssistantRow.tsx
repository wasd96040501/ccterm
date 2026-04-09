import React, { memo, useMemo } from 'react'
import type { Message2Assistant, Message2AssistantMessageContent, ToolUse } from '../../generated/types.generated.ts'
import {
  isMessage2AssistantMessageContentText,
  isMessage2AssistantMessageContentToolUse,
  isToolUseRead, isToolUseGlob, isToolUseGrep,
} from '../../generated/parsers.generated.ts'
import { HIDDEN_TOOLS } from '../../utils/messageUtils.ts'
import { MarkdownRenderer } from '../MarkdownRenderer/MarkdownRenderer.tsx'
import { ToolUseRenderer } from '../ToolUseRenderer/ToolUseRenderer.tsx'
import { ToolGroupBlock } from '../ToolGroupBlock/ToolGroupBlock.tsx'
import { MessageActions } from '../MessageActions/MessageActions.tsx'

function toolUseId(toolUse: ToolUse): string {
  return (toolUse as { id?: string }).id ?? ''
}

interface AssistantRowProps {
  message: Message2Assistant
  conversationId: string
  isIncremental: boolean
  isMostRecent?: boolean
}

type RenderItem =
  | { kind: 'text'; content: string }
  | { kind: 'toolUse'; toolUse: ToolUse }
  | { kind: 'toolGroup'; toolUses: ToolUse[] }

function isGroupable(toolUse: ToolUse): boolean {
  return isToolUseRead(toolUse) || isToolUseGlob(toolUse) || isToolUseGrep(toolUse)
}

function isHidden(toolUse: ToolUse): boolean {
  return HIDDEN_TOOLS.has(toolUse.name)
}

function buildRenderItems(blocks: Message2AssistantMessageContent[]): RenderItem[] {
  const items: RenderItem[] = []
  const textParts: string[] = []
  let groupableTools: ToolUse[] = []

  function flushText() {
    if (textParts.length > 0) {
      items.push({ kind: 'text', content: textParts.join('\n\n') })
      textParts.length = 0
    }
  }

  function flushGroup() {
    if (groupableTools.length > 0) {
      items.push({ kind: 'toolGroup', toolUses: groupableTools })
      groupableTools = []
    }
  }

  for (const block of blocks) {
    if (isMessage2AssistantMessageContentText(block) && block.text) {
      flushGroup()
      textParts.push(block.text)
      continue
    }
    if (isMessage2AssistantMessageContentToolUse(block)) {
      const toolUse = block as unknown as ToolUse
      if (isHidden(toolUse)) continue
      flushText()

      if (isGroupable(toolUse)) {
        groupableTools.push(toolUse)
      } else {
        flushGroup()
        items.push({ kind: 'toolUse', toolUse })
      }
      continue
    }
    // other block types (thinking, etc.) — skip
  }

  flushText()
  flushGroup()
  return items
}

export const AssistantRow = memo(function AssistantRow({
  message, conversationId, isIncremental, isMostRecent,
}: AssistantRowProps) {
  const blocks = message.message?.content ?? []
  const items = useMemo(() => buildRenderItems(blocks), [blocks])

  if (items.length === 0) return null

  const fadeClass = isIncremental ? ' message-fade-in' : ''

  // Extract all text content for copy button
  const fullText = useMemo(() => {
    return items
      .filter((item): item is { kind: 'text'; content: string } => item.kind === 'text')
      .map(item => item.content)
      .join('\n\n')
  }, [items])

  const alwaysShowClass = isMostRecent ? ' message-actions--always-show' : ''

  return (
    <div className={`message-actions-wrapper${alwaysShowClass}`}>
      {items.map((item, idx) => {
        switch (item.kind) {
          case 'text':
            if (!item.content) return null
            return (
              <div key={`text-${idx}`} className={`chat-message chat-message--assistant message-item${fadeClass}`}>
                <MarkdownRenderer content={item.content} />
              </div>
            )
          case 'toolUse':
            return (
              <div key={toolUseId(item.toolUse) || idx} className={`chat-message chat-message--assistant message-item${fadeClass}`}>
                <ToolUseRenderer
                  toolUse={item.toolUse}
                  conversationId={conversationId}
                  isIncremental={isIncremental}
                />
              </div>
            )
          case 'toolGroup':
            return (
              <div key={`group-${item.toolUses[0] ? toolUseId(item.toolUses[0]) : idx}`} className={`chat-message chat-message--assistant message-item${fadeClass}`}>
                <ToolGroupBlock
                  toolUses={item.toolUses}
                  conversationId={conversationId}
                />
              </div>
            )
        }
      })}
      <MessageActions
        timestamp={message.timestamp ?? (message.message as any)?.timestamp}
        align="assistant"
        copyText={fullText || undefined}
      />
    </div>
  )
})
