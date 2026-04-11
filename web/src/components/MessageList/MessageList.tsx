import React, { useCallback, useRef, useLayoutEffect, useMemo } from 'react'
import type { Message2, Message2Assistant, ToolUse } from '../../generated/types.generated.ts'
import {
  isMessage2Assistant, isMessage2User,
  isMessage2AssistantMessageContentToolUse,
  isMessage2AssistantMessageContentText,
  isToolUseRead, isToolUseGlob, isToolUseGrep,
  isToolUseToolSearch, isToolUseTodoWrite,
  isToolUseEnterWorktree, isToolUseExitWorktree,
} from '../../generated/parsers.generated.ts'
import { extractToolUseId } from '../../utils/messageUtils.ts'
import { Message2Row } from '../Message2Row/Message2Row.tsx'
import { ToolGroupBlock } from '../ToolGroupBlock/ToolGroupBlock.tsx'
import { ProcessingIndicator } from '../ProcessingIndicator/ProcessingIndicator.tsx'
import { saveScrollTop } from '../../stores/conversationStore.ts'
import { postToNative } from '../../bridge.ts'

interface MessageListProps {
  conversationId: string
  messages: Message2[]
  incrementalUUIDs: Set<string>
  incrementalStartIndex: number
  savedScrollTop: number | null
  hasBeenOpened: boolean
  isActive: boolean
  isTurnActive: boolean
  interrupted: boolean
}

type RenderEntry =
  | { kind: 'message'; message: Message2; index: number }
  | { kind: 'toolGroup'; toolUses: ToolUse[] }

function isGroupableToolUse(toolUse: ToolUse): boolean {
  return isToolUseRead(toolUse) || isToolUseGlob(toolUse) || isToolUseGrep(toolUse)
}

function isNonRenderingToolUse(toolUse: ToolUse): boolean {
  return isToolUseToolSearch(toolUse) || isToolUseTodoWrite(toolUse) ||
    isToolUseEnterWorktree(toolUse) || isToolUseExitWorktree(toolUse)
}

/** Extract groupable ToolUse blocks from an assistant message that has ONLY groupable tools (no text). */
function extractPureGroupableTools(msg: Message2Assistant): ToolUse[] | null {
  const blocks = msg.message?.content
  if (!blocks || blocks.length === 0) return null
  const tools: ToolUse[] = []
  for (const block of blocks) {
    if (isMessage2AssistantMessageContentText(block) && block.text) return null
    if (isMessage2AssistantMessageContentToolUse(block)) {
      const toolUse = block as unknown as ToolUse
      if (isNonRenderingToolUse(toolUse)) continue
      if (!isGroupableToolUse(toolUse)) return null
      tools.push(toolUse)
    }
    // thinking blocks — skip
  }
  return tools.length > 0 ? tools : null
}

/** Is this a tool_result user message? */
function isToolResultUser(msg: Message2): boolean {
  if (!isMessage2User(msg)) return false
  return !!(msg.sourceToolUseId || extractToolUseId(msg))
}

function buildRenderEntries(messages: Message2[]): RenderEntry[] {
  const entries: RenderEntry[] = []
  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i]
    // Skip tool_result user messages (rendered inline by ToolUseRenderer)
    if (isToolResultUser(msg)) continue

    if (isMessage2Assistant(msg)) {
      const tools = extractPureGroupableTools(msg)
      if (tools) {
        const last = entries[entries.length - 1]
        if (last?.kind === 'toolGroup') {
          last.toolUses.push(...tools)
        } else {
          entries.push({ kind: 'toolGroup', toolUses: tools })
        }
        continue
      }
    }

    entries.push({ kind: 'message', message: msg, index: i })
  }
  return entries
}

function postReady(conversationId: string): void {
  postToNative({ type: 'ready', conversationId })
}

function getMessageKey(msg: Message2, idx: number): string {
  if ('uuid' in msg && msg.uuid) return msg.uuid as string
  if ('type' in msg) return `${msg.type}-${idx}`
  return `msg-${idx}`
}

export function MessageList({ conversationId, messages, incrementalUUIDs, incrementalStartIndex, savedScrollTop, hasBeenOpened, isActive, isTurnActive, interrupted }: MessageListProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const shouldFollowBottom = useRef(true)
  const conversationIdRef = useRef(conversationId)
  conversationIdRef.current = conversationId

  const renderEntries = useMemo(() => buildRenderEntries(messages), [messages])

  useLayoutEffect(() => {
    if (!isActive) return
    const el = containerRef.current
    if (!el) return

    el.style.visibility = 'hidden'

    if (hasBeenOpened && savedScrollTop != null) {
      el.scrollTop = savedScrollTop
      shouldFollowBottom.current = (el.scrollHeight - savedScrollTop - el.clientHeight) < 30
    } else {
      el.scrollTop = el.scrollHeight
      shouldFollowBottom.current = true
    }

    const initialAtBottom = shouldFollowBottom.current
    isAtBottomRef.current = initialAtBottom

    requestAnimationFrame(() => {
      el.style.visibility = ''
      requestAnimationFrame(() => {
        postReady(conversationIdRef.current)
        postToNative({ type: 'scrollStateChanged', conversationId: conversationIdRef.current, isAtBottom: initialAtBottom })
      })
    })
  }, [isActive]) // eslint-disable-line react-hooks/exhaustive-deps

  useLayoutEffect(() => {
    if (!shouldFollowBottom.current) return
    const container = containerRef.current
    if (!container) return
    container.scrollTop = container.scrollHeight
  }, [messages])

  const isAtBottomRef = useRef(true)

  const handleScroll = useCallback(() => {
    const el = containerRef.current
    if (!el) return
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight
    shouldFollowBottom.current = distanceFromBottom < 30
    saveScrollTop(conversationIdRef.current, el.scrollTop)

    const nowAtBottom = distanceFromBottom < 30
    if (nowAtBottom !== isAtBottomRef.current) {
      isAtBottomRef.current = nowAtBottom
      postToNative({ type: 'scrollStateChanged', conversationId: conversationIdRef.current, isAtBottom: nowAtBottom })
    }
  }, [])

  return (
    <div
      ref={containerRef}
      className="message-list"
      onScroll={handleScroll}
    >
      <div className="message-list-inner">
        {renderEntries.map((entry, entryIdx) => {
          if (entry.kind === 'toolGroup') {
            const firstId = (entry.toolUses[0] as { id?: string })?.id ?? `group-${entryIdx}`
            return (
              <div key={firstId} className="chat-message chat-message--assistant message-item">
                <ToolGroupBlock
                  toolUses={entry.toolUses}
                  conversationId={conversationId}
                />
              </div>
            )
          }
          const msg = entry.message
          const idx = entry.index
          const key = getMessageKey(msg, idx)
          const isIncremental = idx >= incrementalStartIndex || (
            'uuid' in msg && typeof msg.uuid === 'string' && incrementalUUIDs.has(msg.uuid)
          )
          const isMostRecent = entryIdx === renderEntries.length - 1
          return (
            <Message2Row
              key={key}
              message={msg}
              conversationId={conversationId}
              isIncremental={isIncremental}
              isMostRecent={isMostRecent}
              messageIndex={idx}
            />
          )
        })}
        <ProcessingIndicator active={isTurnActive} interrupted={interrupted} />
      </div>
    </div>
  )
}
