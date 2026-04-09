import React, { memo, useState } from 'react'
import { MessageCircleQuestion } from 'lucide-react'
import { ToolBlockHeader } from '../ToolBlockHeader/ToolBlockHeader.tsx'
import { CollapsibleMotion } from '../CollapsibleMotion/CollapsibleMotion.tsx'
import type { ToolUseAskUserQuestion, ToolUseResultObjectAskUserQuestion } from '../../generated/types.generated.ts'

interface AskUserQuestionBlockProps {
  toolUse: ToolUseAskUserQuestion
  result: ToolUseResultObjectAskUserQuestion | undefined
  isRunning: boolean
  isError: boolean
  errorMessage: string | null
}

export const AskUserQuestionBlock = memo(function AskUserQuestionBlock({
  toolUse, result, isRunning, isError, errorMessage,
}: AskUserQuestionBlockProps) {
  const [expanded, setExpanded] = useState(false)

  const questions = toolUse.input?.questions ?? []
  const firstQuestion = questions[0]?.question ?? 'Question'
  const answers = result?.answers

  const hasBody = (!!answers && questions.length > 0) || (isError && !!errorMessage)
  const handleToggle = () => { if (hasBody) setExpanded((prev) => !prev) }

  return (
    <div className="file-edit-block">
      <ToolBlockHeader
        icon={<MessageCircleQuestion size={12} strokeWidth={1.75} />}
        label={firstQuestion}
        isRunning={isRunning}
        isError={isError}
        canExpand={hasBody}
        expanded={expanded}
        onToggle={handleToggle}
      />
      {hasBody && (
        <CollapsibleMotion open={expanded} keepMounted={false}>
          <div className="file-edit-clip">
            <div className="file-edit-body">
              {isError && errorMessage ? (
                <div className="file-edit-error-content">{errorMessage}</div>
              ) : (
                <div className="ask-qa-list">
                  {questions.map((q, i) => {
                    const answer = answers?.[String(i)] ?? answers?.[q.question ?? '']
                    return (
                      <div key={i} className="ask-qa-item">
                        <div className="ask-qa-question">{q.question}</div>
                        {answer && <div className="ask-qa-answer">{answer}</div>}
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          </div>
        </CollapsibleMotion>
      )}
    </div>
  )
})
