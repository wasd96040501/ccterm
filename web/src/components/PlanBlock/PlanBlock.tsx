import React, { memo, useState } from 'react'
import { FileText, ChevronRight } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { MarkdownRenderer } from '../MarkdownRenderer/MarkdownRenderer.tsx'

interface PlanBlockProps {
  title: string
  content: string
}

export const PlanBlock = memo(function PlanBlock({ title, content }: PlanBlockProps) {
  const [expanded, setExpanded] = useState(false)

  return (
    <div className={`plan-block${expanded ? ' plan-block--expanded' : ''}`}>
      <div
        className="plan-header"
        onClick={() => setExpanded((prev) => !prev)}
      >
        <div className="plan-header-top">
          <FileText size={14} strokeWidth={1.75} className="plan-header-icon" />
          <span className="plan-header-label">Plan</span>
          <div className={`plan-header-chevron${expanded ? ' plan-header-chevron--expanded' : ''}`}>
            <ChevronRight size={14} strokeWidth={2} />
          </div>
        </div>
        <div className="plan-header-title" title={title}>
          {title}
        </div>
      </div>

      <CollapsibleMotion open={expanded}>
        <div className="plan-body">
          <MarkdownRenderer content={content} />
        </div>
      </CollapsibleMotion>
    </div>
  )
})
