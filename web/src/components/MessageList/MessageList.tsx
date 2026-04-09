import React, { useCallback, useRef, useLayoutEffect } from 'react'
import type { Message2 } from '../../generated/types.generated.ts'
import { Message2Row } from '../Message2Row/Message2Row.tsx'
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
        {messages.map((msg, idx) => {
          const key = getMessageKey(msg, idx)
          const isIncremental = idx >= incrementalStartIndex || (
            'uuid' in msg && typeof msg.uuid === 'string' && incrementalUUIDs.has(msg.uuid)
          )
          return (
            <Message2Row
              key={key}
              message={msg}
              conversationId={conversationId}
              isIncremental={isIncremental}
            />
          )
        })}
        <ProcessingIndicator active={isTurnActive} interrupted={interrupted} />
      </div>
    </div>
  )
}
