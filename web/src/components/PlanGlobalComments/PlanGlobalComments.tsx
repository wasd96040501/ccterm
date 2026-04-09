import { useState } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import { postToNative } from '../../bridge.ts'
import type { PlanCommentDTO } from '../../stores/planFullScreenStore.ts'

interface PlanGlobalCommentsProps {
  comments: PlanCommentDTO[]
}

export function PlanGlobalComments({ comments }: PlanGlobalCommentsProps) {
  if (comments.length === 0) return null

  return (
    <div className="plan-global-comments">
      <div className="global-comments-header">Review Comments</div>
      {comments.map((comment) => (
        <GlobalCommentItem key={comment.id} comment={comment} />
      ))}
    </div>
  )
}

function GlobalCommentItem({ comment }: { comment: PlanCommentDTO }) {
  const [isEditing, setIsEditing] = useState(false)
  const [editText, setEditText] = useState(comment.text)

  const handleSave = () => {
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
    postToNative({
      type: 'commentAction',
      action: 'delete',
      commentId: comment.id,
    } as any)
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSave()
    }
    if (e.key === 'Escape') {
      setIsEditing(false)
      setEditText(comment.text)
    }
  }

  return (
    <div className="global-comment-item">
      {isEditing ? (
        <textarea
          className="global-comment-edit"
          value={editText}
          onChange={(e) => setEditText(e.target.value)}
          onKeyDown={handleKeyDown}
          onBlur={handleSave}
          autoFocus
          rows={2}
        />
      ) : (
        <div className="global-comment-text">{comment.text}</div>
      )}
      <div className="global-comment-actions">
        <button
          className="global-comment-btn"
          onClick={() => setIsEditing(true)}
        >
          <Pencil size={14} strokeWidth={1.75} />
        </button>
        <button
          className="global-comment-btn delete"
          onClick={handleDelete}
        >
          <Trash2 size={14} strokeWidth={1.75} />
        </button>
      </div>
    </div>
  )
}
