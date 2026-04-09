import { create } from 'zustand'
import { produce, enableMapSet } from 'immer'

enableMapSet()
import type { Message2, Message2Assistant, Message2User, ToolUseResultObject, System } from '../generated/types.generated.ts'
import {
  Message2Resolver,
  isMessage2Assistant, isMessage2User, isMessage2Result, isMessage2System,
  isMessage2AssistantMessageContentToolUse,
  isSystemTaskProgress, isSystemTaskNotification, isSystemTurnDuration,
} from '../generated/parsers.generated.ts'
import type { ToolResultEntry, AgentProgressEntry } from '../types/toolIndex.ts'
import { checkIsError, extractErrorText, extractToolUseId } from '../utils/messageUtils.ts'

const MAX_CACHED_CONVERSATIONS = 20

export interface ConversationState {
  messages: Message2[]
  uuidIndex: Map<string, number>
  toolResults: Map<string, ToolResultEntry>
  agentProgress: Map<string, AgentProgressEntry>
  incrementalUUIDs: Set<string>
  incrementalStartIndex: number
  scrollTop: number | null
  hasBeenOpened: boolean
  isTurnActive: boolean
  interrupted: boolean
}

const MAX_DOM_CACHE = 8

interface Store {
  conversations: Map<string, ConversationState>
  activeConversationId: string | null
  domCacheIds: string[]
}

const useStore = create<Store>(() => ({
  conversations: new Map(),
  activeConversationId: null,
  domCacheIds: [],
}))

// Module-level resolvers per conversation
const resolvers = new Map<string, Message2Resolver>()

function getOrCreateResolver(conversationId: string): Message2Resolver {
  let r = resolvers.get(conversationId)
  if (!r) {
    r = new Message2Resolver()
    resolvers.set(conversationId, r)
  }
  return r
}

export function getConversationState(conversationId: string): ConversationState | undefined {
  return useStore.getState().conversations.get(conversationId)
}

function touchKey(map: Map<string, ConversationState>, key: string): void {
  const value = map.get(key)
  if (value) {
    map.delete(key)
    map.set(key, value)
  }
}

function evictIfNeeded(map: Map<string, ConversationState>, activeId: string | null): void {
  while (map.size > MAX_CACHED_CONVERSATIONS) {
    const oldest = map.keys().next().value!
    if (oldest === activeId) break
    map.delete(oldest)
    resolvers.delete(oldest)
  }
}

function createEmptyState(): ConversationState {
  return {
    messages: [],
    uuidIndex: new Map(),
    toolResults: new Map(),
    agentProgress: new Map(),
    incrementalUUIDs: new Set(),
    incrementalStartIndex: 0,
    scrollTop: null,
    hasBeenOpened: false,
    isTurnActive: false,
    interrupted: false,
  }
}

export function switchConversation(conversationId: string): void {
  useStore.setState(produce((state: Store) => {
    if (state.conversations.has(conversationId)) {
      const conv = state.conversations.get(conversationId)!
      conv.incrementalUUIDs.clear()
      conv.incrementalStartIndex = conv.messages.length
      touchKey(state.conversations, conversationId)
    } else {
      state.conversations.set(conversationId, createEmptyState())
      evictIfNeeded(state.conversations, conversationId)
    }

    let domCacheIds = state.domCacheIds.filter((id) => id !== conversationId)
    domCacheIds.push(conversationId)
    if (domCacheIds.length > MAX_DOM_CACHE) {
      domCacheIds = domCacheIds.slice(domCacheIds.length - MAX_DOM_CACHE)
    }
    state.activeConversationId = conversationId
    state.domCacheIds = domCacheIds
  }))
}

/** Update toolResults and agentProgress indexes from a resolved message. */
function updateIndexes(
  msg: Message2,
  toolResults: Map<string, ToolResultEntry>,
  agentProgress: Map<string, AgentProgressEntry>,
): void {
  if (isMessage2User(msg)) {
    const sourceId = msg.sourceToolUseId ?? extractToolUseId(msg)
    if (sourceId) {
      const isError = checkIsError(msg)
      const result = (msg.toolUseResult && typeof msg.toolUseResult === 'object')
        ? msg.toolUseResult as ToolUseResultObject
        : undefined
      toolResults.set(sourceId, {
        result,
        isError,
        errorMessage: isError ? extractErrorText(msg) : null,
      })
    }
    return
  }

  if (isMessage2System(msg)) {
    const sys = msg as unknown as { subtype: string } & System
    if (isSystemTaskProgress(sys)) {
      const tp = sys as any
      const toolUseId = tp.toolUseId
      if (!toolUseId) return
      const existing = agentProgress.get(toolUseId) ?? { progress: [] }
      existing.progress = [...existing.progress, tp]
      agentProgress.set(toolUseId, existing)
      return
    }
    if (isSystemTaskNotification(sys)) {
      const tn = sys as any
      const toolUseId = tn.toolUseId
      if (!toolUseId) return
      const existing = agentProgress.get(toolUseId) ?? { progress: [] }
      existing.notification = tn
      agentProgress.set(toolUseId, { ...existing })
      return
    }
  }
}

/** Append a single raw message (live streaming). */
export function appendMessage(conversationId: string, rawJSON: unknown): void {
  const resolver = getOrCreateResolver(conversationId)
  const msg = resolver.resolve(rawJSON)

  useStore.setState(produce((state: Store) => {
    let conv = state.conversations.get(conversationId)
    if (!conv) {
      conv = createEmptyState()
      state.conversations.set(conversationId, conv)
      evictIfNeeded(state.conversations, state.activeConversationId)
    }

    // Update indexes (mutate in place)
    updateIndexes(msg, conv.toolResults, conv.agentProgress)

    // Update messages
    const key = isMessage2Assistant(msg) ? (msg.uuid ?? null) : null
    if (key) {
      const existingIdx = conv.uuidIndex.get(key)
      if (existingIdx !== undefined) {
        conv.messages[existingIdx] = msg   // O(1) replace
      } else {
        const newIdx = conv.messages.length
        conv.messages.push(msg)            // O(1) append
        conv.uuidIndex.set(key, newIdx)    // O(1) index
        conv.incrementalUUIDs.add(key)
      }
    } else {
      conv.messages.push(msg)              // O(1) append
    }
  }))
}

/** Set all messages (history replay). Creates fresh resolver + indexes. */
export function setAllMessages(conversationId: string, rawJSONs: unknown[]): void {
  const resolver = new Message2Resolver()
  resolvers.set(conversationId, resolver)

  const messages: Message2[] = []
  const uuidIndex = new Map<string, number>()
  const toolResults = new Map<string, ToolResultEntry>()
  const agentProgress = new Map<string, AgentProgressEntry>()

  for (const raw of rawJSONs) {
    const msg = resolver.resolve(raw)
    const key = isMessage2Assistant(msg) ? (msg.uuid ?? null) : null
    if (key) {
      uuidIndex.set(key, messages.length)
    }
    messages.push(msg)
    updateIndexes(msg, toolResults, agentProgress)
  }

  useStore.setState(produce((state: Store) => {
    const existing = state.conversations.get(conversationId)
    state.conversations.set(conversationId, {
      messages,
      uuidIndex,
      toolResults,
      agentProgress,
      incrementalUUIDs: new Set(),
      incrementalStartIndex: messages.length,
      scrollTop: existing?.scrollTop ?? null,
      hasBeenOpened: existing?.hasBeenOpened ?? false,
      isTurnActive: existing?.isTurnActive ?? false,
      interrupted: existing?.interrupted ?? false,
    })
  }))
}

export function setTurnActive(conversationId: string, isTurnActive: boolean, interrupted?: boolean): void {
  useStore.setState(produce((state: Store) => {
    const conv = state.conversations.get(conversationId)
    if (conv) {
      conv.isTurnActive = isTurnActive
      conv.interrupted = interrupted ?? false
    }
  }))
}

/** Truncate messages: remove the message at the given index and all messages after it. */
export function truncateFromIndex(conversationId: string, fromIndex: number): void {
  useStore.setState(produce((state: Store) => {
    const conv = state.conversations.get(conversationId)
    if (!conv || fromIndex < 0 || fromIndex >= conv.messages.length) return

    // Remove from fromIndex onward
    const removed = conv.messages.splice(fromIndex)

    // Clean up uuidIndex for removed messages
    for (const msg of removed) {
      const uuid = (msg as any).uuid
      if (uuid && conv.uuidIndex.has(uuid)) {
        conv.uuidIndex.delete(uuid)
      }
    }

    conv.incrementalStartIndex = Math.min(conv.incrementalStartIndex, conv.messages.length)
  }))
}

export function saveScrollTop(conversationId: string, scrollTop: number): void {
  const state = useStore.getState().conversations.get(conversationId)
  if (state) {
    state.scrollTop = scrollTop
    state.hasBeenOpened = true
  }
}

export { useStore }
