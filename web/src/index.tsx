import { createRoot } from 'react-dom/client'
import { App } from './App.tsx'
import { onNativeEvent } from './bridge.ts'
import { switchConversation, appendMessage, setAllMessages, setTurnActive } from './stores/conversationStore.ts'
import { handleSearch } from './utils/searchHighlight.ts'
import './styles/github-markdown-auto.css'
import './styles/hljs-auto.css'
import './styles/markdown-overrides.css'
import './styles/index.css'

// Mount React
const root = createRoot(document.getElementById('root')!)
root.render(<App />)

// Bridge event dispatcher
onNativeEvent((event) => {
  switch (event.type) {
    case 'switchConversation':
      switchConversation(event.payload.conversationId)
      break
    case 'setTurnActive':
      setTurnActive(event.payload.conversationId, event.payload.isTurnActive, event.payload.interrupted)
      break
    case 'search':
      handleSearch(event.payload.query, event.payload.direction)
      break
    case 'forwardRawMessage':
      appendMessage(event.payload.conversationId, event.payload.message)
      break
    case 'setRawMessages':
      setAllMessages(event.payload.conversationId, event.payload.messages)
      break
    case 'setBottomPadding': {
      const el = document.querySelector<HTMLElement>('.chat-container.active .message-list')
      if (el) {
        const wasAtBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 30
        el.style.paddingBottom = event.payload.height + 'px'
        if (wasAtBottom) {
          requestAnimationFrame(() => { el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }) })
        }
      }
      break
    }
    case 'scrollToBottom': {
      const el = document.querySelector<HTMLElement>('.chat-container.active .message-list')
      if (el) {
        el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
      }
      break
    }
  }
})
