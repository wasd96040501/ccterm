import React, { memo } from 'react'
import { useStore } from './stores/conversationStore.ts'
import { MessageList } from './components/MessageList/MessageList.tsx'

interface ConversationContainerProps {
  conversationId: string
  isActive: boolean
}

const ConversationContainer = memo(function ConversationContainer({
  conversationId, isActive,
}: ConversationContainerProps) {
  const state = useStore((s) => s.conversations.get(conversationId))
  if (!state) return null

  return (
    <div
      className={`chat-container${isActive ? ' active' : ''}`}
      style={{ display: isActive ? '' : 'none' }}
    >
      <MessageList
        conversationId={conversationId}
        messages={state.messages}
        incrementalUUIDs={state.incrementalUUIDs}
        incrementalStartIndex={state.incrementalStartIndex}
        savedScrollTop={state.scrollTop}
        hasBeenOpened={state.hasBeenOpened}
        isActive={isActive}
        isTurnActive={state.isTurnActive}
        interrupted={state.interrupted}
      />
    </div>
  )
})

export function App() {
  const activeId = useStore((s) => s.activeConversationId)
  const domCacheIds = useStore((s) => s.domCacheIds)

  if (!activeId) {
    return <div className="empty-state">No conversation selected</div>
  }

  return (
    <>
      {domCacheIds.map((id) => (
        <ConversationContainer
          key={id}
          conversationId={id}
          isActive={id === activeId}
        />
      ))}
    </>
  )
}
