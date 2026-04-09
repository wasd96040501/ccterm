import { useCallback, useMemo } from 'react'
import hljs from 'highlight.js/lib/core'
import bash from 'highlight.js/lib/languages/bash'
import { useBashStore } from './stores/bashStore.ts'
import { postToNative } from './bridge.ts'

hljs.registerLanguage('bash', bash)

export function BashApp() {
  const command = useBashStore((s) => s.command)

  const containerRef = useCallback((el: HTMLDivElement | null) => {
    if (!el) return
    const observer = new ResizeObserver(() => {
      postToNative({ type: 'contentHeight', height: el.scrollHeight })
    })
    observer.observe(el)
  }, [])

  const commandHtml = useMemo(() => {
    if (!command) return ''
    return hljs.highlight(command, { language: 'bash', ignoreIllegals: true }).value
  }, [command])

  if (!command) return null

  return (
    <div ref={containerRef} className="bash-preview-container">
      <div className="bash-output">
        <pre className="bash-stdout hljs"><span className="bash-command-line"><span className="bash-prompt">$ </span><code dangerouslySetInnerHTML={{ __html: commandHtml }} /></span></pre>
      </div>
    </div>
  )
}
