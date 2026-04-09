import type { Message2User } from '../generated/types.generated.ts'

export const HIDDEN_TOOLS = new Set([
  'ToolSearch', 'TodoWrite', 'ExitPlanMode', 'EnterWorktree', 'ExitWorktree',
])

const INTERRUPTED_MESSAGES = new Set([
  '[Request interrupted by user]',
  '[Request interrupted by user for tool use]',
])

export function timestampMs(ts?: string): number {
  if (!ts) return Date.now()
  const d = new Date(ts)
  return isNaN(d.getTime()) ? Date.now() : d.getTime()
}

export function checkIsError(msg: Message2User): boolean {
  const content = msg.message?.content
  if (!Array.isArray(content)) return false
  for (const item of content) {
    if (item && typeof item === 'object' && (item as any).type === 'tool_result' && (item as any).isError) {
      return true
    }
  }
  return false
}

export function extractErrorText(msg: Message2User): string | null {
  const content = msg.message?.content
  if (!Array.isArray(content)) return null
  for (const item of content) {
    if (item && typeof item === 'object' && (item as any).type === 'tool_result' && (item as any).isError) {
      const c = (item as any).content
      if (typeof c === 'string') return c
      if (Array.isArray(c)) {
        return c
          .filter((ci: any) => ci?.type === 'text')
          .map((ci: any) => ci.text)
          .join('\n')
      }
    }
  }
  return null
}

export function extractUserText(msg: Message2User): string | null {
  const content = msg.message?.content
  if (!content) return null
  if (typeof content === 'string') {
    const lines = content.split('\n').filter(l => !INTERRUPTED_MESSAGES.has(l))
    const text = lines.join('\n')
    return text || null
  }
  if (Array.isArray(content)) {
    const parts = content
      .filter((item: any) => item?.type === 'text' && item?.text && !INTERRUPTED_MESSAGES.has(item.text))
      .map((item: any) => item.text as string)
    const text = parts.join('\n')
    return text || null
  }
  return null
}

export function extractPlanTitle(content: string): string {
  for (const line of content.split('\n')) {
    const trimmed = line.trim()
    if (trimmed.startsWith('# ')) return trimmed.slice(2)
  }
  return 'Plan'
}

export function extractToolUseId(msg: Message2User): string | null {
  const content = msg.message?.content
  if (!Array.isArray(content)) return null
  for (const item of content) {
    if (item && typeof item === 'object' && (item as any).type === 'tool_result') {
      return (item as any).toolUseId ?? null
    }
  }
  return null
}
