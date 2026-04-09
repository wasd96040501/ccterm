import React, { memo } from 'react'
import type { ToolUse, ToolUseResultObjectBash, ToolUseResultObjectEdit, ToolUseResultObjectWrite, ToolUseResultObjectGlob, ToolUseResultObjectGrep, ToolUseResultObjectWebFetch, ToolUseResultObjectWebSearch, ToolUseResultObjectTask, ToolUseResultObjectSkill, ToolUseResultObjectAskUserQuestion } from '../../generated/types.generated.ts'
import {
  isToolUseBash, isToolUseEdit, isToolUseWrite, isToolUseRead,
  isToolUseGlob, isToolUseGrep, isToolUseAgent, isToolUseTask,
  isToolUseWebFetch, isToolUseWebSearch, isToolUseSkill,
  isToolUseAskUserQuestion, isToolUseExitPlanMode,
  isToolUseToolSearch, isToolUseTodoWrite,
  isToolUseEnterWorktree, isToolUseExitWorktree,
} from '../../generated/parsers.generated.ts'
import { useStore } from '../../stores/conversationStore.ts'
import { BashBlock } from '../BashBlock/BashBlock.tsx'
import { FileEditBlock } from '../FileEditBlock/FileEditBlock.tsx'
import { FileWriteBlock } from '../FileWriteBlock/FileWriteBlock.tsx'
import { FileReadBlock } from '../FileReadBlock/FileReadBlock.tsx'
import { GrepBlock } from '../GrepBlock/GrepBlock.tsx'
import { GlobBlock } from '../GlobBlock/GlobBlock.tsx'
import { AgentBlock } from '../AgentBlock/AgentBlock.tsx'
import { WebFetchBlock } from '../WebFetchBlock/WebFetchBlock.tsx'
import { WebSearchBlock } from '../WebSearchBlock/WebSearchBlock.tsx'
import { GenericToolBlock } from '../GenericToolBlock/GenericToolBlock.tsx'
import { AskUserQuestionBlock } from '../AskUserQuestionBlock/AskUserQuestionBlock.tsx'
import { ExitPlanModeBlock } from '../ExitPlanModeBlock/ExitPlanModeBlock.tsx'

function toolUseId(toolUse: ToolUse): string {
  return (toolUse as { id?: string }).id ?? ''
}

interface ToolUseRendererProps {
  toolUse: ToolUse
  conversationId: string
  isIncremental: boolean
}

export const ToolUseRenderer = memo(function ToolUseRenderer({
  toolUse, conversationId, isIncremental,
}: ToolUseRendererProps) {
  const id = toolUseId(toolUse)
  const entry = useStore((s) =>
    s.conversations.get(conversationId)?.toolResults.get(id)
  )
  const agentEntry = useStore((s) =>
    s.conversations.get(conversationId)?.agentProgress.get(id)
  )
  const isTurnActive = useStore((s) =>
    s.conversations.get(conversationId)?.isTurnActive ?? false
  )
  const isRunning = entry === undefined && isTurnActive
  const isError = entry?.isError ?? false
  const errorMessage = entry?.errorMessage ?? null

  if (isToolUseBash(toolUse)) {
    const result = entry?.result as ToolUseResultObjectBash | undefined
    return <BashBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} isIncremental={isIncremental} />
  }
  if (isToolUseEdit(toolUse)) {
    const result = entry?.result as ToolUseResultObjectEdit | undefined
    return <FileEditBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseWrite(toolUse)) {
    const result = entry?.result as ToolUseResultObjectWrite | undefined
    return <FileWriteBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseRead(toolUse)) {
    return <FileReadBlock toolUse={toolUse} result={entry?.result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseGlob(toolUse)) {
    const result = entry?.result as ToolUseResultObjectGlob | undefined
    return <GlobBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseGrep(toolUse)) {
    const result = entry?.result as ToolUseResultObjectGrep | undefined
    return <GrepBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseAgent(toolUse) || isToolUseTask(toolUse)) {
    const result = entry?.result as ToolUseResultObjectTask | undefined
    return <AgentBlock toolUse={toolUse} result={result} agentEntry={agentEntry} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseWebFetch(toolUse)) {
    const result = entry?.result as ToolUseResultObjectWebFetch | undefined
    return <WebFetchBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseWebSearch(toolUse)) {
    const result = entry?.result as ToolUseResultObjectWebSearch | undefined
    return <WebSearchBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} isIncremental={isIncremental} />
  }
  if (isToolUseSkill(toolUse)) {
    const result = entry?.result as ToolUseResultObjectSkill | undefined
    const name = toolUse.input?.skill ?? 'unknown'
    return <GenericToolBlock toolName="Skill" description={`Skill(${name})`} isRunning={isRunning} isError={isError} errorMessage={errorMessage} />
  }
  if (isToolUseAskUserQuestion(toolUse)) {
    const result = entry?.result as ToolUseResultObjectAskUserQuestion | undefined
    return <AskUserQuestionBlock toolUse={toolUse} result={result} isRunning={isRunning} isError={isError} errorMessage={errorMessage} />
  }
  if (isToolUseExitPlanMode(toolUse)) {
    return <ExitPlanModeBlock isRunning={isRunning} isError={isError} errorMessage={errorMessage} />
  }

  // Tools that should not render
  if (isToolUseToolSearch(toolUse) || isToolUseTodoWrite(toolUse) ||
      isToolUseEnterWorktree(toolUse) || isToolUseExitWorktree(toolUse)) {
    return null
  }

  // Default: generic
  return <GenericToolBlock toolName={toolUse.name} description={toolUse.name} isRunning={isRunning} isError={isError} errorMessage={errorMessage} />
})
