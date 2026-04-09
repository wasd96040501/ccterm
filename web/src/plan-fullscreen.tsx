import { createRoot } from 'react-dom/client'
import { PlanFullScreenApp } from './PlanFullScreenApp.tsx'
import { onNativeEvent, postToNative } from './bridge.ts'
import { usePlanFullScreenStore } from './stores/planFullScreenStore.ts'
import { handlePlanSearch } from './utils/planHighlight.ts'
import './styles/github-markdown-auto.css'
import './styles/hljs-auto.css'
import './styles/markdown-overrides.css'
import './styles/plan-fullscreen.css'

const root = createRoot(document.getElementById('root')!)
root.render(<PlanFullScreenApp />)

onNativeEvent((event) => {
  const store = usePlanFullScreenStore.getState()
  switch (event.type) {
    case 'setPlan':
      store.setPlan(event.payload.key, event.payload.markdown)
      break
    case 'setComments':
      store.setComments(event.payload.key, event.payload.comments)
      break
    case 'switchPlan':
      store.switchPlan(event.payload.key)
      break
    case 'clearPlan':
      store.clearPlan(event.payload.key)
      break
    case 'search': {
      const container = document.querySelector<HTMLElement>('.plan-fullscreen-content')
      if (container) {
        const result = handlePlanSearch(container, event.payload.query, event.payload.direction)
        postToNative({ type: 'searchResult', total: result.total, current: result.current } as any)
      }
      break
    }
    case 'setBottomPadding': {
      const spacer = document.querySelector<HTMLElement>('.plan-scroll-spacer')
      if (spacer) {
        const container = document.querySelector<HTMLElement>('.plan-fullscreen-container')
        const wasAtBottom = container
          ? container.scrollHeight - container.scrollTop - container.clientHeight < 30
          : false
        spacer.style.height = event.payload.height + 'px'
        if (wasAtBottom && container) {
          requestAnimationFrame(() => {
            container.scrollTo({ top: container.scrollHeight, behavior: 'smooth' })
          })
        }
      }
      break
    }
    case 'clearSelection':
      window.getSelection()?.removeAllRanges()
      break
  }
})

postToNative({ type: 'ready' } as any)
