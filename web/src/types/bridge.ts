import type { PlanCommentDTO } from '../stores/planFullScreenStore.ts'

export type NativeEvent =
  | { type: 'switchConversation'; payload: { conversationId: string } }
  | { type: 'setTurnActive'; payload: { conversationId: string; isTurnActive: boolean; interrupted?: boolean } }
  | { type: 'search'; payload: { query: string; direction: 'reset' | 'next' | 'prev' } }
  | { type: 'setPlan'; payload: { key: string; markdown: string } }
  | { type: 'setComments'; payload: { key: string; comments: PlanCommentDTO[] } }
  | { type: 'switchPlan'; payload: { key: string } }
  | { type: 'clearPlan'; payload: { key: string } }
  | { type: 'clearSelection'; payload: Record<string, never> }
  | { type: 'setDiff'; payload: { filePath: string; oldString: string; newString: string } }
  | { type: 'setBottomPadding'; payload: { height: number } }
  | { type: 'setCommand'; payload: { command: string } }
  | { type: 'forwardRawMessage'; payload: { conversationId: string; message: unknown } }
  | { type: 'setRawMessages'; payload: { conversationId: string; messages: unknown[] } }
  | { type: 'scrollToBottom' }

export type WebEvent =
  | { type: 'ready'; conversationId?: string }
  | { type: 'searchResult'; total: number; current: number }
  | { type: 'contentHeight'; height: number }
  | { type: 'scrollStateChanged'; conversationId: string; isAtBottom: boolean }
  | { type: 'textSelected'; startOffset: number; endOffset: number; selectedText: string }
  | { type: 'selectionCleared' }
  | { type: 'commentAction'; action: 'edit' | 'delete'; commentId: string; text?: string }
  | { type: 'editMessage'; messageUuid: string; newText: string }
  | { type: 'forkMessage'; messageUuid: string }
