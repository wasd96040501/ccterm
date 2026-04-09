import { useState, useRef, useEffect } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import { postToNative } from '../../bridge.ts'
import { usePlanFullScreenStore } from '../../stores/planFullScreenStore.ts'

interface PlanCommentPopoverProps {
  comment: { id: string; text: string; selectedText?: string }
  rect: DOMRect
  onClose: () => void
}

export function PlanCommentPopover({ comment, rect, onClose }: PlanCommentPopoverProps) {
  const [isEditing, setIsEditing] = useState(false)
  const [editText, setEditText] = useState(comment.text)
  const popoverRef = useRef<HTMLDivElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const removeComment = usePlanFullScreenStore((s) => s.removeComment)

  useEffect(() => {
    if (isEditing && textareaRef.current) {
      textareaRef.current.focus()
      textareaRef.current.select()
    }
  }, [isEditing])

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target as Node)) {
        onClose()
      }
    }
    // Delay to avoid immediate close from the click that opened the popover
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 50)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [onClose])

  const handleSaveEdit = () => {
    const trimmed = editText.trim()
    if (trimmed && trimmed !== comment.text) {
      postToNative({
        type: 'commentAction',
        action: 'edit',
        commentId: comment.id,
        text: trimmed,
      } as any)
    }
    setIsEditing(false)
  }

  const handleDelete = () => {
    // 1. Immediately remove from local store → useEffect rebuilds highlights
    removeComment(comment.id)
    // 2. Notify Swift to persist the deletion
    postToNative({
      type: 'commentAction',
      action: 'delete',
      commentId: comment.id,
    } as any)
    // 3. Close popover
    onClose()
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSaveEdit()
    }
    if (e.key === 'Escape') {
      setIsEditing(false)
      setEditText(comment.text)
    }
  }

  // Position below the highlighted text
  const top = rect.bottom + 8
  const left = Math.max(8, Math.min(rect.left, window.innerWidth - 462))

  return (
    <div
      ref={popoverRef}
      className="plan-comment-popover"
      style={{ top, left }}
    >
      {comment.selectedText && (
        <div className="popover-quote">
          {comment.selectedText.length > 80
            ? comment.selectedText.slice(0, 80) + '…'
            : comment.selectedText}
        </div>
      )}
      {isEditing ? (
        <textarea
          ref={textareaRef}
          className="popover-edit-textarea"
          value={editText}
          onChange={(e) => setEditText(e.target.value)}
          onKeyDown={handleKeyDown}
          onBlur={handleSaveEdit}
          rows={3}
        />
      ) : (
        <div className="popover-text">{comment.text}</div>
      )}
      <div className="popover-actions">
        <button
          className="popover-action-btn"
          onClick={() => setIsEditing(true)}
        >
          <Pencil size={14} strokeWidth={1.75} />
        </button>
        <button
          className="popover-action-btn delete"
          onClick={handleDelete}
        >
          <Trash2 size={14} strokeWidth={1.75} />
        </button>
      </div>
    </div>
  )
}
