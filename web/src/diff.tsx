import { createRoot } from 'react-dom/client'
import { DiffApp } from './DiffApp.tsx'
import { onNativeEvent, postToNative } from './bridge.ts'
import { useDiffStore } from './stores/diffStore.ts'
import './styles/diff.css'

const root = createRoot(document.getElementById('root')!)
root.render(<DiffApp />)

onNativeEvent((event) => {
  if (event.type === 'setDiff') {
    const { filePath, oldString, newString } = event.payload
    useDiffStore.getState().setDiff(filePath, oldString, newString)
  }
})

postToNative({ type: 'ready' })
