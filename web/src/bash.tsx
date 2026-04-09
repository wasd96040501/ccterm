import { createRoot } from 'react-dom/client'
import { BashApp } from './BashApp.tsx'
import { onNativeEvent, postToNative } from './bridge.ts'
import { useBashStore } from './stores/bashStore.ts'
import './styles/bash.css'

const root = createRoot(document.getElementById('root')!)
root.render(<BashApp />)

onNativeEvent((event) => {
  if (event.type === 'setCommand') {
    const { command } = event.payload
    useBashStore.getState().setCommand(command)
  }
})

postToNative({ type: 'ready' })
