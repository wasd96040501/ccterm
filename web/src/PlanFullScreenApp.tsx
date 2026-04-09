import { useRef, useEffect, useState, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { MessageSquareQuote } from 'lucide-react'
import { usePlanFullScreenStore, type PlanCommentDTO } from './stores/planFullScreenStore.ts'
import { MarkdownRenderer } from './components/MarkdownRenderer/MarkdownRenderer.tsx'
import { PlanCommentPopover } from './components/PlanCommentPopover/PlanCommentPopover.tsx'
import { PlanGlobalComments } from './components/PlanGlobalComments/PlanGlobalComments.tsx'
import { postToNative } from './bridge.ts'
import {
  computeTextOffsets,
  getTextOffsetAtPoint,
  findCommentAtOffset,
  applyCommentHighlights,
  offsetsToRange,
} from './utils/planHighlight.ts'

export function PlanFullScreenApp() {
  const plan = usePlanFullScreenStore((s) => s.plans[s.currentKey])
  const markdown = plan?.markdown ?? ''
  const comments = plan?.comments ?? []
  const containerRef = useRef<HTMLDivElement>(null)
  const [popover, setPopover] = useState<{
    comment: PlanCommentDTO
    rect: DOMRect
  } | null>(null)
  const [commentBtn, setCommentBtn] = useState<{
    x: number
    y: number
    startOffset: number
    endOffset: number
    selectedText: string
  } | null>(null)

  const inlineComments = comments.filter((c) => c.isInline)
  const globalComments = comments.filter((c) => !c.isInline)

  // Apply comment highlights when comments change
  useEffect(() => {
    if (!containerRef.current) return
    applyCommentHighlights(containerRef.current, comments)
  }, [comments, markdown])

  // Show floating Quote button on mouseup with active selection
  useEffect(() => {
    const onMouseUp = () => {
      // Defer to let the selection finalize
      requestAnimationFrame(() => {
        const sel = window.getSelection()
        if (!sel || sel.isCollapsed || !containerRef.current?.contains(sel.anchorNode)) {
          setCommentBtn(null)
          return
        }
        const range = sel.getRangeAt(0)
        const { startOffset, endOffset } = computeTextOffsets(containerRef.current!, range)
        if (startOffset < 0 || endOffset < 0) return
        const rect = range.getBoundingClientRect()
        setCommentBtn({
          x: rect.left + rect.width / 2,
          y: rect.top,
          startOffset,
          endOffset,
          selectedText: sel.toString(),
        })
      })
    }
    const onMouseDown = () => {
      setCommentBtn(null)
    }
    const container = containerRef.current
    if (!container) return
    container.addEventListener('mouseup', onMouseUp)
    container.addEventListener('mousedown', onMouseDown)
    return () => {
      container.removeEventListener('mouseup', onMouseUp)
      container.removeEventListener('mousedown', onMouseDown)
    }
  }, [])

  // Hover effect for inline comments
  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    let currentHoverId: string | null = null
    let rafId: number | null = null

    const onMouseMove = (e: MouseEvent) => {
      if (rafId) return
      rafId = requestAnimationFrame(() => {
        rafId = null
        const offset = getTextOffsetAtPoint(container, e.clientX, e.clientY)
        const hit = findCommentAtOffset(offset, inlineComments)

        if (hit && hit.id !== currentHoverId) {
          const range = offsetsToRange(container, hit.startOffset!, hit.endOffset!)
          if (range) {
            CSS.highlights.set('plan-comment-hover', new Highlight(range))
          }
          container.style.cursor = 'pointer'
          currentHoverId = hit.id
        } else if (!hit && currentHoverId) {
          CSS.highlights.delete('plan-comment-hover')
          container.style.cursor = ''
          currentHoverId = null
        }
      })
    }

    container.addEventListener('mousemove', onMouseMove)
    return () => {
      container.removeEventListener('mousemove', onMouseMove)
      if (rafId) cancelAnimationFrame(rafId)
      CSS.highlights.delete('plan-comment-hover')
    }
  }, [inlineComments])

  // Click on highlighted comment to show popover
  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      setCommentBtn(null)
      if (!containerRef.current) return
      const offset = getTextOffsetAtPoint(containerRef.current, e.clientX, e.clientY)
      const hit = findCommentAtOffset(offset, inlineComments)
      if (hit) {
        const range = offsetsToRange(containerRef.current, hit.startOffset!, hit.endOffset!)
        if (range) {
          setPopover({ comment: hit, rect: range.getBoundingClientRect() })
        }
      } else {
        setPopover(null)
      }
    },
    [inlineComments]
  )

  // Handle Comment button click
  const handleCommentBtnClick = useCallback(() => {
    if (!commentBtn) return
    postToNative({
      type: 'textSelected',
      startOffset: commentBtn.startOffset,
      endOffset: commentBtn.endOffset,
      selectedText: commentBtn.selectedText,
    } as any)
    window.getSelection()?.removeAllRanges()
    setCommentBtn(null)
  }, [commentBtn])

  return (
    <div className="plan-fullscreen-container">
      <div
        ref={containerRef}
        className="plan-fullscreen-content markdown-body"
        onClick={handleClick}
      >
        <MarkdownRenderer content={markdown} />
      </div>

      <PlanGlobalComments comments={globalComments} />

      <div className="plan-scroll-spacer" />

      <AnimatePresence>
        {commentBtn && (
          <motion.button
            className="plan-comment-btn-float"
            style={{
              left: commentBtn.x,
              top: commentBtn.y,
            }}
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.15, ease: 'easeOut' }}
            whileTap={{ color: 'var(--tap-color)', transition: { duration: 0.05 } }}
            onMouseDown={(e) => e.preventDefault()}
            onClick={handleCommentBtnClick}
          >
            <MessageSquareQuote size={14} strokeWidth={1.75} />
            <span>Quote</span>
          </motion.button>
        )}
      </AnimatePresence>

      {popover && (
        <PlanCommentPopover
          comment={popover.comment}
          rect={popover.rect}
          onClose={() => setPopover(null)}
        />
      )}
    </div>
  )
}
