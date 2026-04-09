import React, { memo, useState } from 'react'
import { FileSearch } from 'lucide-react'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { ToolUseRenderer } from '../ToolUseRenderer/ToolUseRenderer.tsx'
import { useStore } from '../../stores/conversationStore.ts'
import type { ToolUse } from '../../generated/types.generated.ts'
import { isToolUseRead } from '../../generated/parsers.generated.ts'

function toolUseId(toolUse: ToolUse): string {
  return (toolUse as { id?: string }).id ?? ''
}

interface ToolGroupBlockProps {
  toolUses: ToolUse[]
  conversationId: string
}

function buildGroupLabel(toolUses: ToolUse[], conversationId: string, conversations: any): string {
  let readCount = 0
  let searchCount = 0

  for (const t of toolUses) {
    if (isToolUseRead(t)) {
      readCount++
    } else {
      searchCount++
    }
  }

  const parts: string[] = []

  if (readCount > 0) {
    const noun = readCount === 1 ? '1 file' : `${readCount} files`
    parts.push(`Read ${noun}`)
  }

  if (searchCount > 0) {
    const noun = searchCount === 1 ? '1 file' : `${searchCount} files`
    parts.push(`Search ${noun}`)
  }

  return parts.join(', ')
}

export const ToolGroupBlock = memo(function ToolGroupBlock({
  toolUses, conversationId,
}: ToolGroupBlockProps) {
  const conversations = useStore((s) => s.conversations)
  const convState = conversations.get(conversationId)

  // Check running/error status by looking up store indexes
  const isRunning = toolUses.some((t) => {
    return !convState?.toolResults.has(toolUseId(t))
  })
  const isError = toolUses.some((t) => {
    return convState?.toolResults.get(toolUseId(t))?.isError ?? false
  })

  const [expanded, setExpanded] = useState(false)
  const handleToggle = () => setExpanded((prev) => !prev)

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<FileSearch size={12} strokeWidth={1.75} />}
        label={buildGroupLabel(toolUses, conversationId, conversations)}
        isRunning={isRunning}
        isError={isError}
        canExpand={true}
        expanded={expanded}
        onToggle={handleToggle}
      />

      <CollapsibleMotion open={expanded} keepMounted={false}>
        <div className="tool-group-body">
          {toolUses.map((tu) => (
            <div key={toolUseId(tu)} className="l2-item">
              <ToolUseRenderer
                toolUse={tu}
                conversationId={conversationId}
                isIncremental={false}
              />
            </div>
          ))}
        </div>
      </CollapsibleMotion>
    </div>
  )
})
