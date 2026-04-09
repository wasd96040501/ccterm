import type { ToolUseResultObject, TaskProgress, TaskNotification } from '../generated/types.generated.ts'

export interface ToolResultEntry {
  result: ToolUseResultObject
  isError: boolean
  errorMessage: string | null
}

export interface AgentProgressEntry {
  progress: TaskProgress[]
  notification?: TaskNotification
}
