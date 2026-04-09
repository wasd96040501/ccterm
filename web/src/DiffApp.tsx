import { useCallback, useMemo } from 'react'
import { structuredPatch } from 'diff'
import { useDiffStore } from './stores/diffStore.ts'
import { postToNative } from './bridge.ts'
import { DiffView } from './components/DiffView/DiffView.tsx'
import type { StructuredPatch } from './generated/types.generated.ts'

export function DiffApp() {
  const { filePath, oldString, newString } = useDiffStore()

  const containerRef = useCallback((el: HTMLDivElement | null) => {
    if (!el) return
    const observer = new ResizeObserver(() => {
      postToNative({ type: 'contentHeight', height: el.scrollHeight })
    })
    observer.observe(el)
  }, [])

  const hunks: StructuredPatch[] = useMemo(() => {
    if (!oldString && !newString) return []
    const patch = structuredPatch('', '', oldString, newString, '', '', { context: 3 })
    return patch.hunks.map((h) => ({
      oldStart: h.oldStart,
      newStart: h.newStart,
      lines: h.lines,
    }))
  }, [oldString, newString])

  if (hunks.length === 0) return null

  return (
    <div ref={containerRef} className="diff-container">
      <DiffView hunks={hunks} filePath={filePath} />
    </div>
  )
}
