// Auto-generated — do not edit

import type { Message2, Message2CustomTitle, Message2FileHistorySnapshot, Message2LastPrompt, Message2Progress, Message2PromptSuggestion, Message2QueueOperation, Message2RateLimitEvent, Message2Result, Message2System, Message2WorktreeState, Message2Unknown, Message2Assistant, ForkedFrom, Message2AssistantMessage, Message2AssistantMessageContent, Message2AssistantMessageContentText, Message2AssistantMessageContentThinking, Message2AssistantMessageContentToolUse, Message2AssistantMessageContentUnknown, Text, Thinking, ToolUse, ToolUseAgent, ToolUseUnknown, Agent, Caller, AgentInput, ToolUseAskUserQuestion, AskUserQuestionInput, InputQuestions, Options, ToolUseBash, ToolUseBashInput, ToolUseCronCreate, CronCreateInput, ToolUseEdit, EditInput, ToolUseEnterPlanMode, ToolUseEnterWorktree, EnterWorktreeInput, ToolUseExitPlanMode, ExitPlanModeInput, AllowedPrompts, ToolUseExitWorktree, ExitWorktreeInput, ToolUseGlob, GlobInput, ToolUseGrep, ToolUseGrepInput, ToolUseRead, ToolUseReadInput, Limit, ToolUseReadInputOffset, ToolUseSendMessage, SendMessageInput, InputMessage, MessageObject, ToolUseSkill, SkillInput, ToolUseTask, TaskInput, ToolUseTaskCreate, TaskCreateInput, ToolUseTaskOutput, TaskOutputInput, ToolUseTaskStop, TaskStopInput, ToolUseTaskUpdate, TaskUpdateInput, ToolUseTeamCreate, TeamCreateInput, ToolUseTodoWrite, TodoWriteInput, Todos, TodosItem, ToolUseToolSearch, ToolSearchInput, ToolUseWebFetch, ToolUseWebFetchInput, ToolUseWebSearch, ToolUseWebSearchInput, ToolUseWrite, WriteInput, ContextManagement, MessageUsage, CacheCreation, MessageUsageServerToolUse, AssistantUsage, CustomTitle, FileHistorySnapshot, Snapshot, TrackedFileBackupsValue, LastPrompt, Progress, Data, DataAgentProgress, DataBashProgress, DataHookProgress, DataQueryUpdate, DataSearchResultsReceived, DataWaitingForTask, DataUnknown, AgentProgress, AgentProgressMessage, AgentProgressMessageAssistant, AgentProgressMessageUser, AgentProgressMessageUnknown, MessageAssistant, MessageAssistantMessage, MessageAssistantMessageContent, MessageAssistantMessageContentBash, MessageAssistantMessageContentEdit, MessageAssistantMessageContentGlob, MessageAssistantMessageContentGrep, MessageAssistantMessageContentRead, MessageAssistantMessageContentToolSearch, MessageAssistantMessageContentWebFetch, MessageAssistantMessageContentWebSearch, MessageAssistantMessageContentWrite, MessageAssistantMessageContentUnknown, ContentBash, ContentBashInput, ContentEdit, ContentGlob, ContentGrep, ContentGrepInput, ContentRead, ContentReadInput, ContentReadInputOffset, ContentToolSearch, ContentWebFetch, ContentWebFetchInput, ContentWebSearch, ContentWebSearchInput, ContentWrite, MessageUser, MessageUserMessage, MessageUserMessageContent, MessageUserMessageContentText, MessageUserMessageContentToolResult, MessageUserMessageContentUnknown, ContentToolResult, ContentToolResultContent, ContentToolResultContentItem, BashProgress, HookProgress, QueryUpdate, SearchResultsReceived, WaitingForTask, PromptSuggestion, QueueOperation, QueueOperationDequeue, QueueOperationEnqueue, QueueOperationRemove, QueueOperationUnknown, Dequeue, Enqueue, RateLimitEvent, RateLimitInfo, Result, ResultErrorDuringExecution, ResultSuccess, ResultUnknown, ErrorDuringExecution, ModelUsageValue, ErrorDuringExecutionPermissionDenials, ErrorDuringExecutionPermissionDenialsToolInput, ErrorDuringExecutionUsage, Success, SuccessPermissionDenials, SuccessPermissionDenialsToolInput, System, SystemApiError, SystemCompactBoundary, SystemInformational, SystemInit, SystemLocalCommand, SystemMicrocompactBoundary, SystemStatus, SystemTaskNotification, SystemTaskProgress, SystemTaskStarted, SystemTurnDuration, SystemUnknown, ApiError, Cause, ApiErrorError, ErrorHeaders, CompactBoundary, CompactMetadata, Informational, Init, McpServers, Plugins, LocalCommand, MicrocompactBoundary, MicrocompactMetadata, Status, TaskNotification, TaskNotificationUsage, TaskProgress, TaskStarted, TurnDuration, Message2User, Message2UserMessage, Message2UserMessageContent, MessageContentItem, MessageContentItemImage, MessageContentItemText, MessageContentItemToolResult, MessageContentItemUnknown, Image, Source, ItemToolResult, ItemToolResultContent, ItemToolResultContentItem, ItemToolResultContentItemImage, ItemToolResultContentItemText, ItemToolResultContentItemToolReference, ItemToolResultContentItemUnknown, ToolReference, Origin, ToolUseResult, ToolUseResultObject, ToolUseResultObjectAskUserQuestion, ToolUseResultObjectBash, ToolUseResultObjectCronCreate, ToolUseResultObjectEdit, ToolUseResultObjectEnterPlanMode, ToolUseResultObjectEnterWorktree, ToolUseResultObjectExitPlanMode, ToolUseResultObjectExitWorktree, ToolUseResultObjectGlob, ToolUseResultObjectGrep, ToolUseResultObjectSendMessage, ToolUseResultObjectSkill, ToolUseResultObjectTask, ToolUseResultObjectTaskCreate, ToolUseResultObjectTaskOutput, ToolUseResultObjectTaskStop, ToolUseResultObjectTaskUpdate, ToolUseResultObjectTeamCreate, ToolUseResultObjectTodoWrite, ToolUseResultObjectToolSearch, ToolUseResultObjectWebFetch, ToolUseResultObjectWebSearch, ToolUseResultObjectWrite, ToolUseResultObjectUnknown, ObjectAskUserQuestion, AnnotationsValue, AskUserQuestionQuestions, ObjectBash, ObjectCronCreate, ObjectEdit, StructuredPatch, ObjectEnterPlanMode, ObjectEnterWorktree, ObjectExitPlanMode, ObjectExitWorktree, ObjectGlob, ObjectGrep, ObjectSendMessage, Routing, ObjectSkill, ObjectTask, TaskContent, TaskUsage, TaskUsageServerToolUse, ObjectTaskCreate, TaskCreateTask, ObjectTaskOutput, TaskOutputTask, ObjectTaskStop, ObjectTaskUpdate, StatusChange, ObjectTeamCreate, ObjectTodoWrite, NewTodos, ObjectToolSearch, ObjectWebFetch, ObjectWebSearch, Results, ResultsObject, ObjectContent, ObjectWrite, WorktreeState, WorktreeSession } from './types.generated';

// Scaffold helpers
const asStr = (v: unknown): string | undefined => typeof v === 'string' ? v : undefined;
const asNum = (v: unknown): number | undefined => typeof v === 'number' ? v : undefined;
const asBool = (v: unknown): boolean | undefined => typeof v === 'boolean' ? v : undefined;
const asObj = (v: unknown): Record<string, unknown> | undefined =>
  typeof v === 'object' && v !== null && !Array.isArray(v) ? v as Record<string, unknown> : undefined;
const asArr = (v: unknown): unknown[] | undefined => Array.isArray(v) ? v : undefined;
const pick = (o: Record<string, unknown>, ...keys: string[]): unknown => {
  for (const k of keys) { if (k in o) return o[k]; }
  return undefined;
};

export function parseMessage2(json: unknown): Message2 {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as Message2Unknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'assistant': return parseMessage2Assistant(o);
    case 'custom-title': return { type: 'custom-title', ...parseCustomTitle(o) } as Message2CustomTitle;
    case 'file-history-snapshot': return { type: 'file-history-snapshot', ...parseFileHistorySnapshot(o) } as Message2FileHistorySnapshot;
    case 'last-prompt': return { type: 'last-prompt', ...parseLastPrompt(o) } as Message2LastPrompt;
    case 'progress': return { type: 'progress', ...parseProgress(o) } as Message2Progress;
    case 'prompt_suggestion': return { type: 'prompt_suggestion', ...parsePromptSuggestion(o) } as Message2PromptSuggestion;
    case 'queue-operation': return { type: 'queue-operation', ...parseQueueOperation(o) } as Message2QueueOperation;
    case 'rate_limit_event': return { type: 'rate_limit_event', ...parseRateLimitEvent(o) } as Message2RateLimitEvent;
    case 'result': return { type: 'result', ...parseResult(o) } as Message2Result;
    case 'system': return { type: 'system', ...parseSystem(o) } as Message2System;
    case 'user': return parseMessage2User(o);
    case 'worktree-state': return { type: 'worktree-state', ...parseWorktreeState(o) } as Message2WorktreeState;
    default: return { type: _tag ?? 'unknown', ...o } as Message2Unknown;
  }
}

export function message2ToJSON(v: Message2): Record<string, unknown> {
  switch (v.type) {
    case 'assistant': return message2AssistantToJSON(v as Message2Assistant);
    case 'custom-title': return { type: 'custom-title', ...customTitleToJSON(v as any) };
    case 'file-history-snapshot': return { type: 'file-history-snapshot', ...fileHistorySnapshotToJSON(v as any) };
    case 'last-prompt': return { type: 'last-prompt', ...lastPromptToJSON(v as any) };
    case 'progress': return { type: 'progress', ...progressToJSON(v as any) };
    case 'prompt_suggestion': return { type: 'prompt_suggestion', ...promptSuggestionToJSON(v as any) };
    case 'queue-operation': return { type: 'queue-operation', ...queueOperationToJSON(v as any) };
    case 'rate_limit_event': return { type: 'rate_limit_event', ...rateLimitEventToJSON(v as any) };
    case 'result': return { type: 'result', ...resultToJSON(v as any) };
    case 'system': return { type: 'system', ...systemToJSON(v as any) };
    case 'user': return message2UserToJSON(v as Message2User);
    case 'worktree-state': return { type: 'worktree-state', ...worktreeStateToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isMessage2Assistant = (v: Message2): v is Message2Assistant => v.type === 'assistant';
export const isMessage2CustomTitle = (v: Message2): v is Message2CustomTitle => v.type === 'custom-title';
export const isMessage2FileHistorySnapshot = (v: Message2): v is Message2FileHistorySnapshot => v.type === 'file-history-snapshot';
export const isMessage2LastPrompt = (v: Message2): v is Message2LastPrompt => v.type === 'last-prompt';
export const isMessage2Progress = (v: Message2): v is Message2Progress => v.type === 'progress';
export const isMessage2PromptSuggestion = (v: Message2): v is Message2PromptSuggestion => v.type === 'prompt_suggestion';
export const isMessage2QueueOperation = (v: Message2): v is Message2QueueOperation => v.type === 'queue-operation';
export const isMessage2RateLimitEvent = (v: Message2): v is Message2RateLimitEvent => v.type === 'rate_limit_event';
export const isMessage2Result = (v: Message2): v is Message2Result => v.type === 'result';
export const isMessage2System = (v: Message2): v is Message2System => v.type === 'system';
export const isMessage2User = (v: Message2): v is Message2User => v.type === 'user';
export const isMessage2WorktreeState = (v: Message2): v is Message2WorktreeState => v.type === 'worktree-state';

export function parseMessage2Assistant(o: Record<string, unknown>): Message2Assistant {
  return {
    type: 'assistant',
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    cwd: asStr(pick(o, 'cwd')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    error: asStr(pick(o, 'error')),
    forkedFrom: (() => { const _o = asObj(pick(o, 'forked_from', 'forkedFrom')); return _o ? parseForkedFrom(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isApiErrorMessage: asBool(pick(o, 'is_api_error_message', 'isApiErrorMessage')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    line: asNum(pick(o, 'line')),
    message: (() => { const _o = asObj(pick(o, 'message')); return _o ? parseMessage2AssistantMessage(_o) : undefined; })(),
    parentToolUseId: asStr(pick(o, 'parent_tool_use_id', 'parentToolUseID', 'parentToolUseId')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    requestId: asStr(pick(o, 'request_id', 'requestID', 'requestId')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
    timestamp: asStr(pick(o, 'timestamp')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseAssistantUsage(_o) : undefined; })(),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function message2AssistantToJSON(v: Message2Assistant): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['type'] = 'assistant';
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.error != null) d['error'] = v.error;
  if (v.forkedFrom != null) d['forked_from'] = forkedFromToJSON(v.forkedFrom);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isApiErrorMessage != null) d['is_api_error_message'] = v.isApiErrorMessage;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.line != null) d['line'] = v.line;
  if (v.message != null) d['message'] = message2AssistantMessageToJSON(v.message);
  if (v.parentToolUseId != null) d['parent_tool_use_id'] = v.parentToolUseId;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.teamName != null) d['team_name'] = v.teamName;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.usage != null) d['usage'] = assistantUsageToJSON(v.usage);
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseForkedFrom(o: Record<string, unknown>): ForkedFrom {
  return {
    messageUuid: asStr(pick(o, 'message_uuid', 'messageUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
  };
}

export function forkedFromToJSON(v: ForkedFrom): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.messageUuid != null) d['message_uuid'] = v.messageUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  return d;
}

export function parseMessage2AssistantMessage(o: Record<string, unknown>): Message2AssistantMessage {
  return {
    container: pick(o, 'container'),
    content: asArr(pick(o, 'content'))?.map(v => parseMessage2AssistantMessageContent(v)),
    contextManagement: (() => { const _o = asObj(pick(o, 'context_management', 'contextManagement')); return _o ? parseContextManagement(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    model: asStr(pick(o, 'model')),
    role: asStr(pick(o, 'role')),
    stopReason: asStr(pick(o, 'stop_reason', 'stopReason')),
    stopSequence: asStr(pick(o, 'stop_sequence', 'stopSequence')),
    type: asStr(pick(o, 'type')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseMessageUsage(_o) : undefined; })(),
  };
}

export function message2AssistantMessageToJSON(v: Message2AssistantMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.container != null) d['container'] = v.container;
  if (v.content != null) d['content'] = v.content.map(v => message2AssistantMessageContentToJSON(v));
  if (v.contextManagement != null) d['context_management'] = contextManagementToJSON(v.contextManagement);
  if (v.id != null) d['id'] = v.id;
  if (v.model != null) d['model'] = v.model;
  if (v.role != null) d['role'] = v.role;
  if (v.stopReason != null) d['stop_reason'] = v.stopReason;
  if (v.stopSequence != null) d['stop_sequence'] = v.stopSequence;
  if (v.type != null) d['type'] = v.type;
  if (v.usage != null) d['usage'] = messageUsageToJSON(v.usage);
  return d;
}

export function parseMessage2AssistantMessageContent(json: unknown): Message2AssistantMessageContent {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as Message2AssistantMessageContentUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'text': return { type: 'text', ...parseText(o) } as Message2AssistantMessageContentText;
    case 'thinking': return { type: 'thinking', ...parseThinking(o) } as Message2AssistantMessageContentThinking;
    case 'tool_use': return { type: 'tool_use', ...parseToolUse(o) } as Message2AssistantMessageContentToolUse;
    default: return { type: _tag ?? 'unknown', ...o } as Message2AssistantMessageContentUnknown;
  }
}

export function message2AssistantMessageContentToJSON(v: Message2AssistantMessageContent): Record<string, unknown> {
  switch (v.type) {
    case 'text': return { type: 'text', ...textToJSON(v as any) };
    case 'thinking': return { type: 'thinking', ...thinkingToJSON(v as any) };
    case 'tool_use': return { type: 'tool_use', ...toolUseToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isMessage2AssistantMessageContentText = (v: Message2AssistantMessageContent): v is Message2AssistantMessageContentText => v.type === 'text';
export const isMessage2AssistantMessageContentThinking = (v: Message2AssistantMessageContent): v is Message2AssistantMessageContentThinking => v.type === 'thinking';
export const isMessage2AssistantMessageContentToolUse = (v: Message2AssistantMessageContent): v is Message2AssistantMessageContentToolUse => v.type === 'tool_use';

export function parseText(o: Record<string, unknown>): Text {
  return {
    text: asStr(pick(o, 'text')),
  };
}

export function textToJSON(v: Text): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.text != null) d['text'] = v.text;
  return d;
}

export function parseThinking(o: Record<string, unknown>): Thinking {
  return {
    signature: asStr(pick(o, 'signature')),
    thinking: asStr(pick(o, 'thinking')),
  };
}

export function thinkingToJSON(v: Thinking): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.signature != null) d['signature'] = v.signature;
  if (v.thinking != null) d['thinking'] = v.thinking;
  return d;
}

export function parseToolUse(json: unknown): ToolUse {
  const o = asObj(json);
  if (!o) return { name: 'unknown' } as ToolUseUnknown;
  const _tag = asStr(o.name);
  switch (_tag) {
    case 'Agent': return { name: 'Agent', ...parseAgent(o) } as ToolUseAgent;
    case 'AskUserQuestion': return parseToolUseAskUserQuestion(o);
    case 'Bash': return parseToolUseBash(o);
    case 'CronCreate': return parseToolUseCronCreate(o);
    case 'Edit': return parseToolUseEdit(o);
    case 'EnterPlanMode': return parseToolUseEnterPlanMode(o);
    case 'EnterWorktree': return parseToolUseEnterWorktree(o);
    case 'ExitPlanMode': return parseToolUseExitPlanMode(o);
    case 'ExitWorktree': return parseToolUseExitWorktree(o);
    case 'Glob': return parseToolUseGlob(o);
    case 'Grep': return parseToolUseGrep(o);
    case 'Read': return parseToolUseRead(o);
    case 'SendMessage': return parseToolUseSendMessage(o);
    case 'Skill': return parseToolUseSkill(o);
    case 'Task': return parseToolUseTask(o);
    case 'TaskCreate': return parseToolUseTaskCreate(o);
    case 'TaskOutput': return parseToolUseTaskOutput(o);
    case 'TaskStop': return parseToolUseTaskStop(o);
    case 'TaskUpdate': return parseToolUseTaskUpdate(o);
    case 'TeamCreate': return parseToolUseTeamCreate(o);
    case 'TodoWrite': return parseToolUseTodoWrite(o);
    case 'ToolSearch': return parseToolUseToolSearch(o);
    case 'WebFetch': return parseToolUseWebFetch(o);
    case 'WebSearch': return parseToolUseWebSearch(o);
    case 'Write': return parseToolUseWrite(o);
    default: return { name: _tag ?? 'unknown', ...o } as ToolUseUnknown;
  }
}

export function toolUseToJSON(v: ToolUse): Record<string, unknown> {
  switch (v.name) {
    case 'Agent': return { name: 'Agent', ...agentToJSON(v as any) };
    case 'AskUserQuestion': return toolUseAskUserQuestionToJSON(v as ToolUseAskUserQuestion);
    case 'Bash': return toolUseBashToJSON(v as ToolUseBash);
    case 'CronCreate': return toolUseCronCreateToJSON(v as ToolUseCronCreate);
    case 'Edit': return toolUseEditToJSON(v as ToolUseEdit);
    case 'EnterPlanMode': return toolUseEnterPlanModeToJSON(v as ToolUseEnterPlanMode);
    case 'EnterWorktree': return toolUseEnterWorktreeToJSON(v as ToolUseEnterWorktree);
    case 'ExitPlanMode': return toolUseExitPlanModeToJSON(v as ToolUseExitPlanMode);
    case 'ExitWorktree': return toolUseExitWorktreeToJSON(v as ToolUseExitWorktree);
    case 'Glob': return toolUseGlobToJSON(v as ToolUseGlob);
    case 'Grep': return toolUseGrepToJSON(v as ToolUseGrep);
    case 'Read': return toolUseReadToJSON(v as ToolUseRead);
    case 'SendMessage': return toolUseSendMessageToJSON(v as ToolUseSendMessage);
    case 'Skill': return toolUseSkillToJSON(v as ToolUseSkill);
    case 'Task': return toolUseTaskToJSON(v as ToolUseTask);
    case 'TaskCreate': return toolUseTaskCreateToJSON(v as ToolUseTaskCreate);
    case 'TaskOutput': return toolUseTaskOutputToJSON(v as ToolUseTaskOutput);
    case 'TaskStop': return toolUseTaskStopToJSON(v as ToolUseTaskStop);
    case 'TaskUpdate': return toolUseTaskUpdateToJSON(v as ToolUseTaskUpdate);
    case 'TeamCreate': return toolUseTeamCreateToJSON(v as ToolUseTeamCreate);
    case 'TodoWrite': return toolUseTodoWriteToJSON(v as ToolUseTodoWrite);
    case 'ToolSearch': return toolUseToolSearchToJSON(v as ToolUseToolSearch);
    case 'WebFetch': return toolUseWebFetchToJSON(v as ToolUseWebFetch);
    case 'WebSearch': return toolUseWebSearchToJSON(v as ToolUseWebSearch);
    case 'Write': return toolUseWriteToJSON(v as ToolUseWrite);
    default: { const { name: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isToolUseAgent = (v: ToolUse): v is ToolUseAgent => v.name === 'Agent';
export const isToolUseAskUserQuestion = (v: ToolUse): v is ToolUseAskUserQuestion => v.name === 'AskUserQuestion';
export const isToolUseBash = (v: ToolUse): v is ToolUseBash => v.name === 'Bash';
export const isToolUseCronCreate = (v: ToolUse): v is ToolUseCronCreate => v.name === 'CronCreate';
export const isToolUseEdit = (v: ToolUse): v is ToolUseEdit => v.name === 'Edit';
export const isToolUseEnterPlanMode = (v: ToolUse): v is ToolUseEnterPlanMode => v.name === 'EnterPlanMode';
export const isToolUseEnterWorktree = (v: ToolUse): v is ToolUseEnterWorktree => v.name === 'EnterWorktree';
export const isToolUseExitPlanMode = (v: ToolUse): v is ToolUseExitPlanMode => v.name === 'ExitPlanMode';
export const isToolUseExitWorktree = (v: ToolUse): v is ToolUseExitWorktree => v.name === 'ExitWorktree';
export const isToolUseGlob = (v: ToolUse): v is ToolUseGlob => v.name === 'Glob';
export const isToolUseGrep = (v: ToolUse): v is ToolUseGrep => v.name === 'Grep';
export const isToolUseRead = (v: ToolUse): v is ToolUseRead => v.name === 'Read';
export const isToolUseSendMessage = (v: ToolUse): v is ToolUseSendMessage => v.name === 'SendMessage';
export const isToolUseSkill = (v: ToolUse): v is ToolUseSkill => v.name === 'Skill';
export const isToolUseTask = (v: ToolUse): v is ToolUseTask => v.name === 'Task';
export const isToolUseTaskCreate = (v: ToolUse): v is ToolUseTaskCreate => v.name === 'TaskCreate';
export const isToolUseTaskOutput = (v: ToolUse): v is ToolUseTaskOutput => v.name === 'TaskOutput';
export const isToolUseTaskStop = (v: ToolUse): v is ToolUseTaskStop => v.name === 'TaskStop';
export const isToolUseTaskUpdate = (v: ToolUse): v is ToolUseTaskUpdate => v.name === 'TaskUpdate';
export const isToolUseTeamCreate = (v: ToolUse): v is ToolUseTeamCreate => v.name === 'TeamCreate';
export const isToolUseTodoWrite = (v: ToolUse): v is ToolUseTodoWrite => v.name === 'TodoWrite';
export const isToolUseToolSearch = (v: ToolUse): v is ToolUseToolSearch => v.name === 'ToolSearch';
export const isToolUseWebFetch = (v: ToolUse): v is ToolUseWebFetch => v.name === 'WebFetch';
export const isToolUseWebSearch = (v: ToolUse): v is ToolUseWebSearch => v.name === 'WebSearch';
export const isToolUseWrite = (v: ToolUse): v is ToolUseWrite => v.name === 'Write';

export function parseAgent(o: Record<string, unknown>): Agent {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseAgentInput(_o) : undefined; })(),
  };
}

export function agentToJSON(v: Agent): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = agentInputToJSON(v.input);
  return d;
}

export function parseCaller(o: Record<string, unknown>): Caller {
  return {
    type: asStr(pick(o, 'type')),
  };
}

export function callerToJSON(v: Caller): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseAgentInput(o: Record<string, unknown>): AgentInput {
  return {
    description: asStr(pick(o, 'description')),
    isolation: asStr(pick(o, 'isolation')),
    mode: asStr(pick(o, 'mode')),
    model: asStr(pick(o, 'model')),
    name: asStr(pick(o, 'name')),
    prompt: asStr(pick(o, 'prompt')),
    resume: asStr(pick(o, 'resume')),
    runInBackground: asBool(pick(o, 'run_in_background', 'runInBackground')),
    subagentType: asStr(pick(o, 'subagent_type', 'subagentType')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
  };
}

export function agentInputToJSON(v: AgentInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.isolation != null) d['isolation'] = v.isolation;
  if (v.mode != null) d['mode'] = v.mode;
  if (v.model != null) d['model'] = v.model;
  if (v.name != null) d['name'] = v.name;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.resume != null) d['resume'] = v.resume;
  if (v.runInBackground != null) d['run_in_background'] = v.runInBackground;
  if (v.subagentType != null) d['subagent_type'] = v.subagentType;
  if (v.teamName != null) d['team_name'] = v.teamName;
  return d;
}

export function parseToolUseAskUserQuestion(o: Record<string, unknown>): ToolUseAskUserQuestion {
  return {
    name: 'AskUserQuestion',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseAskUserQuestionInput(_o) : undefined; })(),
  };
}

export function toolUseAskUserQuestionToJSON(v: ToolUseAskUserQuestion): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'AskUserQuestion';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = askUserQuestionInputToJSON(v.input);
  return d;
}

export function parseAskUserQuestionInput(o: Record<string, unknown>): AskUserQuestionInput {
  return {
    questions: asArr(pick(o, 'questions'))?.map(v => { const _o = asObj(v); return _o ? parseInputQuestions(_o) : undefined; }).filter((v): v is InputQuestions => v !== undefined),
  };
}

export function askUserQuestionInputToJSON(v: AskUserQuestionInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.questions != null) d['questions'] = v.questions.map(v => inputQuestionsToJSON(v));
  return d;
}

export function parseInputQuestions(o: Record<string, unknown>): InputQuestions {
  return {
    header: asStr(pick(o, 'header')),
    multiSelect: asBool(pick(o, 'multi_select', 'multiSelect')),
    options: asArr(pick(o, 'options'))?.map(v => { const _o = asObj(v); return _o ? parseOptions(_o) : undefined; }).filter((v): v is Options => v !== undefined),
    question: asStr(pick(o, 'question')),
  };
}

export function inputQuestionsToJSON(v: InputQuestions): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.header != null) d['header'] = v.header;
  if (v.multiSelect != null) d['multi_select'] = v.multiSelect;
  if (v.options != null) d['options'] = v.options.map(v => optionsToJSON(v));
  if (v.question != null) d['question'] = v.question;
  return d;
}

export function parseOptions(o: Record<string, unknown>): Options {
  return {
    description: asStr(pick(o, 'description')),
    label: asStr(pick(o, 'label')),
    preview: asStr(pick(o, 'preview')),
  };
}

export function optionsToJSON(v: Options): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.label != null) d['label'] = v.label;
  if (v.preview != null) d['preview'] = v.preview;
  return d;
}

export function parseToolUseBash(o: Record<string, unknown>): ToolUseBash {
  return {
    name: 'Bash',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolUseBashInput(_o) : undefined; })(),
  };
}

export function toolUseBashToJSON(v: ToolUseBash): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Bash';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolUseBashInputToJSON(v.input);
  return d;
}

export function parseToolUseBashInput(o: Record<string, unknown>): ToolUseBashInput {
  return {
    command: asStr(pick(o, 'command')),
    context: asNum(pick(o, 'context')),
    description: asStr(pick(o, 'description')),
    outputMode: asStr(pick(o, 'output_mode', 'outputMode')),
    path: asStr(pick(o, 'path')),
    pattern: asStr(pick(o, 'pattern')),
    runInBackground: asBool(pick(o, 'run_in_background', 'runInBackground')),
    timeout: asNum(pick(o, 'timeout')),
  };
}

export function toolUseBashInputToJSON(v: ToolUseBashInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.command != null) d['command'] = v.command;
  if (v.context != null) d['context'] = v.context;
  if (v.description != null) d['description'] = v.description;
  if (v.outputMode != null) d['output_mode'] = v.outputMode;
  if (v.path != null) d['path'] = v.path;
  if (v.pattern != null) d['pattern'] = v.pattern;
  if (v.runInBackground != null) d['run_in_background'] = v.runInBackground;
  if (v.timeout != null) d['timeout'] = v.timeout;
  return d;
}

export function parseToolUseCronCreate(o: Record<string, unknown>): ToolUseCronCreate {
  return {
    name: 'CronCreate',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseCronCreateInput(_o) : undefined; })(),
  };
}

export function toolUseCronCreateToJSON(v: ToolUseCronCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'CronCreate';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = cronCreateInputToJSON(v.input);
  return d;
}

export function parseCronCreateInput(o: Record<string, unknown>): CronCreateInput {
  return {
    cron: asStr(pick(o, 'cron')),
    prompt: asStr(pick(o, 'prompt')),
    recurring: asBool(pick(o, 'recurring')),
  };
}

export function cronCreateInputToJSON(v: CronCreateInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cron != null) d['cron'] = v.cron;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.recurring != null) d['recurring'] = v.recurring;
  return d;
}

export function parseToolUseEdit(o: Record<string, unknown>): ToolUseEdit {
  return {
    name: 'Edit',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseEditInput(_o) : undefined; })(),
  };
}

export function toolUseEditToJSON(v: ToolUseEdit): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Edit';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = editInputToJSON(v.input);
  return d;
}

export function parseEditInput(o: Record<string, unknown>): EditInput {
  return {
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    newString: asStr(pick(o, 'new_string', 'newString')),
    oldString: asStr(pick(o, 'old_string', 'oldString')),
    replaceAll: asBool(pick(o, 'replace_all', 'replaceAll')),
  };
}

export function editInputToJSON(v: EditInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.newString != null) d['new_string'] = v.newString;
  if (v.oldString != null) d['old_string'] = v.oldString;
  if (v.replaceAll != null) d['replace_all'] = v.replaceAll;
  return d;
}

export function parseToolUseEnterPlanMode(o: Record<string, unknown>): ToolUseEnterPlanMode {
  return {
    name: 'EnterPlanMode',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: asObj(pick(o, 'input')),
  };
}

export function toolUseEnterPlanModeToJSON(v: ToolUseEnterPlanMode): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'EnterPlanMode';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = v.input;
  return d;
}

export function parseToolUseEnterWorktree(o: Record<string, unknown>): ToolUseEnterWorktree {
  return {
    name: 'EnterWorktree',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseEnterWorktreeInput(_o) : undefined; })(),
  };
}

export function toolUseEnterWorktreeToJSON(v: ToolUseEnterWorktree): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'EnterWorktree';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = enterWorktreeInputToJSON(v.input);
  return d;
}

export function parseEnterWorktreeInput(o: Record<string, unknown>): EnterWorktreeInput {
  return {
    name: asStr(pick(o, 'name')),
  };
}

export function enterWorktreeInputToJSON(v: EnterWorktreeInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.name != null) d['name'] = v.name;
  return d;
}

export function parseToolUseExitPlanMode(o: Record<string, unknown>): ToolUseExitPlanMode {
  return {
    name: 'ExitPlanMode',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseExitPlanModeInput(_o) : undefined; })(),
  };
}

export function toolUseExitPlanModeToJSON(v: ToolUseExitPlanMode): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'ExitPlanMode';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = exitPlanModeInputToJSON(v.input);
  return d;
}

export function parseExitPlanModeInput(o: Record<string, unknown>): ExitPlanModeInput {
  return {
    allowedPrompts: asArr(pick(o, 'allowed_prompts', 'allowedPrompts'))?.map(v => { const _o = asObj(v); return _o ? parseAllowedPrompts(_o) : undefined; }).filter((v): v is AllowedPrompts => v !== undefined),
    plan: asStr(pick(o, 'plan')),
    planFilePath: asStr(pick(o, 'plan_file_path', 'planFilePath')),
  };
}

export function exitPlanModeInputToJSON(v: ExitPlanModeInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.allowedPrompts != null) d['allowed_prompts'] = v.allowedPrompts.map(v => allowedPromptsToJSON(v));
  if (v.plan != null) d['plan'] = v.plan;
  if (v.planFilePath != null) d['plan_file_path'] = v.planFilePath;
  return d;
}

export function parseAllowedPrompts(o: Record<string, unknown>): AllowedPrompts {
  return {
    prompt: asStr(pick(o, 'prompt')),
    tool: asStr(pick(o, 'tool')),
  };
}

export function allowedPromptsToJSON(v: AllowedPrompts): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.tool != null) d['tool'] = v.tool;
  return d;
}

export function parseToolUseExitWorktree(o: Record<string, unknown>): ToolUseExitWorktree {
  return {
    name: 'ExitWorktree',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseExitWorktreeInput(_o) : undefined; })(),
  };
}

export function toolUseExitWorktreeToJSON(v: ToolUseExitWorktree): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'ExitWorktree';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = exitWorktreeInputToJSON(v.input);
  return d;
}

export function parseExitWorktreeInput(o: Record<string, unknown>): ExitWorktreeInput {
  return {
    action: asStr(pick(o, 'action')),
  };
}

export function exitWorktreeInputToJSON(v: ExitWorktreeInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.action != null) d['action'] = v.action;
  return d;
}

export function parseToolUseGlob(o: Record<string, unknown>): ToolUseGlob {
  return {
    name: 'Glob',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseGlobInput(_o) : undefined; })(),
  };
}

export function toolUseGlobToJSON(v: ToolUseGlob): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Glob';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = globInputToJSON(v.input);
  return d;
}

export function parseGlobInput(o: Record<string, unknown>): GlobInput {
  return {
    path: asStr(pick(o, 'path')),
    pattern: asStr(pick(o, 'pattern')),
  };
}

export function globInputToJSON(v: GlobInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.path != null) d['path'] = v.path;
  if (v.pattern != null) d['pattern'] = v.pattern;
  return d;
}

export function parseToolUseGrep(o: Record<string, unknown>): ToolUseGrep {
  return {
    name: 'Grep',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolUseGrepInput(_o) : undefined; })(),
  };
}

export function toolUseGrepToJSON(v: ToolUseGrep): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Grep';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolUseGrepInputToJSON(v.input);
  return d;
}

export function parseToolUseGrepInput(o: Record<string, unknown>): ToolUseGrepInput {
  return {
    A: asNum(pick(o, '-a', '-A', 'A')),
    B: asNum(pick(o, '-b', '-B', 'B')),
    C: asNum(pick(o, '-c', '-C', 'C')),
    I: asBool(pick(o, '-i', 'I')),
    N: asBool(pick(o, '-n', 'N')),
    context: asNum(pick(o, 'context')),
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    glob: asStr(pick(o, 'glob')),
    headLimit: asNum(pick(o, 'head_limit', 'headLimit')),
    limit: asNum(pick(o, 'limit')),
    offset: asNum(pick(o, 'offset')),
    outputMode: asStr(pick(o, 'output_mode', 'outputMode')),
    path: asStr(pick(o, 'path')),
    pattern: asStr(pick(o, 'pattern')),
    query: asStr(pick(o, 'query')),
    type: asStr(pick(o, 'type')),
  };
}

export function toolUseGrepInputToJSON(v: ToolUseGrepInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.A != null) d['-a'] = v.A;
  if (v.B != null) d['-b'] = v.B;
  if (v.C != null) d['-c'] = v.C;
  if (v.I != null) d['-i'] = v.I;
  if (v.N != null) d['-n'] = v.N;
  if (v.context != null) d['context'] = v.context;
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.glob != null) d['glob'] = v.glob;
  if (v.headLimit != null) d['head_limit'] = v.headLimit;
  if (v.limit != null) d['limit'] = v.limit;
  if (v.offset != null) d['offset'] = v.offset;
  if (v.outputMode != null) d['output_mode'] = v.outputMode;
  if (v.path != null) d['path'] = v.path;
  if (v.pattern != null) d['pattern'] = v.pattern;
  if (v.query != null) d['query'] = v.query;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseToolUseRead(o: Record<string, unknown>): ToolUseRead {
  return {
    name: 'Read',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolUseReadInput(_o) : undefined; })(),
  };
}

export function toolUseReadToJSON(v: ToolUseRead): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Read';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolUseReadInputToJSON(v.input);
  return d;
}

export function parseToolUseReadInput(o: Record<string, unknown>): ToolUseReadInput {
  return {
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    limit: parseLimit(pick(o, 'limit')),
    offset: parseToolUseReadInputOffset(pick(o, 'offset')),
  };
}

export function toolUseReadInputToJSON(v: ToolUseReadInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.limit != null) d['limit'] = limitToJSON(v.limit);
  if (v.offset != null) d['offset'] = toolUseReadInputOffsetToJSON(v.offset);
  return d;
}

export function parseLimit(json: unknown): Limit {
  if (typeof json === 'string') return json;
  if (typeof json === 'number') return json;
  return json as Limit;
}

export function limitToJSON(v: Limit): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return v;
  return v;
}

export function parseToolUseReadInputOffset(json: unknown): ToolUseReadInputOffset {
  if (typeof json === 'string') return json;
  if (typeof json === 'number') return json;
  return json as ToolUseReadInputOffset;
}

export function toolUseReadInputOffsetToJSON(v: ToolUseReadInputOffset): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return v;
  return v;
}

export function parseToolUseSendMessage(o: Record<string, unknown>): ToolUseSendMessage {
  return {
    name: 'SendMessage',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseSendMessageInput(_o) : undefined; })(),
  };
}

export function toolUseSendMessageToJSON(v: ToolUseSendMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'SendMessage';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = sendMessageInputToJSON(v.input);
  return d;
}

export function parseSendMessageInput(o: Record<string, unknown>): SendMessageInput {
  return {
    approve: asBool(pick(o, 'approve')),
    content: asStr(pick(o, 'content')),
    message: parseInputMessage(pick(o, 'message')),
    recipient: asStr(pick(o, 'recipient')),
    requestId: asStr(pick(o, 'request_id', 'requestID', 'requestId')),
    summary: asStr(pick(o, 'summary')),
    to: asStr(pick(o, 'to')),
    type: asStr(pick(o, 'type')),
  };
}

export function sendMessageInputToJSON(v: SendMessageInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.approve != null) d['approve'] = v.approve;
  if (v.content != null) d['content'] = v.content;
  if (v.message != null) d['message'] = inputMessageToJSON(v.message);
  if (v.recipient != null) d['recipient'] = v.recipient;
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.summary != null) d['summary'] = v.summary;
  if (v.to != null) d['to'] = v.to;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseInputMessage(json: unknown): InputMessage {
  if (typeof json === 'string') return json;
  { const _o = asObj(json); if (_o) return parseMessageObject(_o); }
  return json as InputMessage;
}

export function inputMessageToJSON(v: InputMessage): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) return messageObjectToJSON(v as MessageObject);
  return v;
}

export function parseMessageObject(o: Record<string, unknown>): MessageObject {
  return {
    approve: asBool(pick(o, 'approve')),
    reason: asStr(pick(o, 'reason')),
    requestId: asStr(pick(o, 'request_id', 'requestID', 'requestId')),
    type: asStr(pick(o, 'type')),
  };
}

export function messageObjectToJSON(v: MessageObject): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.approve != null) d['approve'] = v.approve;
  if (v.reason != null) d['reason'] = v.reason;
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseToolUseSkill(o: Record<string, unknown>): ToolUseSkill {
  return {
    name: 'Skill',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseSkillInput(_o) : undefined; })(),
  };
}

export function toolUseSkillToJSON(v: ToolUseSkill): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Skill';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = skillInputToJSON(v.input);
  return d;
}

export function parseSkillInput(o: Record<string, unknown>): SkillInput {
  return {
    args: asStr(pick(o, 'args')),
    skill: asStr(pick(o, 'skill')),
  };
}

export function skillInputToJSON(v: SkillInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.args != null) d['args'] = v.args;
  if (v.skill != null) d['skill'] = v.skill;
  return d;
}

export function parseToolUseTask(o: Record<string, unknown>): ToolUseTask {
  return {
    name: 'Task',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTaskInput(_o) : undefined; })(),
  };
}

export function toolUseTaskToJSON(v: ToolUseTask): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Task';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = taskInputToJSON(v.input);
  return d;
}

export function parseTaskInput(o: Record<string, unknown>): TaskInput {
  return {
    description: asStr(pick(o, 'description')),
    model: asStr(pick(o, 'model')),
    prompt: asStr(pick(o, 'prompt')),
    resume: asStr(pick(o, 'resume')),
    runInBackground: asBool(pick(o, 'run_in_background', 'runInBackground')),
    subagentType: asStr(pick(o, 'subagent_type', 'subagentType')),
  };
}

export function taskInputToJSON(v: TaskInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.model != null) d['model'] = v.model;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.resume != null) d['resume'] = v.resume;
  if (v.runInBackground != null) d['run_in_background'] = v.runInBackground;
  if (v.subagentType != null) d['subagent_type'] = v.subagentType;
  return d;
}

export function parseToolUseTaskCreate(o: Record<string, unknown>): ToolUseTaskCreate {
  return {
    name: 'TaskCreate',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTaskCreateInput(_o) : undefined; })(),
  };
}

export function toolUseTaskCreateToJSON(v: ToolUseTaskCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TaskCreate';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = taskCreateInputToJSON(v.input);
  return d;
}

export function parseTaskCreateInput(o: Record<string, unknown>): TaskCreateInput {
  return {
    activeForm: asStr(pick(o, 'active_form', 'activeForm')),
    description: asStr(pick(o, 'description')),
    subject: asStr(pick(o, 'subject')),
  };
}

export function taskCreateInputToJSON(v: TaskCreateInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.activeForm != null) d['active_form'] = v.activeForm;
  if (v.description != null) d['description'] = v.description;
  if (v.subject != null) d['subject'] = v.subject;
  return d;
}

export function parseToolUseTaskOutput(o: Record<string, unknown>): ToolUseTaskOutput {
  return {
    name: 'TaskOutput',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTaskOutputInput(_o) : undefined; })(),
  };
}

export function toolUseTaskOutputToJSON(v: ToolUseTaskOutput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TaskOutput';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = taskOutputInputToJSON(v.input);
  return d;
}

export function parseTaskOutputInput(o: Record<string, unknown>): TaskOutputInput {
  return {
    block: asBool(pick(o, 'block')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    timeout: asNum(pick(o, 'timeout')),
  };
}

export function taskOutputInputToJSON(v: TaskOutputInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.block != null) d['block'] = v.block;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.timeout != null) d['timeout'] = v.timeout;
  return d;
}

export function parseToolUseTaskStop(o: Record<string, unknown>): ToolUseTaskStop {
  return {
    name: 'TaskStop',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTaskStopInput(_o) : undefined; })(),
  };
}

export function toolUseTaskStopToJSON(v: ToolUseTaskStop): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TaskStop';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = taskStopInputToJSON(v.input);
  return d;
}

export function parseTaskStopInput(o: Record<string, unknown>): TaskStopInput {
  return {
    taskId: asStr(pick(o, 'task_id', 'taskId')),
  };
}

export function taskStopInputToJSON(v: TaskStopInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.taskId != null) d['task_id'] = v.taskId;
  return d;
}

export function parseToolUseTaskUpdate(o: Record<string, unknown>): ToolUseTaskUpdate {
  return {
    name: 'TaskUpdate',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTaskUpdateInput(_o) : undefined; })(),
  };
}

export function toolUseTaskUpdateToJSON(v: ToolUseTaskUpdate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TaskUpdate';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = taskUpdateInputToJSON(v.input);
  return d;
}

export function parseTaskUpdateInput(o: Record<string, unknown>): TaskUpdateInput {
  return {
    activeForm: asStr(pick(o, 'active_form', 'activeForm')),
    addBlockedBy: asArr(pick(o, 'add_blocked_by', 'addBlockedBy'))?.map(v => asStr(v)!),
    description: asStr(pick(o, 'description')),
    owner: asStr(pick(o, 'owner')),
    status: asStr(pick(o, 'status')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
  };
}

export function taskUpdateInputToJSON(v: TaskUpdateInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.activeForm != null) d['active_form'] = v.activeForm;
  if (v.addBlockedBy != null) d['add_blocked_by'] = v.addBlockedBy;
  if (v.description != null) d['description'] = v.description;
  if (v.owner != null) d['owner'] = v.owner;
  if (v.status != null) d['status'] = v.status;
  if (v.taskId != null) d['task_id'] = v.taskId;
  return d;
}

export function parseToolUseTeamCreate(o: Record<string, unknown>): ToolUseTeamCreate {
  return {
    name: 'TeamCreate',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTeamCreateInput(_o) : undefined; })(),
  };
}

export function toolUseTeamCreateToJSON(v: ToolUseTeamCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TeamCreate';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = teamCreateInputToJSON(v.input);
  return d;
}

export function parseTeamCreateInput(o: Record<string, unknown>): TeamCreateInput {
  return {
    agentType: asStr(pick(o, 'agent_type', 'agentType')),
    description: asStr(pick(o, 'description')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
  };
}

export function teamCreateInputToJSON(v: TeamCreateInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agentType != null) d['agent_type'] = v.agentType;
  if (v.description != null) d['description'] = v.description;
  if (v.teamName != null) d['team_name'] = v.teamName;
  return d;
}

export function parseToolUseTodoWrite(o: Record<string, unknown>): ToolUseTodoWrite {
  return {
    name: 'TodoWrite',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseTodoWriteInput(_o) : undefined; })(),
  };
}

export function toolUseTodoWriteToJSON(v: ToolUseTodoWrite): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'TodoWrite';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = todoWriteInputToJSON(v.input);
  return d;
}

export function parseTodoWriteInput(o: Record<string, unknown>): TodoWriteInput {
  return {
    todos: parseTodos(pick(o, 'todos')),
  };
}

export function todoWriteInputToJSON(v: TodoWriteInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.todos != null) d['todos'] = todosToJSON(v.todos);
  return d;
}

export function parseTodos(json: unknown): Todos {
  if (typeof json === 'string') return json;
  if (Array.isArray(json)) return asArr(json)?.map(v => { const _o = asObj(v); return _o ? parseTodosItem(_o) : undefined; }).filter((v): v is TodosItem => v !== undefined);
  return json as Todos;
}

export function todosToJSON(v: Todos): unknown {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v;
  return v;
}

export function parseTodosItem(o: Record<string, unknown>): TodosItem {
  return {
    activeForm: asStr(pick(o, 'active_form', 'activeForm')),
    content: asStr(pick(o, 'content')),
    status: asStr(pick(o, 'status')),
  };
}

export function todosItemToJSON(v: TodosItem): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.activeForm != null) d['active_form'] = v.activeForm;
  if (v.content != null) d['content'] = v.content;
  if (v.status != null) d['status'] = v.status;
  return d;
}

export function parseToolUseToolSearch(o: Record<string, unknown>): ToolUseToolSearch {
  return {
    name: 'ToolSearch',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolSearchInput(_o) : undefined; })(),
  };
}

export function toolUseToolSearchToJSON(v: ToolUseToolSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'ToolSearch';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolSearchInputToJSON(v.input);
  return d;
}

export function parseToolSearchInput(o: Record<string, unknown>): ToolSearchInput {
  return {
    maxResults: asNum(pick(o, 'max_results', 'maxResults')),
    query: asStr(pick(o, 'query')),
  };
}

export function toolSearchInputToJSON(v: ToolSearchInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.maxResults != null) d['max_results'] = v.maxResults;
  if (v.query != null) d['query'] = v.query;
  return d;
}

export function parseToolUseWebFetch(o: Record<string, unknown>): ToolUseWebFetch {
  return {
    name: 'WebFetch',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolUseWebFetchInput(_o) : undefined; })(),
  };
}

export function toolUseWebFetchToJSON(v: ToolUseWebFetch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'WebFetch';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolUseWebFetchInputToJSON(v.input);
  return d;
}

export function parseToolUseWebFetchInput(o: Record<string, unknown>): ToolUseWebFetchInput {
  return {
    prompt: asStr(pick(o, 'prompt')),
    url: asStr(pick(o, 'url')),
  };
}

export function toolUseWebFetchInputToJSON(v: ToolUseWebFetchInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.url != null) d['url'] = v.url;
  return d;
}

export function parseToolUseWebSearch(o: Record<string, unknown>): ToolUseWebSearch {
  return {
    name: 'WebSearch',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolUseWebSearchInput(_o) : undefined; })(),
  };
}

export function toolUseWebSearchToJSON(v: ToolUseWebSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'WebSearch';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolUseWebSearchInputToJSON(v.input);
  return d;
}

export function parseToolUseWebSearchInput(o: Record<string, unknown>): ToolUseWebSearchInput {
  return {
    allowedDomains: asArr(pick(o, 'allowed_domains', 'allowedDomains'))?.map(v => asStr(v)!),
    query: asStr(pick(o, 'query')),
    searchQuery: asStr(pick(o, 'search_query', 'searchQuery')),
  };
}

export function toolUseWebSearchInputToJSON(v: ToolUseWebSearchInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.allowedDomains != null) d['allowed_domains'] = v.allowedDomains;
  if (v.query != null) d['query'] = v.query;
  if (v.searchQuery != null) d['search_query'] = v.searchQuery;
  return d;
}

export function parseToolUseWrite(o: Record<string, unknown>): ToolUseWrite {
  return {
    name: 'Write',
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseWriteInput(_o) : undefined; })(),
  };
}

export function toolUseWriteToJSON(v: ToolUseWrite): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['name'] = 'Write';
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = writeInputToJSON(v.input);
  return d;
}

export function parseWriteInput(o: Record<string, unknown>): WriteInput {
  return {
    content: asStr(pick(o, 'content')),
    filePath: asStr(pick(o, 'file_path', 'filePath')),
  };
}

export function writeInputToJSON(v: WriteInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.filePath != null) d['file_path'] = v.filePath;
  return d;
}

export function parseContextManagement(o: Record<string, unknown>): ContextManagement {
  return {
    appliedEdits: asArr(pick(o, 'applied_edits', 'appliedEdits')),
  };
}

export function contextManagementToJSON(v: ContextManagement): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.appliedEdits != null) d['applied_edits'] = v.appliedEdits;
  return d;
}

export function parseMessageUsage(o: Record<string, unknown>): MessageUsage {
  return {
    cacheCreation: (() => { const _o = asObj(pick(o, 'cache_creation', 'cacheCreation')); return _o ? parseCacheCreation(_o) : undefined; })(),
    cacheCreationInputTokens: asNum(pick(o, 'cache_creation_input_tokens', 'cacheCreationInputTokens')),
    cacheReadInputTokens: asNum(pick(o, 'cache_read_input_tokens', 'cacheReadInputTokens')),
    inferenceGeo: asStr(pick(o, 'inference_geo', 'inferenceGeo')),
    inputTokens: asNum(pick(o, 'input_tokens', 'inputTokens')),
    iterations: asArr(pick(o, 'iterations')),
    outputTokens: asNum(pick(o, 'output_tokens', 'outputTokens')),
    serverToolUse: (() => { const _o = asObj(pick(o, 'server_tool_use', 'serverToolUse')); return _o ? parseMessageUsageServerToolUse(_o) : undefined; })(),
    serviceTier: asStr(pick(o, 'service_tier', 'serviceTier')),
    speed: asStr(pick(o, 'speed')),
  };
}

export function messageUsageToJSON(v: MessageUsage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cacheCreation != null) d['cache_creation'] = cacheCreationToJSON(v.cacheCreation);
  if (v.cacheCreationInputTokens != null) d['cache_creation_input_tokens'] = v.cacheCreationInputTokens;
  if (v.cacheReadInputTokens != null) d['cache_read_input_tokens'] = v.cacheReadInputTokens;
  if (v.inferenceGeo != null) d['inference_geo'] = v.inferenceGeo;
  if (v.inputTokens != null) d['input_tokens'] = v.inputTokens;
  if (v.iterations != null) d['iterations'] = v.iterations;
  if (v.outputTokens != null) d['output_tokens'] = v.outputTokens;
  if (v.serverToolUse != null) d['server_tool_use'] = messageUsageServerToolUseToJSON(v.serverToolUse);
  if (v.serviceTier != null) d['service_tier'] = v.serviceTier;
  if (v.speed != null) d['speed'] = v.speed;
  return d;
}

export function parseCacheCreation(o: Record<string, unknown>): CacheCreation {
  return {
    ephemeral1hInputTokens: asNum(pick(o, 'ephemeral_1h_input_tokens', 'ephemeral1hInputTokens')),
    ephemeral5mInputTokens: asNum(pick(o, 'ephemeral_5m_input_tokens', 'ephemeral5mInputTokens')),
  };
}

export function cacheCreationToJSON(v: CacheCreation): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.ephemeral1hInputTokens != null) d['ephemeral_1h_input_tokens'] = v.ephemeral1hInputTokens;
  if (v.ephemeral5mInputTokens != null) d['ephemeral_5m_input_tokens'] = v.ephemeral5mInputTokens;
  return d;
}

export function parseMessageUsageServerToolUse(o: Record<string, unknown>): MessageUsageServerToolUse {
  return {
    webFetchRequests: asNum(pick(o, 'web_fetch_requests', 'webFetchRequests')),
    webSearchRequests: asNum(pick(o, 'web_search_requests', 'webSearchRequests')),
  };
}

export function messageUsageServerToolUseToJSON(v: MessageUsageServerToolUse): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.webFetchRequests != null) d['web_fetch_requests'] = v.webFetchRequests;
  if (v.webSearchRequests != null) d['web_search_requests'] = v.webSearchRequests;
  return d;
}

export function parseAssistantUsage(o: Record<string, unknown>): AssistantUsage {
  return {
    cacheCreation: (() => { const _o = asObj(pick(o, 'cache_creation', 'cacheCreation')); return _o ? parseCacheCreation(_o) : undefined; })(),
    cacheCreationInputTokens: asNum(pick(o, 'cache_creation_input_tokens', 'cacheCreationInputTokens')),
    cacheReadInputTokens: asNum(pick(o, 'cache_read_input_tokens', 'cacheReadInputTokens')),
    inferenceGeo: asStr(pick(o, 'inference_geo', 'inferenceGeo')),
    inputTokens: asNum(pick(o, 'input_tokens', 'inputTokens')),
    outputTokens: asNum(pick(o, 'output_tokens', 'outputTokens')),
    serviceTier: asStr(pick(o, 'service_tier', 'serviceTier')),
  };
}

export function assistantUsageToJSON(v: AssistantUsage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cacheCreation != null) d['cache_creation'] = cacheCreationToJSON(v.cacheCreation);
  if (v.cacheCreationInputTokens != null) d['cache_creation_input_tokens'] = v.cacheCreationInputTokens;
  if (v.cacheReadInputTokens != null) d['cache_read_input_tokens'] = v.cacheReadInputTokens;
  if (v.inferenceGeo != null) d['inference_geo'] = v.inferenceGeo;
  if (v.inputTokens != null) d['input_tokens'] = v.inputTokens;
  if (v.outputTokens != null) d['output_tokens'] = v.outputTokens;
  if (v.serviceTier != null) d['service_tier'] = v.serviceTier;
  return d;
}

export function parseCustomTitle(o: Record<string, unknown>): CustomTitle {
  return {
    customTitle: asStr(pick(o, 'custom_title', 'customTitle')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
  };
}

export function customTitleToJSON(v: CustomTitle): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.customTitle != null) d['custom_title'] = v.customTitle;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  return d;
}

export function parseFileHistorySnapshot(o: Record<string, unknown>): FileHistorySnapshot {
  return {
    isSnapshotUpdate: asBool(pick(o, 'is_snapshot_update', 'isSnapshotUpdate')),
    messageId: asStr(pick(o, 'message_id', 'messageId')),
    snapshot: (() => { const _o = asObj(pick(o, 'snapshot')); return _o ? parseSnapshot(_o) : undefined; })(),
  };
}

export function fileHistorySnapshotToJSON(v: FileHistorySnapshot): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.isSnapshotUpdate != null) d['is_snapshot_update'] = v.isSnapshotUpdate;
  if (v.messageId != null) d['message_id'] = v.messageId;
  if (v.snapshot != null) d['snapshot'] = snapshotToJSON(v.snapshot);
  return d;
}

export function parseSnapshot(o: Record<string, unknown>): Snapshot {
  return {
    messageId: asStr(pick(o, 'message_id', 'messageId')),
    timestamp: asStr(pick(o, 'timestamp')),
    trackedFileBackups: (() => { const _o = asObj(pick(o, 'tracked_file_backups', 'trackedFileBackups')); if (!_o) return undefined; const r: Record<string, TrackedFileBackupsValue> = {}; for (const [k, v] of Object.entries(_o)) { const _ov = asObj(v); if (_ov) r[k] = parseTrackedFileBackupsValue(_ov); }; return r; })(),
  };
}

export function snapshotToJSON(v: Snapshot): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.messageId != null) d['message_id'] = v.messageId;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.trackedFileBackups != null) d['tracked_file_backups'] = Object.fromEntries(Object.entries(v.trackedFileBackups).map(([k, v]) => [k, trackedFileBackupsValueToJSON(v)]));
  return d;
}

export function parseTrackedFileBackupsValue(o: Record<string, unknown>): TrackedFileBackupsValue {
  return {
    backupFileName: asStr(pick(o, 'backup_file_name', 'backupFileName')),
    backupTime: asStr(pick(o, 'backup_time', 'backupTime')),
    version: asNum(pick(o, 'version')),
  };
}

export function trackedFileBackupsValueToJSON(v: TrackedFileBackupsValue): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.backupFileName != null) d['backup_file_name'] = v.backupFileName;
  if (v.backupTime != null) d['backup_time'] = v.backupTime;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseLastPrompt(o: Record<string, unknown>): LastPrompt {
  return {
    lastPrompt: asStr(pick(o, 'last_prompt', 'lastPrompt')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
  };
}

export function lastPromptToJSON(v: LastPrompt): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.lastPrompt != null) d['last_prompt'] = v.lastPrompt;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  return d;
}

export function parseProgress(o: Record<string, unknown>): Progress {
  return {
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    cwd: asStr(pick(o, 'cwd')),
    data: parseData(pick(o, 'data')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    forkedFrom: (() => { const _o = asObj(pick(o, 'forked_from', 'forkedFrom')); return _o ? parseForkedFrom(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    parentToolUseId: asStr(pick(o, 'parent_tool_use_id', 'parentToolUseID', 'parentToolUseId')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
    timestamp: asStr(pick(o, 'timestamp')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function progressToJSON(v: Progress): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.data != null) d['data'] = dataToJSON(v.data);
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.forkedFrom != null) d['forked_from'] = forkedFromToJSON(v.forkedFrom);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.parentToolUseId != null) d['parent_tool_use_id'] = v.parentToolUseId;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.teamName != null) d['team_name'] = v.teamName;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseData(json: unknown): Data {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as DataUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'agent_progress': return { type: 'agent_progress', ...parseAgentProgress(o) } as DataAgentProgress;
    case 'bash_progress': return { type: 'bash_progress', ...parseBashProgress(o) } as DataBashProgress;
    case 'hook_progress': return { type: 'hook_progress', ...parseHookProgress(o) } as DataHookProgress;
    case 'query_update': return { type: 'query_update', ...parseQueryUpdate(o) } as DataQueryUpdate;
    case 'search_results_received': return { type: 'search_results_received', ...parseSearchResultsReceived(o) } as DataSearchResultsReceived;
    case 'waiting_for_task': return { type: 'waiting_for_task', ...parseWaitingForTask(o) } as DataWaitingForTask;
    default: return { type: _tag ?? 'unknown', ...o } as DataUnknown;
  }
}

export function dataToJSON(v: Data): Record<string, unknown> {
  switch (v.type) {
    case 'agent_progress': return { type: 'agent_progress', ...agentProgressToJSON(v as any) };
    case 'bash_progress': return { type: 'bash_progress', ...bashProgressToJSON(v as any) };
    case 'hook_progress': return { type: 'hook_progress', ...hookProgressToJSON(v as any) };
    case 'query_update': return { type: 'query_update', ...queryUpdateToJSON(v as any) };
    case 'search_results_received': return { type: 'search_results_received', ...searchResultsReceivedToJSON(v as any) };
    case 'waiting_for_task': return { type: 'waiting_for_task', ...waitingForTaskToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isDataAgentProgress = (v: Data): v is DataAgentProgress => v.type === 'agent_progress';
export const isDataBashProgress = (v: Data): v is DataBashProgress => v.type === 'bash_progress';
export const isDataHookProgress = (v: Data): v is DataHookProgress => v.type === 'hook_progress';
export const isDataQueryUpdate = (v: Data): v is DataQueryUpdate => v.type === 'query_update';
export const isDataSearchResultsReceived = (v: Data): v is DataSearchResultsReceived => v.type === 'search_results_received';
export const isDataWaitingForTask = (v: Data): v is DataWaitingForTask => v.type === 'waiting_for_task';

export function parseAgentProgress(o: Record<string, unknown>): AgentProgress {
  return {
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    message: parseAgentProgressMessage(pick(o, 'message')),
    normalizedMessages: asArr(pick(o, 'normalized_messages', 'normalizedMessages')),
    prompt: asStr(pick(o, 'prompt')),
    resume: asStr(pick(o, 'resume')),
  };
}

export function agentProgressToJSON(v: AgentProgress): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.message != null) d['message'] = agentProgressMessageToJSON(v.message);
  if (v.normalizedMessages != null) d['normalized_messages'] = v.normalizedMessages;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.resume != null) d['resume'] = v.resume;
  return d;
}

export function parseAgentProgressMessage(json: unknown): AgentProgressMessage {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as AgentProgressMessageUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'assistant': return { type: 'assistant', ...parseMessageAssistant(o) } as AgentProgressMessageAssistant;
    case 'user': return { type: 'user', ...parseMessageUser(o) } as AgentProgressMessageUser;
    default: return { type: _tag ?? 'unknown', ...o } as AgentProgressMessageUnknown;
  }
}

export function agentProgressMessageToJSON(v: AgentProgressMessage): Record<string, unknown> {
  switch (v.type) {
    case 'assistant': return { type: 'assistant', ...messageAssistantToJSON(v as any) };
    case 'user': return { type: 'user', ...messageUserToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isAgentProgressMessageAssistant = (v: AgentProgressMessage): v is AgentProgressMessageAssistant => v.type === 'assistant';
export const isAgentProgressMessageUser = (v: AgentProgressMessage): v is AgentProgressMessageUser => v.type === 'user';

export function parseMessageAssistant(o: Record<string, unknown>): MessageAssistant {
  return {
    message: (() => { const _o = asObj(pick(o, 'message')); return _o ? parseMessageAssistantMessage(_o) : undefined; })(),
    requestId: asStr(pick(o, 'request_id', 'requestID', 'requestId')),
    timestamp: asStr(pick(o, 'timestamp')),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function messageAssistantToJSON(v: MessageAssistant): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.message != null) d['message'] = messageAssistantMessageToJSON(v.message);
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseMessageAssistantMessage(o: Record<string, unknown>): MessageAssistantMessage {
  return {
    content: asArr(pick(o, 'content'))?.map(v => parseMessageAssistantMessageContent(v)),
    contextManagement: pick(o, 'context_management', 'contextManagement'),
    id: asStr(pick(o, 'id')),
    model: asStr(pick(o, 'model')),
    role: asStr(pick(o, 'role')),
    stopReason: asStr(pick(o, 'stop_reason', 'stopReason')),
    stopSequence: pick(o, 'stop_sequence', 'stopSequence'),
    type: asStr(pick(o, 'type')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseAssistantUsage(_o) : undefined; })(),
  };
}

export function messageAssistantMessageToJSON(v: MessageAssistantMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content.map(v => messageAssistantMessageContentToJSON(v));
  if (v.contextManagement != null) d['context_management'] = v.contextManagement;
  if (v.id != null) d['id'] = v.id;
  if (v.model != null) d['model'] = v.model;
  if (v.role != null) d['role'] = v.role;
  if (v.stopReason != null) d['stop_reason'] = v.stopReason;
  if (v.stopSequence != null) d['stop_sequence'] = v.stopSequence;
  if (v.type != null) d['type'] = v.type;
  if (v.usage != null) d['usage'] = assistantUsageToJSON(v.usage);
  return d;
}

export function parseMessageAssistantMessageContent(json: unknown): MessageAssistantMessageContent {
  const o = asObj(json);
  if (!o) return { name: 'unknown' } as MessageAssistantMessageContentUnknown;
  const _tag = asStr(o.name);
  switch (_tag) {
    case 'Bash': return { name: 'Bash', ...parseContentBash(o) } as MessageAssistantMessageContentBash;
    case 'Edit': return { name: 'Edit', ...parseContentEdit(o) } as MessageAssistantMessageContentEdit;
    case 'Glob': return { name: 'Glob', ...parseContentGlob(o) } as MessageAssistantMessageContentGlob;
    case 'Grep': return { name: 'Grep', ...parseContentGrep(o) } as MessageAssistantMessageContentGrep;
    case 'Read': return { name: 'Read', ...parseContentRead(o) } as MessageAssistantMessageContentRead;
    case 'ToolSearch': return { name: 'ToolSearch', ...parseContentToolSearch(o) } as MessageAssistantMessageContentToolSearch;
    case 'WebFetch': return { name: 'WebFetch', ...parseContentWebFetch(o) } as MessageAssistantMessageContentWebFetch;
    case 'WebSearch': return { name: 'WebSearch', ...parseContentWebSearch(o) } as MessageAssistantMessageContentWebSearch;
    case 'Write': return { name: 'Write', ...parseContentWrite(o) } as MessageAssistantMessageContentWrite;
    default: return { name: _tag ?? 'unknown', ...o } as MessageAssistantMessageContentUnknown;
  }
}

export function messageAssistantMessageContentToJSON(v: MessageAssistantMessageContent): Record<string, unknown> {
  switch (v.name) {
    case 'Bash': return { name: 'Bash', ...contentBashToJSON(v as any) };
    case 'Edit': return { name: 'Edit', ...contentEditToJSON(v as any) };
    case 'Glob': return { name: 'Glob', ...contentGlobToJSON(v as any) };
    case 'Grep': return { name: 'Grep', ...contentGrepToJSON(v as any) };
    case 'Read': return { name: 'Read', ...contentReadToJSON(v as any) };
    case 'ToolSearch': return { name: 'ToolSearch', ...contentToolSearchToJSON(v as any) };
    case 'WebFetch': return { name: 'WebFetch', ...contentWebFetchToJSON(v as any) };
    case 'WebSearch': return { name: 'WebSearch', ...contentWebSearchToJSON(v as any) };
    case 'Write': return { name: 'Write', ...contentWriteToJSON(v as any) };
    default: { const { name: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isMessageAssistantMessageContentBash = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentBash => v.name === 'Bash';
export const isMessageAssistantMessageContentEdit = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentEdit => v.name === 'Edit';
export const isMessageAssistantMessageContentGlob = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentGlob => v.name === 'Glob';
export const isMessageAssistantMessageContentGrep = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentGrep => v.name === 'Grep';
export const isMessageAssistantMessageContentRead = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentRead => v.name === 'Read';
export const isMessageAssistantMessageContentToolSearch = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentToolSearch => v.name === 'ToolSearch';
export const isMessageAssistantMessageContentWebFetch = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentWebFetch => v.name === 'WebFetch';
export const isMessageAssistantMessageContentWebSearch = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentWebSearch => v.name === 'WebSearch';
export const isMessageAssistantMessageContentWrite = (v: MessageAssistantMessageContent): v is MessageAssistantMessageContentWrite => v.name === 'Write';

export function parseContentBash(o: Record<string, unknown>): ContentBash {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseContentBashInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentBashToJSON(v: ContentBash): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = contentBashInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentBashInput(o: Record<string, unknown>): ContentBashInput {
  return {
    command: asStr(pick(o, 'command')),
    context: asNum(pick(o, 'context')),
    description: asStr(pick(o, 'description')),
    outputMode: asStr(pick(o, 'output_mode', 'outputMode')),
    path: asStr(pick(o, 'path')),
    pattern: asStr(pick(o, 'pattern')),
    timeout: asNum(pick(o, 'timeout')),
  };
}

export function contentBashInputToJSON(v: ContentBashInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.command != null) d['command'] = v.command;
  if (v.context != null) d['context'] = v.context;
  if (v.description != null) d['description'] = v.description;
  if (v.outputMode != null) d['output_mode'] = v.outputMode;
  if (v.path != null) d['path'] = v.path;
  if (v.pattern != null) d['pattern'] = v.pattern;
  if (v.timeout != null) d['timeout'] = v.timeout;
  return d;
}

export function parseContentEdit(o: Record<string, unknown>): ContentEdit {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseEditInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentEditToJSON(v: ContentEdit): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = editInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentGlob(o: Record<string, unknown>): ContentGlob {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseGlobInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentGlobToJSON(v: ContentGlob): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = globInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentGrep(o: Record<string, unknown>): ContentGrep {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseContentGrepInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentGrepToJSON(v: ContentGrep): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = contentGrepInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentGrepInput(o: Record<string, unknown>): ContentGrepInput {
  return {
    A: asNum(pick(o, '-a', '-A', 'A')),
    C: asNum(pick(o, '-c', '-C', 'C')),
    I: asBool(pick(o, '-i', 'I')),
    N: asBool(pick(o, '-n', 'N')),
    context: asNum(pick(o, 'context')),
    glob: asStr(pick(o, 'glob')),
    headLimit: asNum(pick(o, 'head_limit', 'headLimit')),
    outputMode: asStr(pick(o, 'output_mode', 'outputMode')),
    path: asStr(pick(o, 'path')),
    pattern: asStr(pick(o, 'pattern')),
    type: asStr(pick(o, 'type')),
  };
}

export function contentGrepInputToJSON(v: ContentGrepInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.A != null) d['-a'] = v.A;
  if (v.C != null) d['-c'] = v.C;
  if (v.I != null) d['-i'] = v.I;
  if (v.N != null) d['-n'] = v.N;
  if (v.context != null) d['context'] = v.context;
  if (v.glob != null) d['glob'] = v.glob;
  if (v.headLimit != null) d['head_limit'] = v.headLimit;
  if (v.outputMode != null) d['output_mode'] = v.outputMode;
  if (v.path != null) d['path'] = v.path;
  if (v.pattern != null) d['pattern'] = v.pattern;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentRead(o: Record<string, unknown>): ContentRead {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseContentReadInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentReadToJSON(v: ContentRead): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = contentReadInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentReadInput(o: Record<string, unknown>): ContentReadInput {
  return {
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    limit: asNum(pick(o, 'limit')),
    offset: parseContentReadInputOffset(pick(o, 'offset')),
  };
}

export function contentReadInputToJSON(v: ContentReadInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.limit != null) d['limit'] = v.limit;
  if (v.offset != null) d['offset'] = contentReadInputOffsetToJSON(v.offset);
  return d;
}

export function parseContentReadInputOffset(json: unknown): ContentReadInputOffset {
  if (typeof json === 'string') return json;
  if (typeof json === 'number') return json;
  return json as ContentReadInputOffset;
}

export function contentReadInputOffsetToJSON(v: ContentReadInputOffset): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return v;
  return v;
}

export function parseContentToolSearch(o: Record<string, unknown>): ContentToolSearch {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseToolSearchInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentToolSearchToJSON(v: ContentToolSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = toolSearchInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentWebFetch(o: Record<string, unknown>): ContentWebFetch {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseContentWebFetchInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentWebFetchToJSON(v: ContentWebFetch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = contentWebFetchInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentWebFetchInput(o: Record<string, unknown>): ContentWebFetchInput {
  return {
    prompt: asStr(pick(o, 'prompt')),
    url: asStr(pick(o, 'url')),
  };
}

export function contentWebFetchInputToJSON(v: ContentWebFetchInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.url != null) d['url'] = v.url;
  return d;
}

export function parseContentWebSearch(o: Record<string, unknown>): ContentWebSearch {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseContentWebSearchInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentWebSearchToJSON(v: ContentWebSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = contentWebSearchInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseContentWebSearchInput(o: Record<string, unknown>): ContentWebSearchInput {
  return {
    allowedDomains: asArr(pick(o, 'allowed_domains', 'allowedDomains'))?.map(v => asStr(v)!),
    query: asStr(pick(o, 'query')),
  };
}

export function contentWebSearchInputToJSON(v: ContentWebSearchInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.allowedDomains != null) d['allowed_domains'] = v.allowedDomains;
  if (v.query != null) d['query'] = v.query;
  return d;
}

export function parseContentWrite(o: Record<string, unknown>): ContentWrite {
  return {
    caller: (() => { const _o = asObj(pick(o, 'caller')); return _o ? parseCaller(_o) : undefined; })(),
    id: asStr(pick(o, 'id')),
    input: (() => { const _o = asObj(pick(o, 'input')); return _o ? parseWriteInput(_o) : undefined; })(),
    type: asStr(pick(o, 'type')),
  };
}

export function contentWriteToJSON(v: ContentWrite): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.caller != null) d['caller'] = callerToJSON(v.caller);
  if (v.id != null) d['id'] = v.id;
  if (v.input != null) d['input'] = writeInputToJSON(v.input);
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseMessageUser(o: Record<string, unknown>): MessageUser {
  return {
    message: (() => { const _o = asObj(pick(o, 'message')); return _o ? parseMessageUserMessage(_o) : undefined; })(),
    timestamp: asStr(pick(o, 'timestamp')),
    toolUseResult: asStr(pick(o, 'tool_use_result', 'toolUseResult')),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function messageUserToJSON(v: MessageUser): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.message != null) d['message'] = messageUserMessageToJSON(v.message);
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.toolUseResult != null) d['tool_use_result'] = v.toolUseResult;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseMessageUserMessage(o: Record<string, unknown>): MessageUserMessage {
  return {
    content: asArr(pick(o, 'content'))?.map(v => parseMessageUserMessageContent(v)),
    role: asStr(pick(o, 'role')),
  };
}

export function messageUserMessageToJSON(v: MessageUserMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content.map(v => messageUserMessageContentToJSON(v));
  if (v.role != null) d['role'] = v.role;
  return d;
}

export function parseMessageUserMessageContent(json: unknown): MessageUserMessageContent {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as MessageUserMessageContentUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'text': return { type: 'text', ...parseText(o) } as MessageUserMessageContentText;
    case 'tool_result': return { type: 'tool_result', ...parseContentToolResult(o) } as MessageUserMessageContentToolResult;
    default: return { type: _tag ?? 'unknown', ...o } as MessageUserMessageContentUnknown;
  }
}

export function messageUserMessageContentToJSON(v: MessageUserMessageContent): Record<string, unknown> {
  switch (v.type) {
    case 'text': return { type: 'text', ...textToJSON(v as any) };
    case 'tool_result': return { type: 'tool_result', ...contentToolResultToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isMessageUserMessageContentText = (v: MessageUserMessageContent): v is MessageUserMessageContentText => v.type === 'text';
export const isMessageUserMessageContentToolResult = (v: MessageUserMessageContent): v is MessageUserMessageContentToolResult => v.type === 'tool_result';

export function parseContentToolResult(o: Record<string, unknown>): ContentToolResult {
  return {
    content: parseContentToolResultContent(pick(o, 'content')),
    isError: asBool(pick(o, 'is_error', 'isError')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
  };
}

export function contentToolResultToJSON(v: ContentToolResult): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = contentToolResultContentToJSON(v.content);
  if (v.isError != null) d['is_error'] = v.isError;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  return d;
}

export function parseContentToolResultContent(json: unknown): ContentToolResultContent {
  if (typeof json === 'string') return json;
  if (Array.isArray(json)) return asArr(json)?.map(v => { const _o = asObj(v); return _o ? parseContentToolResultContentItem(_o) : undefined; }).filter((v): v is ContentToolResultContentItem => v !== undefined);
  return json as ContentToolResultContent;
}

export function contentToolResultContentToJSON(v: ContentToolResultContent): unknown {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v;
  return v;
}

export function parseContentToolResultContentItem(o: Record<string, unknown>): ContentToolResultContentItem {
  return {
    toolName: asStr(pick(o, 'tool_name', 'toolName')),
    type: asStr(pick(o, 'type')),
  };
}

export function contentToolResultContentItemToJSON(v: ContentToolResultContentItem): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.toolName != null) d['tool_name'] = v.toolName;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseBashProgress(o: Record<string, unknown>): BashProgress {
  return {
    elapsedTimeSeconds: asNum(pick(o, 'elapsed_time_seconds', 'elapsedTimeSeconds')),
    fullOutput: asStr(pick(o, 'full_output', 'fullOutput')),
    output: asStr(pick(o, 'output')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    timeoutMs: asNum(pick(o, 'timeout_ms', 'timeoutMs')),
    totalBytes: asNum(pick(o, 'total_bytes', 'totalBytes')),
    totalLines: asNum(pick(o, 'total_lines', 'totalLines')),
  };
}

export function bashProgressToJSON(v: BashProgress): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.elapsedTimeSeconds != null) d['elapsed_time_seconds'] = v.elapsedTimeSeconds;
  if (v.fullOutput != null) d['full_output'] = v.fullOutput;
  if (v.output != null) d['output'] = v.output;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.timeoutMs != null) d['timeout_ms'] = v.timeoutMs;
  if (v.totalBytes != null) d['total_bytes'] = v.totalBytes;
  if (v.totalLines != null) d['total_lines'] = v.totalLines;
  return d;
}

export function parseHookProgress(o: Record<string, unknown>): HookProgress {
  return {
    command: asStr(pick(o, 'command')),
    hookEvent: asStr(pick(o, 'hook_event', 'hookEvent')),
    hookName: asStr(pick(o, 'hook_name', 'hookName')),
  };
}

export function hookProgressToJSON(v: HookProgress): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.command != null) d['command'] = v.command;
  if (v.hookEvent != null) d['hook_event'] = v.hookEvent;
  if (v.hookName != null) d['hook_name'] = v.hookName;
  return d;
}

export function parseQueryUpdate(o: Record<string, unknown>): QueryUpdate {
  return {
    query: asStr(pick(o, 'query')),
  };
}

export function queryUpdateToJSON(v: QueryUpdate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.query != null) d['query'] = v.query;
  return d;
}

export function parseSearchResultsReceived(o: Record<string, unknown>): SearchResultsReceived {
  return {
    query: asStr(pick(o, 'query')),
    resultCount: asNum(pick(o, 'result_count', 'resultCount')),
  };
}

export function searchResultsReceivedToJSON(v: SearchResultsReceived): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.query != null) d['query'] = v.query;
  if (v.resultCount != null) d['result_count'] = v.resultCount;
  return d;
}

export function parseWaitingForTask(o: Record<string, unknown>): WaitingForTask {
  return {
    taskDescription: asStr(pick(o, 'task_description', 'taskDescription')),
    taskType: asStr(pick(o, 'task_type', 'taskType')),
  };
}

export function waitingForTaskToJSON(v: WaitingForTask): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.taskDescription != null) d['task_description'] = v.taskDescription;
  if (v.taskType != null) d['task_type'] = v.taskType;
  return d;
}

export function parsePromptSuggestion(o: Record<string, unknown>): PromptSuggestion {
  return {
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    suggestion: asStr(pick(o, 'suggestion')),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function promptSuggestionToJSON(v: PromptSuggestion): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.suggestion != null) d['suggestion'] = v.suggestion;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseQueueOperation(json: unknown): QueueOperation {
  const o = asObj(json);
  if (!o) return { operation: 'unknown' } as QueueOperationUnknown;
  const _tag = asStr(o.operation);
  switch (_tag) {
    case 'dequeue': return { operation: 'dequeue', ...parseDequeue(o) } as QueueOperationDequeue;
    case 'enqueue': return { operation: 'enqueue', ...parseEnqueue(o) } as QueueOperationEnqueue;
    case 'remove': return { operation: 'remove', ...parseDequeue(o) } as QueueOperationRemove;
    default: return { operation: _tag ?? 'unknown', ...o } as QueueOperationUnknown;
  }
}

export function queueOperationToJSON(v: QueueOperation): Record<string, unknown> {
  switch (v.operation) {
    case 'dequeue': return { operation: 'dequeue', ...dequeueToJSON(v as any) };
    case 'enqueue': return { operation: 'enqueue', ...enqueueToJSON(v as any) };
    case 'remove': return { operation: 'remove', ...dequeueToJSON(v as any) };
    default: { const { operation: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isQueueOperationDequeue = (v: QueueOperation): v is QueueOperationDequeue => v.operation === 'dequeue';
export const isQueueOperationEnqueue = (v: QueueOperation): v is QueueOperationEnqueue => v.operation === 'enqueue';
export const isQueueOperationRemove = (v: QueueOperation): v is QueueOperationRemove => v.operation === 'remove';

export function parseDequeue(o: Record<string, unknown>): Dequeue {
  return {
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    timestamp: asStr(pick(o, 'timestamp')),
  };
}

export function dequeueToJSON(v: Dequeue): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  return d;
}

export function parseEnqueue(o: Record<string, unknown>): Enqueue {
  return {
    content: asStr(pick(o, 'content')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    timestamp: asStr(pick(o, 'timestamp')),
  };
}

export function enqueueToJSON(v: Enqueue): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  return d;
}

export function parseRateLimitEvent(o: Record<string, unknown>): RateLimitEvent {
  return {
    rateLimitInfo: (() => { const _o = asObj(pick(o, 'rate_limit_info', 'rateLimitInfo')); return _o ? parseRateLimitInfo(_o) : undefined; })(),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function rateLimitEventToJSON(v: RateLimitEvent): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.rateLimitInfo != null) d['rate_limit_info'] = rateLimitInfoToJSON(v.rateLimitInfo);
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseRateLimitInfo(o: Record<string, unknown>): RateLimitInfo {
  return {
    isUsingOverage: asBool(pick(o, 'is_using_overage', 'isUsingOverage')),
    overageDisabledReason: asStr(pick(o, 'overage_disabled_reason', 'overageDisabledReason')),
    overageStatus: asStr(pick(o, 'overage_status', 'overageStatus')),
    rateLimitType: asStr(pick(o, 'rate_limit_type', 'rateLimitType')),
    resetsAt: asNum(pick(o, 'resets_at', 'resetsAt')),
    status: asStr(pick(o, 'status')),
  };
}

export function rateLimitInfoToJSON(v: RateLimitInfo): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.isUsingOverage != null) d['is_using_overage'] = v.isUsingOverage;
  if (v.overageDisabledReason != null) d['overage_disabled_reason'] = v.overageDisabledReason;
  if (v.overageStatus != null) d['overage_status'] = v.overageStatus;
  if (v.rateLimitType != null) d['rate_limit_type'] = v.rateLimitType;
  if (v.resetsAt != null) d['resets_at'] = v.resetsAt;
  if (v.status != null) d['status'] = v.status;
  return d;
}

export function parseResult(json: unknown): Result {
  const o = asObj(json);
  if (!o) return { subtype: 'unknown' } as ResultUnknown;
  const _tag = asStr(o.subtype);
  switch (_tag) {
    case 'error_during_execution': return { subtype: 'error_during_execution', ...parseErrorDuringExecution(o) } as ResultErrorDuringExecution;
    case 'success': return { subtype: 'success', ...parseSuccess(o) } as ResultSuccess;
    default: return { subtype: _tag ?? 'unknown', ...o } as ResultUnknown;
  }
}

export function resultToJSON(v: Result): Record<string, unknown> {
  switch (v.subtype) {
    case 'error_during_execution': return { subtype: 'error_during_execution', ...errorDuringExecutionToJSON(v as any) };
    case 'success': return { subtype: 'success', ...successToJSON(v as any) };
    default: { const { subtype: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isResultErrorDuringExecution = (v: Result): v is ResultErrorDuringExecution => v.subtype === 'error_during_execution';
export const isResultSuccess = (v: Result): v is ResultSuccess => v.subtype === 'success';

export function parseErrorDuringExecution(o: Record<string, unknown>): ErrorDuringExecution {
  return {
    durationApiMs: asNum(pick(o, 'duration_api_ms', 'durationApiMs')),
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    errors: asArr(pick(o, 'errors'))?.map(v => asStr(v)!),
    fastModeState: asStr(pick(o, 'fast_mode_state', 'fastModeState')),
    isError: asBool(pick(o, 'is_error', 'isError')),
    modelUsage: (() => { const _o = asObj(pick(o, 'model_usage', 'modelUsage')); if (!_o) return undefined; const r: Record<string, ModelUsageValue> = {}; for (const [k, v] of Object.entries(_o)) { const _ov = asObj(v); if (_ov) r[k] = parseModelUsageValue(_ov); }; return r; })(),
    numTurns: asNum(pick(o, 'num_turns', 'numTurns')),
    permissionDenials: asArr(pick(o, 'permission_denials', 'permissionDenials'))?.map(v => { const _o = asObj(v); return _o ? parseErrorDuringExecutionPermissionDenials(_o) : undefined; }).filter((v): v is ErrorDuringExecutionPermissionDenials => v !== undefined),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    stopReason: asStr(pick(o, 'stop_reason', 'stopReason')),
    totalCostUsd: asNum(pick(o, 'total_cost_usd', 'totalCostUsd')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseErrorDuringExecutionUsage(_o) : undefined; })(),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function errorDuringExecutionToJSON(v: ErrorDuringExecution): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durationApiMs != null) d['duration_api_ms'] = v.durationApiMs;
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.errors != null) d['errors'] = v.errors;
  if (v.fastModeState != null) d['fast_mode_state'] = v.fastModeState;
  if (v.isError != null) d['is_error'] = v.isError;
  if (v.modelUsage != null) d['model_usage'] = Object.fromEntries(Object.entries(v.modelUsage).map(([k, v]) => [k, modelUsageValueToJSON(v)]));
  if (v.numTurns != null) d['num_turns'] = v.numTurns;
  if (v.permissionDenials != null) d['permission_denials'] = v.permissionDenials.map(v => errorDuringExecutionPermissionDenialsToJSON(v));
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.stopReason != null) d['stop_reason'] = v.stopReason;
  if (v.totalCostUsd != null) d['total_cost_usd'] = v.totalCostUsd;
  if (v.usage != null) d['usage'] = errorDuringExecutionUsageToJSON(v.usage);
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseModelUsageValue(o: Record<string, unknown>): ModelUsageValue {
  return {
    cacheCreationInputTokens: asNum(pick(o, 'cache_creation_input_tokens', 'cacheCreationInputTokens')),
    cacheReadInputTokens: asNum(pick(o, 'cache_read_input_tokens', 'cacheReadInputTokens')),
    contextWindow: asNum(pick(o, 'context_window', 'contextWindow')),
    costUsd: asNum(pick(o, 'cost_usd', 'costUSD', 'costUsd')),
    inputTokens: asNum(pick(o, 'input_tokens', 'inputTokens')),
    maxOutputTokens: asNum(pick(o, 'max_output_tokens', 'maxOutputTokens')),
    outputTokens: asNum(pick(o, 'output_tokens', 'outputTokens')),
    webSearchRequests: asNum(pick(o, 'web_search_requests', 'webSearchRequests')),
  };
}

export function modelUsageValueToJSON(v: ModelUsageValue): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cacheCreationInputTokens != null) d['cache_creation_input_tokens'] = v.cacheCreationInputTokens;
  if (v.cacheReadInputTokens != null) d['cache_read_input_tokens'] = v.cacheReadInputTokens;
  if (v.contextWindow != null) d['context_window'] = v.contextWindow;
  if (v.costUsd != null) d['cost_usd'] = v.costUsd;
  if (v.inputTokens != null) d['input_tokens'] = v.inputTokens;
  if (v.maxOutputTokens != null) d['max_output_tokens'] = v.maxOutputTokens;
  if (v.outputTokens != null) d['output_tokens'] = v.outputTokens;
  if (v.webSearchRequests != null) d['web_search_requests'] = v.webSearchRequests;
  return d;
}

export function parseErrorDuringExecutionPermissionDenials(o: Record<string, unknown>): ErrorDuringExecutionPermissionDenials {
  return {
    toolInput: (() => { const _o = asObj(pick(o, 'tool_input', 'toolInput')); return _o ? parseErrorDuringExecutionPermissionDenialsToolInput(_o) : undefined; })(),
    toolName: asStr(pick(o, 'tool_name', 'toolName')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
  };
}

export function errorDuringExecutionPermissionDenialsToJSON(v: ErrorDuringExecutionPermissionDenials): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.toolInput != null) d['tool_input'] = errorDuringExecutionPermissionDenialsToolInputToJSON(v.toolInput);
  if (v.toolName != null) d['tool_name'] = v.toolName;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  return d;
}

export function parseErrorDuringExecutionPermissionDenialsToolInput(o: Record<string, unknown>): ErrorDuringExecutionPermissionDenialsToolInput {
  return {
    allowedPrompts: asArr(pick(o, 'allowed_prompts', 'allowedPrompts'))?.map(v => { const _o = asObj(v); return _o ? parseAllowedPrompts(_o) : undefined; }).filter((v): v is AllowedPrompts => v !== undefined),
    command: asStr(pick(o, 'command')),
    description: asStr(pick(o, 'description')),
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    newString: asStr(pick(o, 'new_string', 'newString')),
    oldString: asStr(pick(o, 'old_string', 'oldString')),
    plan: asStr(pick(o, 'plan')),
    planFilePath: asStr(pick(o, 'plan_file_path', 'planFilePath')),
    replaceAll: asBool(pick(o, 'replace_all', 'replaceAll')),
    timeout: asNum(pick(o, 'timeout')),
  };
}

export function errorDuringExecutionPermissionDenialsToolInputToJSON(v: ErrorDuringExecutionPermissionDenialsToolInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.allowedPrompts != null) d['allowed_prompts'] = v.allowedPrompts.map(v => allowedPromptsToJSON(v));
  if (v.command != null) d['command'] = v.command;
  if (v.description != null) d['description'] = v.description;
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.newString != null) d['new_string'] = v.newString;
  if (v.oldString != null) d['old_string'] = v.oldString;
  if (v.plan != null) d['plan'] = v.plan;
  if (v.planFilePath != null) d['plan_file_path'] = v.planFilePath;
  if (v.replaceAll != null) d['replace_all'] = v.replaceAll;
  if (v.timeout != null) d['timeout'] = v.timeout;
  return d;
}

export function parseErrorDuringExecutionUsage(o: Record<string, unknown>): ErrorDuringExecutionUsage {
  return {
    cacheCreation: (() => { const _o = asObj(pick(o, 'cache_creation', 'cacheCreation')); return _o ? parseCacheCreation(_o) : undefined; })(),
    cacheCreationInputTokens: asNum(pick(o, 'cache_creation_input_tokens', 'cacheCreationInputTokens')),
    cacheReadInputTokens: asNum(pick(o, 'cache_read_input_tokens', 'cacheReadInputTokens')),
    inferenceGeo: asStr(pick(o, 'inference_geo', 'inferenceGeo')),
    inputTokens: asNum(pick(o, 'input_tokens', 'inputTokens')),
    iterations: asArr(pick(o, 'iterations')),
    outputTokens: asNum(pick(o, 'output_tokens', 'outputTokens')),
    serverToolUse: (() => { const _o = asObj(pick(o, 'server_tool_use', 'serverToolUse')); return _o ? parseMessageUsageServerToolUse(_o) : undefined; })(),
    serviceTier: asStr(pick(o, 'service_tier', 'serviceTier')),
    speed: asStr(pick(o, 'speed')),
  };
}

export function errorDuringExecutionUsageToJSON(v: ErrorDuringExecutionUsage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cacheCreation != null) d['cache_creation'] = cacheCreationToJSON(v.cacheCreation);
  if (v.cacheCreationInputTokens != null) d['cache_creation_input_tokens'] = v.cacheCreationInputTokens;
  if (v.cacheReadInputTokens != null) d['cache_read_input_tokens'] = v.cacheReadInputTokens;
  if (v.inferenceGeo != null) d['inference_geo'] = v.inferenceGeo;
  if (v.inputTokens != null) d['input_tokens'] = v.inputTokens;
  if (v.iterations != null) d['iterations'] = v.iterations;
  if (v.outputTokens != null) d['output_tokens'] = v.outputTokens;
  if (v.serverToolUse != null) d['server_tool_use'] = messageUsageServerToolUseToJSON(v.serverToolUse);
  if (v.serviceTier != null) d['service_tier'] = v.serviceTier;
  if (v.speed != null) d['speed'] = v.speed;
  return d;
}

export function parseSuccess(o: Record<string, unknown>): Success {
  return {
    durationApiMs: asNum(pick(o, 'duration_api_ms', 'durationApiMs')),
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    fastModeState: asStr(pick(o, 'fast_mode_state', 'fastModeState')),
    isError: asBool(pick(o, 'is_error', 'isError')),
    modelUsage: (() => { const _o = asObj(pick(o, 'model_usage', 'modelUsage')); if (!_o) return undefined; const r: Record<string, ModelUsageValue> = {}; for (const [k, v] of Object.entries(_o)) { const _ov = asObj(v); if (_ov) r[k] = parseModelUsageValue(_ov); }; return r; })(),
    numTurns: asNum(pick(o, 'num_turns', 'numTurns')),
    permissionDenials: asArr(pick(o, 'permission_denials', 'permissionDenials'))?.map(v => { const _o = asObj(v); return _o ? parseSuccessPermissionDenials(_o) : undefined; }).filter((v): v is SuccessPermissionDenials => v !== undefined),
    result: asStr(pick(o, 'result')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    stopReason: asStr(pick(o, 'stop_reason', 'stopReason')),
    totalCostUsd: asNum(pick(o, 'total_cost_usd', 'totalCostUsd')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseErrorDuringExecutionUsage(_o) : undefined; })(),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function successToJSON(v: Success): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durationApiMs != null) d['duration_api_ms'] = v.durationApiMs;
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.fastModeState != null) d['fast_mode_state'] = v.fastModeState;
  if (v.isError != null) d['is_error'] = v.isError;
  if (v.modelUsage != null) d['model_usage'] = Object.fromEntries(Object.entries(v.modelUsage).map(([k, v]) => [k, modelUsageValueToJSON(v)]));
  if (v.numTurns != null) d['num_turns'] = v.numTurns;
  if (v.permissionDenials != null) d['permission_denials'] = v.permissionDenials.map(v => successPermissionDenialsToJSON(v));
  if (v.result != null) d['result'] = v.result;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.stopReason != null) d['stop_reason'] = v.stopReason;
  if (v.totalCostUsd != null) d['total_cost_usd'] = v.totalCostUsd;
  if (v.usage != null) d['usage'] = errorDuringExecutionUsageToJSON(v.usage);
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseSuccessPermissionDenials(o: Record<string, unknown>): SuccessPermissionDenials {
  return {
    toolInput: (() => { const _o = asObj(pick(o, 'tool_input', 'toolInput')); return _o ? parseSuccessPermissionDenialsToolInput(_o) : undefined; })(),
    toolName: asStr(pick(o, 'tool_name', 'toolName')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
  };
}

export function successPermissionDenialsToJSON(v: SuccessPermissionDenials): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.toolInput != null) d['tool_input'] = successPermissionDenialsToolInputToJSON(v.toolInput);
  if (v.toolName != null) d['tool_name'] = v.toolName;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  return d;
}

export function parseSuccessPermissionDenialsToolInput(o: Record<string, unknown>): SuccessPermissionDenialsToolInput {
  return {
    content: asStr(pick(o, 'content')),
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    plan: asStr(pick(o, 'plan')),
    planFilePath: asStr(pick(o, 'plan_file_path', 'planFilePath')),
  };
}

export function successPermissionDenialsToolInputToJSON(v: SuccessPermissionDenialsToolInput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.plan != null) d['plan'] = v.plan;
  if (v.planFilePath != null) d['plan_file_path'] = v.planFilePath;
  return d;
}

export function parseSystem(json: unknown): System {
  const o = asObj(json);
  if (!o) return { subtype: 'unknown' } as SystemUnknown;
  const _tag = asStr(o.subtype);
  switch (_tag) {
    case 'api_error': return { subtype: 'api_error', ...parseApiError(o) } as SystemApiError;
    case 'compact_boundary': return { subtype: 'compact_boundary', ...parseCompactBoundary(o) } as SystemCompactBoundary;
    case 'informational': return { subtype: 'informational', ...parseInformational(o) } as SystemInformational;
    case 'init': return { subtype: 'init', ...parseInit(o) } as SystemInit;
    case 'local_command': return { subtype: 'local_command', ...parseLocalCommand(o) } as SystemLocalCommand;
    case 'microcompact_boundary': return { subtype: 'microcompact_boundary', ...parseMicrocompactBoundary(o) } as SystemMicrocompactBoundary;
    case 'status': return { subtype: 'status', ...parseStatus(o) } as SystemStatus;
    case 'task_notification': return { subtype: 'task_notification', ...parseTaskNotification(o) } as SystemTaskNotification;
    case 'task_progress': return { subtype: 'task_progress', ...parseTaskProgress(o) } as SystemTaskProgress;
    case 'task_started': return { subtype: 'task_started', ...parseTaskStarted(o) } as SystemTaskStarted;
    case 'turn_duration': return { subtype: 'turn_duration', ...parseTurnDuration(o) } as SystemTurnDuration;
    default: return { subtype: _tag ?? 'unknown', ...o } as SystemUnknown;
  }
}

export function systemToJSON(v: System): Record<string, unknown> {
  switch (v.subtype) {
    case 'api_error': return { subtype: 'api_error', ...apiErrorToJSON(v as any) };
    case 'compact_boundary': return { subtype: 'compact_boundary', ...compactBoundaryToJSON(v as any) };
    case 'informational': return { subtype: 'informational', ...informationalToJSON(v as any) };
    case 'init': return { subtype: 'init', ...initToJSON(v as any) };
    case 'local_command': return { subtype: 'local_command', ...localCommandToJSON(v as any) };
    case 'microcompact_boundary': return { subtype: 'microcompact_boundary', ...microcompactBoundaryToJSON(v as any) };
    case 'status': return { subtype: 'status', ...statusToJSON(v as any) };
    case 'task_notification': return { subtype: 'task_notification', ...taskNotificationToJSON(v as any) };
    case 'task_progress': return { subtype: 'task_progress', ...taskProgressToJSON(v as any) };
    case 'task_started': return { subtype: 'task_started', ...taskStartedToJSON(v as any) };
    case 'turn_duration': return { subtype: 'turn_duration', ...turnDurationToJSON(v as any) };
    default: { const { subtype: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isSystemApiError = (v: System): v is SystemApiError => v.subtype === 'api_error';
export const isSystemCompactBoundary = (v: System): v is SystemCompactBoundary => v.subtype === 'compact_boundary';
export const isSystemInformational = (v: System): v is SystemInformational => v.subtype === 'informational';
export const isSystemInit = (v: System): v is SystemInit => v.subtype === 'init';
export const isSystemLocalCommand = (v: System): v is SystemLocalCommand => v.subtype === 'local_command';
export const isSystemMicrocompactBoundary = (v: System): v is SystemMicrocompactBoundary => v.subtype === 'microcompact_boundary';
export const isSystemStatus = (v: System): v is SystemStatus => v.subtype === 'status';
export const isSystemTaskNotification = (v: System): v is SystemTaskNotification => v.subtype === 'task_notification';
export const isSystemTaskProgress = (v: System): v is SystemTaskProgress => v.subtype === 'task_progress';
export const isSystemTaskStarted = (v: System): v is SystemTaskStarted => v.subtype === 'task_started';
export const isSystemTurnDuration = (v: System): v is SystemTurnDuration => v.subtype === 'turn_duration';

export function parseApiError(o: Record<string, unknown>): ApiError {
  return {
    cause: (() => { const _o = asObj(pick(o, 'cause')); return _o ? parseCause(_o) : undefined; })(),
    cwd: asStr(pick(o, 'cwd')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    error: (() => { const _o = asObj(pick(o, 'error')); return _o ? parseApiErrorError(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    level: asStr(pick(o, 'level')),
    maxRetries: asNum(pick(o, 'max_retries', 'maxRetries')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    retryAttempt: asNum(pick(o, 'retry_attempt', 'retryAttempt')),
    retryInMs: asNum(pick(o, 'retry_in_ms', 'retryInMs')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function apiErrorToJSON(v: ApiError): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cause != null) d['cause'] = causeToJSON(v.cause);
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.error != null) d['error'] = apiErrorErrorToJSON(v.error);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.level != null) d['level'] = v.level;
  if (v.maxRetries != null) d['max_retries'] = v.maxRetries;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.retryAttempt != null) d['retry_attempt'] = v.retryAttempt;
  if (v.retryInMs != null) d['retry_in_ms'] = v.retryInMs;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseCause(o: Record<string, unknown>): Cause {
  return {
    code: asStr(pick(o, 'code')),
    errno: asNum(pick(o, 'errno')),
    path: asStr(pick(o, 'path')),
  };
}

export function causeToJSON(v: Cause): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.code != null) d['code'] = v.code;
  if (v.errno != null) d['errno'] = v.errno;
  if (v.path != null) d['path'] = v.path;
  return d;
}

export function parseApiErrorError(o: Record<string, unknown>): ApiErrorError {
  return {
    cause: (() => { const _o = asObj(pick(o, 'cause')); return _o ? parseCause(_o) : undefined; })(),
    headers: (() => { const _o = asObj(pick(o, 'headers')); return _o ? parseErrorHeaders(_o) : undefined; })(),
    requestId: pick(o, 'request_id', 'requestID', 'requestId'),
    status: asNum(pick(o, 'status')),
  };
}

export function apiErrorErrorToJSON(v: ApiErrorError): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cause != null) d['cause'] = causeToJSON(v.cause);
  if (v.headers != null) d['headers'] = errorHeadersToJSON(v.headers);
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.status != null) d['status'] = v.status;
  return d;
}

export function parseErrorHeaders(o: Record<string, unknown>): ErrorHeaders {
  return {
    cfCacheStatus: asStr(pick(o, 'cf-cache-status', 'cfCacheStatus')),
    cfRay: asStr(pick(o, 'cf-ray', 'cfRay')),
    connection: asStr(pick(o, 'connection')),
    contentLength: asStr(pick(o, 'content-length', 'contentLength')),
    contentSecurityPolicy: asStr(pick(o, 'content-security-policy', 'contentSecurityPolicy')),
    contentType: asStr(pick(o, 'content-type', 'contentType')),
    date: asStr(pick(o, 'date')),
    server: asStr(pick(o, 'server')),
    xRobotsTag: asStr(pick(o, 'x-robots-tag', 'xRobotsTag')),
  };
}

export function errorHeadersToJSON(v: ErrorHeaders): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cfCacheStatus != null) d['cf-cache-status'] = v.cfCacheStatus;
  if (v.cfRay != null) d['cf-ray'] = v.cfRay;
  if (v.connection != null) d['connection'] = v.connection;
  if (v.contentLength != null) d['content-length'] = v.contentLength;
  if (v.contentSecurityPolicy != null) d['content-security-policy'] = v.contentSecurityPolicy;
  if (v.contentType != null) d['content-type'] = v.contentType;
  if (v.date != null) d['date'] = v.date;
  if (v.server != null) d['server'] = v.server;
  if (v.xRobotsTag != null) d['x-robots-tag'] = v.xRobotsTag;
  return d;
}

export function parseCompactBoundary(o: Record<string, unknown>): CompactBoundary {
  return {
    compactMetadata: (() => { const _o = asObj(pick(o, 'compact_metadata', 'compactMetadata')); return _o ? parseCompactMetadata(_o) : undefined; })(),
    content: asStr(pick(o, 'content')),
    cwd: asStr(pick(o, 'cwd')),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    level: asStr(pick(o, 'level')),
    logicalParentUuid: asStr(pick(o, 'logical_parent_uuid', 'logicalParentUuid')),
    parentUuid: pick(o, 'parent_uuid', 'parentUuid'),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function compactBoundaryToJSON(v: CompactBoundary): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.compactMetadata != null) d['compact_metadata'] = compactMetadataToJSON(v.compactMetadata);
  if (v.content != null) d['content'] = v.content;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.level != null) d['level'] = v.level;
  if (v.logicalParentUuid != null) d['logical_parent_uuid'] = v.logicalParentUuid;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseCompactMetadata(o: Record<string, unknown>): CompactMetadata {
  return {
    preCompactDiscoveredTools: asArr(pick(o, 'pre_compact_discovered_tools', 'preCompactDiscoveredTools'))?.map(v => asStr(v)!),
    preTokens: asNum(pick(o, 'pre_tokens', 'preTokens')),
    trigger: asStr(pick(o, 'trigger')),
  };
}

export function compactMetadataToJSON(v: CompactMetadata): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.preCompactDiscoveredTools != null) d['pre_compact_discovered_tools'] = v.preCompactDiscoveredTools;
  if (v.preTokens != null) d['pre_tokens'] = v.preTokens;
  if (v.trigger != null) d['trigger'] = v.trigger;
  return d;
}

export function parseInformational(o: Record<string, unknown>): Informational {
  return {
    content: asStr(pick(o, 'content')),
    cwd: asStr(pick(o, 'cwd')),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    level: asStr(pick(o, 'level')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function informationalToJSON(v: Informational): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.level != null) d['level'] = v.level;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseInit(o: Record<string, unknown>): Init {
  return {
    agents: asArr(pick(o, 'agents'))?.map(v => asStr(v)!),
    apiKeySource: asStr(pick(o, 'api_key_source', 'apiKeySource')),
    claudeCodeVersion: asStr(pick(o, 'claude_code_version', 'claudeCodeVersion')),
    cwd: asStr(pick(o, 'cwd')),
    fastModeState: asStr(pick(o, 'fast_mode_state', 'fastModeState')),
    mcpServers: asArr(pick(o, 'mcp_servers', 'mcpServers'))?.map(v => { const _o = asObj(v); return _o ? parseMcpServers(_o) : undefined; }).filter((v): v is McpServers => v !== undefined),
    model: asStr(pick(o, 'model')),
    outputStyle: asStr(pick(o, 'output_style', 'outputStyle')),
    permissionMode: asStr(pick(o, 'permission_mode', 'permissionMode')),
    plugins: asArr(pick(o, 'plugins'))?.map(v => { const _o = asObj(v); return _o ? parsePlugins(_o) : undefined; }).filter((v): v is Plugins => v !== undefined),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    skills: asArr(pick(o, 'skills'))?.map(v => asStr(v)!),
    slashCommands: asArr(pick(o, 'slash_commands', 'slashCommands'))?.map(v => asStr(v)!),
    tools: asArr(pick(o, 'tools'))?.map(v => asStr(v)!),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function initToJSON(v: Init): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agents != null) d['agents'] = v.agents;
  if (v.apiKeySource != null) d['api_key_source'] = v.apiKeySource;
  if (v.claudeCodeVersion != null) d['claude_code_version'] = v.claudeCodeVersion;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.fastModeState != null) d['fast_mode_state'] = v.fastModeState;
  if (v.mcpServers != null) d['mcp_servers'] = v.mcpServers.map(v => mcpServersToJSON(v));
  if (v.model != null) d['model'] = v.model;
  if (v.outputStyle != null) d['output_style'] = v.outputStyle;
  if (v.permissionMode != null) d['permission_mode'] = v.permissionMode;
  if (v.plugins != null) d['plugins'] = v.plugins.map(v => pluginsToJSON(v));
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.skills != null) d['skills'] = v.skills;
  if (v.slashCommands != null) d['slash_commands'] = v.slashCommands;
  if (v.tools != null) d['tools'] = v.tools;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseMcpServers(o: Record<string, unknown>): McpServers {
  return {
    name: asStr(pick(o, 'name')),
    status: asStr(pick(o, 'status')),
  };
}

export function mcpServersToJSON(v: McpServers): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.name != null) d['name'] = v.name;
  if (v.status != null) d['status'] = v.status;
  return d;
}

export function parsePlugins(o: Record<string, unknown>): Plugins {
  return {
    name: asStr(pick(o, 'name')),
    path: asStr(pick(o, 'path')),
  };
}

export function pluginsToJSON(v: Plugins): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.name != null) d['name'] = v.name;
  if (v.path != null) d['path'] = v.path;
  return d;
}

export function parseLocalCommand(o: Record<string, unknown>): LocalCommand {
  return {
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    content: asStr(pick(o, 'content')),
    cwd: asStr(pick(o, 'cwd')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    forkedFrom: (() => { const _o = asObj(pick(o, 'forked_from', 'forkedFrom')); return _o ? parseForkedFrom(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    level: asStr(pick(o, 'level')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function localCommandToJSON(v: LocalCommand): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.content != null) d['content'] = v.content;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.forkedFrom != null) d['forked_from'] = forkedFromToJSON(v.forkedFrom);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.level != null) d['level'] = v.level;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.teamName != null) d['team_name'] = v.teamName;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseMicrocompactBoundary(o: Record<string, unknown>): MicrocompactBoundary {
  return {
    content: asStr(pick(o, 'content')),
    cwd: asStr(pick(o, 'cwd')),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    level: asStr(pick(o, 'level')),
    microcompactMetadata: (() => { const _o = asObj(pick(o, 'microcompact_metadata', 'microcompactMetadata')); return _o ? parseMicrocompactMetadata(_o) : undefined; })(),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function microcompactBoundaryToJSON(v: MicrocompactBoundary): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.level != null) d['level'] = v.level;
  if (v.microcompactMetadata != null) d['microcompact_metadata'] = microcompactMetadataToJSON(v.microcompactMetadata);
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseMicrocompactMetadata(o: Record<string, unknown>): MicrocompactMetadata {
  return {
    clearedAttachmentUuiDs: asArr(pick(o, 'cleared_attachment_uui_ds', 'clearedAttachmentUUIDs', 'clearedAttachmentUuiDs')),
    compactedToolIds: asArr(pick(o, 'compacted_tool_ids', 'compactedToolIds')),
    preTokens: asNum(pick(o, 'pre_tokens', 'preTokens')),
    tokensSaved: asNum(pick(o, 'tokens_saved', 'tokensSaved')),
    trigger: asStr(pick(o, 'trigger')),
  };
}

export function microcompactMetadataToJSON(v: MicrocompactMetadata): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.clearedAttachmentUuiDs != null) d['cleared_attachment_uui_ds'] = v.clearedAttachmentUuiDs;
  if (v.compactedToolIds != null) d['compacted_tool_ids'] = v.compactedToolIds;
  if (v.preTokens != null) d['pre_tokens'] = v.preTokens;
  if (v.tokensSaved != null) d['tokens_saved'] = v.tokensSaved;
  if (v.trigger != null) d['trigger'] = v.trigger;
  return d;
}

export function parseStatus(o: Record<string, unknown>): Status {
  return {
    permissionMode: asStr(pick(o, 'permission_mode', 'permissionMode')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    status: pick(o, 'status'),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function statusToJSON(v: Status): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.permissionMode != null) d['permission_mode'] = v.permissionMode;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.status != null) d['status'] = v.status;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseTaskNotification(o: Record<string, unknown>): TaskNotification {
  return {
    outputFile: asStr(pick(o, 'output_file', 'outputFile')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    status: asStr(pick(o, 'status')),
    summary: asStr(pick(o, 'summary')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseTaskNotificationUsage(_o) : undefined; })(),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function taskNotificationToJSON(v: TaskNotification): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.outputFile != null) d['output_file'] = v.outputFile;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.status != null) d['status'] = v.status;
  if (v.summary != null) d['summary'] = v.summary;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  if (v.usage != null) d['usage'] = taskNotificationUsageToJSON(v.usage);
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseTaskNotificationUsage(o: Record<string, unknown>): TaskNotificationUsage {
  return {
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    toolUses: asNum(pick(o, 'tool_uses', 'toolUses')),
    totalTokens: asNum(pick(o, 'total_tokens', 'totalTokens')),
  };
}

export function taskNotificationUsageToJSON(v: TaskNotificationUsage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.toolUses != null) d['tool_uses'] = v.toolUses;
  if (v.totalTokens != null) d['total_tokens'] = v.totalTokens;
  return d;
}

export function parseTaskProgress(o: Record<string, unknown>): TaskProgress {
  return {
    description: asStr(pick(o, 'description')),
    lastToolName: asStr(pick(o, 'last_tool_name', 'lastToolName')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseTaskNotificationUsage(_o) : undefined; })(),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function taskProgressToJSON(v: TaskProgress): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.lastToolName != null) d['last_tool_name'] = v.lastToolName;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  if (v.usage != null) d['usage'] = taskNotificationUsageToJSON(v.usage);
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseTaskStarted(o: Record<string, unknown>): TaskStarted {
  return {
    description: asStr(pick(o, 'description')),
    prompt: asStr(pick(o, 'prompt')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    taskType: asStr(pick(o, 'task_type', 'taskType')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
    uuid: asStr(pick(o, 'uuid')),
  };
}

export function taskStartedToJSON(v: TaskStarted): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.taskType != null) d['task_type'] = v.taskType;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  if (v.uuid != null) d['uuid'] = v.uuid;
  return d;
}

export function parseTurnDuration(o: Record<string, unknown>): TurnDuration {
  return {
    cwd: asStr(pick(o, 'cwd')),
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    forkedFrom: (() => { const _o = asObj(pick(o, 'forked_from', 'forkedFrom')); return _o ? parseForkedFrom(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    messageCount: asNum(pick(o, 'message_count', 'messageCount')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
    timestamp: asStr(pick(o, 'timestamp')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function turnDurationToJSON(v: TurnDuration): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.forkedFrom != null) d['forked_from'] = forkedFromToJSON(v.forkedFrom);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.messageCount != null) d['message_count'] = v.messageCount;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.teamName != null) d['team_name'] = v.teamName;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseMessage2User(o: Record<string, unknown>): Message2User {
  return {
    type: 'user',
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    cwd: asStr(pick(o, 'cwd')),
    entrypoint: asStr(pick(o, 'entrypoint')),
    forkedFrom: (() => { const _o = asObj(pick(o, 'forked_from', 'forkedFrom')); return _o ? parseForkedFrom(_o) : undefined; })(),
    gitBranch: asStr(pick(o, 'git_branch', 'gitBranch')),
    imagePasteIds: asArr(pick(o, 'image_paste_ids', 'imagePasteIds'))?.map(v => asNum(v)!),
    isCompactSummary: asBool(pick(o, 'is_compact_summary', 'isCompactSummary')),
    isMeta: asBool(pick(o, 'is_meta', 'isMeta')),
    isSidechain: asBool(pick(o, 'is_sidechain', 'isSidechain')),
    isSynthetic: asBool(pick(o, 'is_synthetic', 'isSynthetic')),
    isVisibleInTranscriptOnly: asBool(pick(o, 'is_visible_in_transcript_only', 'isVisibleInTranscriptOnly')),
    message: (() => { const _o = asObj(pick(o, 'message')); return _o ? parseMessage2UserMessage(_o) : undefined; })(),
    origin: (() => { const _o = asObj(pick(o, 'origin')); return _o ? parseOrigin(_o) : undefined; })(),
    parentToolUseId: asStr(pick(o, 'parent_tool_use_id', 'parentToolUseID', 'parentToolUseId')),
    parentUuid: asStr(pick(o, 'parent_uuid', 'parentUuid')),
    permissionMode: asStr(pick(o, 'permission_mode', 'permissionMode')),
    planContent: asStr(pick(o, 'plan_content', 'planContent')),
    promptId: asStr(pick(o, 'prompt_id', 'promptId')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    slug: asStr(pick(o, 'slug')),
    sourceToolAssistantUuid: asStr(pick(o, 'source_tool_assistant_uuid', 'sourceToolAssistantUUID', 'sourceToolAssistantUuid')),
    sourceToolUseId: asStr(pick(o, 'source_tool_use_id', 'sourceToolUseID', 'sourceToolUseId')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
    timestamp: asStr(pick(o, 'timestamp')),
    todos: asArr(pick(o, 'todos')),
    toolUseResult: parseToolUseResult(pick(o, 'tool_use_result', 'toolUseResult')),
    userType: asStr(pick(o, 'user_type', 'userType')),
    uuid: asStr(pick(o, 'uuid')),
    version: asStr(pick(o, 'version')),
  };
}

export function message2UserToJSON(v: Message2User): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  d['type'] = 'user';
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.cwd != null) d['cwd'] = v.cwd;
  if (v.entrypoint != null) d['entrypoint'] = v.entrypoint;
  if (v.forkedFrom != null) d['forked_from'] = forkedFromToJSON(v.forkedFrom);
  if (v.gitBranch != null) d['git_branch'] = v.gitBranch;
  if (v.imagePasteIds != null) d['image_paste_ids'] = v.imagePasteIds;
  if (v.isCompactSummary != null) d['is_compact_summary'] = v.isCompactSummary;
  if (v.isMeta != null) d['is_meta'] = v.isMeta;
  if (v.isSidechain != null) d['is_sidechain'] = v.isSidechain;
  if (v.isSynthetic != null) d['is_synthetic'] = v.isSynthetic;
  if (v.isVisibleInTranscriptOnly != null) d['is_visible_in_transcript_only'] = v.isVisibleInTranscriptOnly;
  if (v.message != null) d['message'] = message2UserMessageToJSON(v.message);
  if (v.origin != null) d['origin'] = originToJSON(v.origin);
  if (v.parentToolUseId != null) d['parent_tool_use_id'] = v.parentToolUseId;
  if (v.parentUuid != null) d['parent_uuid'] = v.parentUuid;
  if (v.permissionMode != null) d['permission_mode'] = v.permissionMode;
  if (v.planContent != null) d['plan_content'] = v.planContent;
  if (v.promptId != null) d['prompt_id'] = v.promptId;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.slug != null) d['slug'] = v.slug;
  if (v.sourceToolAssistantUuid != null) d['source_tool_assistant_uuid'] = v.sourceToolAssistantUuid;
  if (v.sourceToolUseId != null) d['source_tool_use_id'] = v.sourceToolUseId;
  if (v.teamName != null) d['team_name'] = v.teamName;
  if (v.timestamp != null) d['timestamp'] = v.timestamp;
  if (v.todos != null) d['todos'] = v.todos;
  if (v.toolUseResult != null) d['tool_use_result'] = toolUseResultToJSON(v.toolUseResult);
  if (v.userType != null) d['user_type'] = v.userType;
  if (v.uuid != null) d['uuid'] = v.uuid;
  if (v.version != null) d['version'] = v.version;
  return d;
}

export function parseMessage2UserMessage(o: Record<string, unknown>): Message2UserMessage {
  return {
    content: parseMessage2UserMessageContent(pick(o, 'content')),
    role: asStr(pick(o, 'role')),
  };
}

export function message2UserMessageToJSON(v: Message2UserMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = message2UserMessageContentToJSON(v.content);
  if (v.role != null) d['role'] = v.role;
  return d;
}

export function parseMessage2UserMessageContent(json: unknown): Message2UserMessageContent {
  if (typeof json === 'string') return json;
  if (Array.isArray(json)) return asArr(json)?.map(v => parseMessageContentItem(v));
  return json as Message2UserMessageContent;
}

export function message2UserMessageContentToJSON(v: Message2UserMessageContent): unknown {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v;
  return v;
}

export function parseMessageContentItem(json: unknown): MessageContentItem {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as MessageContentItemUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'image': return { type: 'image', ...parseImage(o) } as MessageContentItemImage;
    case 'text': return { type: 'text', ...parseText(o) } as MessageContentItemText;
    case 'tool_result': return { type: 'tool_result', ...parseItemToolResult(o) } as MessageContentItemToolResult;
    default: return { type: _tag ?? 'unknown', ...o } as MessageContentItemUnknown;
  }
}

export function messageContentItemToJSON(v: MessageContentItem): Record<string, unknown> {
  switch (v.type) {
    case 'image': return { type: 'image', ...imageToJSON(v as any) };
    case 'text': return { type: 'text', ...textToJSON(v as any) };
    case 'tool_result': return { type: 'tool_result', ...itemToolResultToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isMessageContentItemImage = (v: MessageContentItem): v is MessageContentItemImage => v.type === 'image';
export const isMessageContentItemText = (v: MessageContentItem): v is MessageContentItemText => v.type === 'text';
export const isMessageContentItemToolResult = (v: MessageContentItem): v is MessageContentItemToolResult => v.type === 'tool_result';

export function parseImage(o: Record<string, unknown>): Image {
  return {
    source: (() => { const _o = asObj(pick(o, 'source')); return _o ? parseSource(_o) : undefined; })(),
  };
}

export function imageToJSON(v: Image): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.source != null) d['source'] = sourceToJSON(v.source);
  return d;
}

export function parseSource(o: Record<string, unknown>): Source {
  return {
    data: asStr(pick(o, 'data')),
    mediaType: asStr(pick(o, 'media_type', 'mediaType')),
    type: asStr(pick(o, 'type')),
  };
}

export function sourceToJSON(v: Source): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.data != null) d['data'] = v.data;
  if (v.mediaType != null) d['media_type'] = v.mediaType;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseItemToolResult(o: Record<string, unknown>): ItemToolResult {
  return {
    content: parseItemToolResultContent(pick(o, 'content')),
    isError: asBool(pick(o, 'is_error', 'isError')),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
  };
}

export function itemToolResultToJSON(v: ItemToolResult): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = itemToolResultContentToJSON(v.content);
  if (v.isError != null) d['is_error'] = v.isError;
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  return d;
}

export function parseItemToolResultContent(json: unknown): ItemToolResultContent {
  if (typeof json === 'string') return json;
  if (Array.isArray(json)) return asArr(json)?.map(v => parseItemToolResultContentItem(v));
  return json as ItemToolResultContent;
}

export function itemToolResultContentToJSON(v: ItemToolResultContent): unknown {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v;
  return v;
}

export function parseItemToolResultContentItem(json: unknown): ItemToolResultContentItem {
  const o = asObj(json);
  if (!o) return { type: 'unknown' } as ItemToolResultContentItemUnknown;
  const _tag = asStr(o.type);
  switch (_tag) {
    case 'image': return { type: 'image', ...parseImage(o) } as ItemToolResultContentItemImage;
    case 'text': return { type: 'text', ...parseText(o) } as ItemToolResultContentItemText;
    case 'tool_reference': return { type: 'tool_reference', ...parseToolReference(o) } as ItemToolResultContentItemToolReference;
    default: return { type: _tag ?? 'unknown', ...o } as ItemToolResultContentItemUnknown;
  }
}

export function itemToolResultContentItemToJSON(v: ItemToolResultContentItem): Record<string, unknown> {
  switch (v.type) {
    case 'image': return { type: 'image', ...imageToJSON(v as any) };
    case 'text': return { type: 'text', ...textToJSON(v as any) };
    case 'tool_reference': return { type: 'tool_reference', ...toolReferenceToJSON(v as any) };
    default: { const { type: _t, ...rest } = v as any; return _t === 'unknown' ? rest : v as any; }
  }
}

export const isItemToolResultContentItemImage = (v: ItemToolResultContentItem): v is ItemToolResultContentItemImage => v.type === 'image';
export const isItemToolResultContentItemText = (v: ItemToolResultContentItem): v is ItemToolResultContentItemText => v.type === 'text';
export const isItemToolResultContentItemToolReference = (v: ItemToolResultContentItem): v is ItemToolResultContentItemToolReference => v.type === 'tool_reference';

export function parseToolReference(o: Record<string, unknown>): ToolReference {
  return {
    toolName: asStr(pick(o, 'tool_name', 'toolName')),
  };
}

export function toolReferenceToJSON(v: ToolReference): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.toolName != null) d['tool_name'] = v.toolName;
  return d;
}

export function parseOrigin(o: Record<string, unknown>): Origin {
  return {
    kind: asStr(pick(o, 'kind')),
  };
}

export function originToJSON(v: Origin): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.kind != null) d['kind'] = v.kind;
  return d;
}

export function parseToolUseResult(json: unknown): ToolUseResult {
  if (typeof json === 'string') return json;
  { const _o = asObj(json); if (_o) return parseToolUseResultObject(_o); }
  return json as ToolUseResult;
}

export function toolUseResultToJSON(v: ToolUseResult): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) return toolUseResultObjectToJSON(v as ToolUseResultObject);
  return v;
}

export function parseToolUseResultObject(json: unknown): ToolUseResultObject {
  const o = asObj(json);
  if (!o) return { _resolved_tool: 'unknown', _raw: {} } as ToolUseResultObjectUnknown;
  return { _resolved_tool: 'unknown', _raw: o } as ToolUseResultObjectUnknown;
}

export function toolUseResultObjectToJSON(v: ToolUseResultObject): Record<string, unknown> {
  switch (v._resolved_tool) {
    case 'AskUserQuestion': return objectAskUserQuestionToJSON(v as any);
    case 'Bash': return objectBashToJSON(v as any);
    case 'CronCreate': return objectCronCreateToJSON(v as any);
    case 'Edit': return objectEditToJSON(v as any);
    case 'EnterPlanMode': return objectEnterPlanModeToJSON(v as any);
    case 'EnterWorktree': return objectEnterWorktreeToJSON(v as any);
    case 'ExitPlanMode': return objectExitPlanModeToJSON(v as any);
    case 'ExitWorktree': return objectExitWorktreeToJSON(v as any);
    case 'Glob': return objectGlobToJSON(v as any);
    case 'Grep': return objectGrepToJSON(v as any);
    case 'SendMessage': return objectSendMessageToJSON(v as any);
    case 'Skill': return objectSkillToJSON(v as any);
    case 'Task': return objectTaskToJSON(v as any);
    case 'TaskCreate': return objectTaskCreateToJSON(v as any);
    case 'TaskOutput': return objectTaskOutputToJSON(v as any);
    case 'TaskStop': return objectTaskStopToJSON(v as any);
    case 'TaskUpdate': return objectTaskUpdateToJSON(v as any);
    case 'TeamCreate': return objectTeamCreateToJSON(v as any);
    case 'TodoWrite': return objectTodoWriteToJSON(v as any);
    case 'ToolSearch': return objectToolSearchToJSON(v as any);
    case 'WebFetch': return objectWebFetchToJSON(v as any);
    case 'WebSearch': return objectWebSearchToJSON(v as any);
    case 'Write': return objectWriteToJSON(v as any);
    default: return (v as any)._raw ?? {};
  }
}

export const isToolUseResultObjectAskUserQuestion = (v: ToolUseResultObject): v is ToolUseResultObjectAskUserQuestion => v._resolved_tool === 'AskUserQuestion';
export const isToolUseResultObjectBash = (v: ToolUseResultObject): v is ToolUseResultObjectBash => v._resolved_tool === 'Bash';
export const isToolUseResultObjectCronCreate = (v: ToolUseResultObject): v is ToolUseResultObjectCronCreate => v._resolved_tool === 'CronCreate';
export const isToolUseResultObjectEdit = (v: ToolUseResultObject): v is ToolUseResultObjectEdit => v._resolved_tool === 'Edit';
export const isToolUseResultObjectEnterPlanMode = (v: ToolUseResultObject): v is ToolUseResultObjectEnterPlanMode => v._resolved_tool === 'EnterPlanMode';
export const isToolUseResultObjectEnterWorktree = (v: ToolUseResultObject): v is ToolUseResultObjectEnterWorktree => v._resolved_tool === 'EnterWorktree';
export const isToolUseResultObjectExitPlanMode = (v: ToolUseResultObject): v is ToolUseResultObjectExitPlanMode => v._resolved_tool === 'ExitPlanMode';
export const isToolUseResultObjectExitWorktree = (v: ToolUseResultObject): v is ToolUseResultObjectExitWorktree => v._resolved_tool === 'ExitWorktree';
export const isToolUseResultObjectGlob = (v: ToolUseResultObject): v is ToolUseResultObjectGlob => v._resolved_tool === 'Glob';
export const isToolUseResultObjectGrep = (v: ToolUseResultObject): v is ToolUseResultObjectGrep => v._resolved_tool === 'Grep';
export const isToolUseResultObjectSendMessage = (v: ToolUseResultObject): v is ToolUseResultObjectSendMessage => v._resolved_tool === 'SendMessage';
export const isToolUseResultObjectSkill = (v: ToolUseResultObject): v is ToolUseResultObjectSkill => v._resolved_tool === 'Skill';
export const isToolUseResultObjectTask = (v: ToolUseResultObject): v is ToolUseResultObjectTask => v._resolved_tool === 'Task';
export const isToolUseResultObjectTaskCreate = (v: ToolUseResultObject): v is ToolUseResultObjectTaskCreate => v._resolved_tool === 'TaskCreate';
export const isToolUseResultObjectTaskOutput = (v: ToolUseResultObject): v is ToolUseResultObjectTaskOutput => v._resolved_tool === 'TaskOutput';
export const isToolUseResultObjectTaskStop = (v: ToolUseResultObject): v is ToolUseResultObjectTaskStop => v._resolved_tool === 'TaskStop';
export const isToolUseResultObjectTaskUpdate = (v: ToolUseResultObject): v is ToolUseResultObjectTaskUpdate => v._resolved_tool === 'TaskUpdate';
export const isToolUseResultObjectTeamCreate = (v: ToolUseResultObject): v is ToolUseResultObjectTeamCreate => v._resolved_tool === 'TeamCreate';
export const isToolUseResultObjectTodoWrite = (v: ToolUseResultObject): v is ToolUseResultObjectTodoWrite => v._resolved_tool === 'TodoWrite';
export const isToolUseResultObjectToolSearch = (v: ToolUseResultObject): v is ToolUseResultObjectToolSearch => v._resolved_tool === 'ToolSearch';
export const isToolUseResultObjectWebFetch = (v: ToolUseResultObject): v is ToolUseResultObjectWebFetch => v._resolved_tool === 'WebFetch';
export const isToolUseResultObjectWebSearch = (v: ToolUseResultObject): v is ToolUseResultObjectWebSearch => v._resolved_tool === 'WebSearch';
export const isToolUseResultObjectWrite = (v: ToolUseResultObject): v is ToolUseResultObjectWrite => v._resolved_tool === 'Write';

export function parseObjectAskUserQuestion(o: Record<string, unknown>): ObjectAskUserQuestion {
  return {
    annotations: (() => { const _o = asObj(pick(o, 'annotations')); if (!_o) return undefined; const r: Record<string, AnnotationsValue> = {}; for (const [k, v] of Object.entries(_o)) { const _ov = asObj(v); if (_ov) r[k] = parseAnnotationsValue(_ov); }; return r; })(),
    answers: (() => { const _o = asObj(pick(o, 'answers')); if (!_o) return undefined; const r: Record<string, string> = {}; for (const [k, v] of Object.entries(_o)) { const s = asStr(v); if (s !== undefined) r[k] = s; }; return r; })(),
    questions: asArr(pick(o, 'questions'))?.map(v => { const _o = asObj(v); return _o ? parseAskUserQuestionQuestions(_o) : undefined; }).filter((v): v is AskUserQuestionQuestions => v !== undefined),
  };
}

export function objectAskUserQuestionToJSON(v: ObjectAskUserQuestion): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.annotations != null) d['annotations'] = Object.fromEntries(Object.entries(v.annotations).map(([k, v]) => [k, annotationsValueToJSON(v)]));
  if (v.answers != null) d['answers'] = v.answers;
  if (v.questions != null) d['questions'] = v.questions.map(v => askUserQuestionQuestionsToJSON(v));
  return d;
}

export function parseAnnotationsValue(o: Record<string, unknown>): AnnotationsValue {
  return {
    notes: asStr(pick(o, 'notes')),
    preview: asStr(pick(o, 'preview')),
  };
}

export function annotationsValueToJSON(v: AnnotationsValue): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.notes != null) d['notes'] = v.notes;
  if (v.preview != null) d['preview'] = v.preview;
  return d;
}

export function parseAskUserQuestionQuestions(o: Record<string, unknown>): AskUserQuestionQuestions {
  return {
    header: asStr(pick(o, 'header')),
    multiSelect: asBool(pick(o, 'multi_select', 'multiSelect')),
    options: asArr(pick(o, 'options'))?.map(v => { const _o = asObj(v); return _o ? parseOptions(_o) : undefined; }).filter((v): v is Options => v !== undefined),
    question: asStr(pick(o, 'question')),
  };
}

export function askUserQuestionQuestionsToJSON(v: AskUserQuestionQuestions): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.header != null) d['header'] = v.header;
  if (v.multiSelect != null) d['multi_select'] = v.multiSelect;
  if (v.options != null) d['options'] = v.options.map(v => optionsToJSON(v));
  if (v.question != null) d['question'] = v.question;
  return d;
}

export function parseObjectBash(o: Record<string, unknown>): ObjectBash {
  return {
    assistantAutoBackgrounded: asBool(pick(o, 'assistant_auto_backgrounded', 'assistantAutoBackgrounded')),
    backgroundTaskId: asStr(pick(o, 'background_task_id', 'backgroundTaskId')),
    backgroundedByUser: asBool(pick(o, 'backgrounded_by_user', 'backgroundedByUser')),
    interrupted: asBool(pick(o, 'interrupted')),
    isImage: asBool(pick(o, 'is_image', 'isImage')),
    noOutputExpected: asBool(pick(o, 'no_output_expected', 'noOutputExpected')),
    persistedOutputPath: asStr(pick(o, 'persisted_output_path', 'persistedOutputPath')),
    persistedOutputSize: asNum(pick(o, 'persisted_output_size', 'persistedOutputSize')),
    returnCodeInterpretation: asStr(pick(o, 'return_code_interpretation', 'returnCodeInterpretation')),
    stderr: asStr(pick(o, 'stderr')),
    stdout: asStr(pick(o, 'stdout')),
    tokenSaverOutput: asStr(pick(o, 'token_saver_output', 'tokenSaverOutput')),
  };
}

export function objectBashToJSON(v: ObjectBash): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.assistantAutoBackgrounded != null) d['assistant_auto_backgrounded'] = v.assistantAutoBackgrounded;
  if (v.backgroundTaskId != null) d['background_task_id'] = v.backgroundTaskId;
  if (v.backgroundedByUser != null) d['backgrounded_by_user'] = v.backgroundedByUser;
  if (v.interrupted != null) d['interrupted'] = v.interrupted;
  if (v.isImage != null) d['is_image'] = v.isImage;
  if (v.noOutputExpected != null) d['no_output_expected'] = v.noOutputExpected;
  if (v.persistedOutputPath != null) d['persisted_output_path'] = v.persistedOutputPath;
  if (v.persistedOutputSize != null) d['persisted_output_size'] = v.persistedOutputSize;
  if (v.returnCodeInterpretation != null) d['return_code_interpretation'] = v.returnCodeInterpretation;
  if (v.stderr != null) d['stderr'] = v.stderr;
  if (v.stdout != null) d['stdout'] = v.stdout;
  if (v.tokenSaverOutput != null) d['token_saver_output'] = v.tokenSaverOutput;
  return d;
}

export function parseObjectCronCreate(o: Record<string, unknown>): ObjectCronCreate {
  return {
    durable: asBool(pick(o, 'durable')),
    humanSchedule: asStr(pick(o, 'human_schedule', 'humanSchedule')),
    id: asStr(pick(o, 'id')),
    recurring: asBool(pick(o, 'recurring')),
  };
}

export function objectCronCreateToJSON(v: ObjectCronCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durable != null) d['durable'] = v.durable;
  if (v.humanSchedule != null) d['human_schedule'] = v.humanSchedule;
  if (v.id != null) d['id'] = v.id;
  if (v.recurring != null) d['recurring'] = v.recurring;
  return d;
}

export function parseObjectEdit(o: Record<string, unknown>): ObjectEdit {
  return {
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    newString: asStr(pick(o, 'new_string', 'newString')),
    oldString: asStr(pick(o, 'old_string', 'oldString')),
    originalFile: asStr(pick(o, 'original_file', 'originalFile')),
    replaceAll: asBool(pick(o, 'replace_all', 'replaceAll')),
    structuredPatch: asArr(pick(o, 'structured_patch', 'structuredPatch'))?.map(v => { const _o = asObj(v); return _o ? parseStructuredPatch(_o) : undefined; }).filter((v): v is StructuredPatch => v !== undefined),
    userModified: asBool(pick(o, 'user_modified', 'userModified')),
  };
}

export function objectEditToJSON(v: ObjectEdit): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.newString != null) d['new_string'] = v.newString;
  if (v.oldString != null) d['old_string'] = v.oldString;
  if (v.originalFile != null) d['original_file'] = v.originalFile;
  if (v.replaceAll != null) d['replace_all'] = v.replaceAll;
  if (v.structuredPatch != null) d['structured_patch'] = v.structuredPatch.map(v => structuredPatchToJSON(v));
  if (v.userModified != null) d['user_modified'] = v.userModified;
  return d;
}

export function parseStructuredPatch(o: Record<string, unknown>): StructuredPatch {
  return {
    lines: asArr(pick(o, 'lines'))?.map(v => asStr(v)!),
    newLines: asNum(pick(o, 'new_lines', 'newLines')),
    newStart: asNum(pick(o, 'new_start', 'newStart')),
    oldLines: asNum(pick(o, 'old_lines', 'oldLines')),
    oldStart: asNum(pick(o, 'old_start', 'oldStart')),
  };
}

export function structuredPatchToJSON(v: StructuredPatch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.lines != null) d['lines'] = v.lines;
  if (v.newLines != null) d['new_lines'] = v.newLines;
  if (v.newStart != null) d['new_start'] = v.newStart;
  if (v.oldLines != null) d['old_lines'] = v.oldLines;
  if (v.oldStart != null) d['old_start'] = v.oldStart;
  return d;
}

export function parseObjectEnterPlanMode(o: Record<string, unknown>): ObjectEnterPlanMode {
  return {
    message: asStr(pick(o, 'message')),
  };
}

export function objectEnterPlanModeToJSON(v: ObjectEnterPlanMode): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.message != null) d['message'] = v.message;
  return d;
}

export function parseObjectEnterWorktree(o: Record<string, unknown>): ObjectEnterWorktree {
  return {
    message: asStr(pick(o, 'message')),
    worktreeBranch: asStr(pick(o, 'worktree_branch', 'worktreeBranch')),
    worktreePath: asStr(pick(o, 'worktree_path', 'worktreePath')),
  };
}

export function objectEnterWorktreeToJSON(v: ObjectEnterWorktree): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.message != null) d['message'] = v.message;
  if (v.worktreeBranch != null) d['worktree_branch'] = v.worktreeBranch;
  if (v.worktreePath != null) d['worktree_path'] = v.worktreePath;
  return d;
}

export function parseObjectExitPlanMode(o: Record<string, unknown>): ObjectExitPlanMode {
  return {
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    isAgent: asBool(pick(o, 'is_agent', 'isAgent')),
    plan: asStr(pick(o, 'plan')),
  };
}

export function objectExitPlanModeToJSON(v: ObjectExitPlanMode): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.isAgent != null) d['is_agent'] = v.isAgent;
  if (v.plan != null) d['plan'] = v.plan;
  return d;
}

export function parseObjectExitWorktree(o: Record<string, unknown>): ObjectExitWorktree {
  return {
    action: asStr(pick(o, 'action')),
    message: asStr(pick(o, 'message')),
    originalCwd: asStr(pick(o, 'original_cwd', 'originalCwd')),
    worktreeBranch: asStr(pick(o, 'worktree_branch', 'worktreeBranch')),
    worktreePath: asStr(pick(o, 'worktree_path', 'worktreePath')),
  };
}

export function objectExitWorktreeToJSON(v: ObjectExitWorktree): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.action != null) d['action'] = v.action;
  if (v.message != null) d['message'] = v.message;
  if (v.originalCwd != null) d['original_cwd'] = v.originalCwd;
  if (v.worktreeBranch != null) d['worktree_branch'] = v.worktreeBranch;
  if (v.worktreePath != null) d['worktree_path'] = v.worktreePath;
  return d;
}

export function parseObjectGlob(o: Record<string, unknown>): ObjectGlob {
  return {
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    filenames: asArr(pick(o, 'filenames'))?.map(v => asStr(v)!),
    numFiles: asNum(pick(o, 'num_files', 'numFiles')),
    truncated: asBool(pick(o, 'truncated')),
  };
}

export function objectGlobToJSON(v: ObjectGlob): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.filenames != null) d['filenames'] = v.filenames;
  if (v.numFiles != null) d['num_files'] = v.numFiles;
  if (v.truncated != null) d['truncated'] = v.truncated;
  return d;
}

export function parseObjectGrep(o: Record<string, unknown>): ObjectGrep {
  return {
    appliedLimit: asNum(pick(o, 'applied_limit', 'appliedLimit')),
    appliedOffset: asNum(pick(o, 'applied_offset', 'appliedOffset')),
    content: asStr(pick(o, 'content')),
    filenames: asArr(pick(o, 'filenames'))?.map(v => asStr(v)!),
    mode: asStr(pick(o, 'mode')),
    numFiles: asNum(pick(o, 'num_files', 'numFiles')),
    numLines: asNum(pick(o, 'num_lines', 'numLines')),
    numMatches: asNum(pick(o, 'num_matches', 'numMatches')),
  };
}

export function objectGrepToJSON(v: ObjectGrep): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.appliedLimit != null) d['applied_limit'] = v.appliedLimit;
  if (v.appliedOffset != null) d['applied_offset'] = v.appliedOffset;
  if (v.content != null) d['content'] = v.content;
  if (v.filenames != null) d['filenames'] = v.filenames;
  if (v.mode != null) d['mode'] = v.mode;
  if (v.numFiles != null) d['num_files'] = v.numFiles;
  if (v.numLines != null) d['num_lines'] = v.numLines;
  if (v.numMatches != null) d['num_matches'] = v.numMatches;
  return d;
}

export function parseObjectSendMessage(o: Record<string, unknown>): ObjectSendMessage {
  return {
    message: asStr(pick(o, 'message')),
    requestId: asStr(pick(o, 'request_id', 'requestID', 'requestId')),
    routing: (() => { const _o = asObj(pick(o, 'routing')); return _o ? parseRouting(_o) : undefined; })(),
    success: asBool(pick(o, 'success')),
    target: asStr(pick(o, 'target')),
  };
}

export function objectSendMessageToJSON(v: ObjectSendMessage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.message != null) d['message'] = v.message;
  if (v.requestId != null) d['request_id'] = v.requestId;
  if (v.routing != null) d['routing'] = routingToJSON(v.routing);
  if (v.success != null) d['success'] = v.success;
  if (v.target != null) d['target'] = v.target;
  return d;
}

export function parseRouting(o: Record<string, unknown>): Routing {
  return {
    content: asStr(pick(o, 'content')),
    sender: asStr(pick(o, 'sender')),
    senderColor: asStr(pick(o, 'sender_color', 'senderColor')),
    summary: asStr(pick(o, 'summary')),
    target: asStr(pick(o, 'target')),
    targetColor: asStr(pick(o, 'target_color', 'targetColor')),
  };
}

export function routingToJSON(v: Routing): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.sender != null) d['sender'] = v.sender;
  if (v.senderColor != null) d['sender_color'] = v.senderColor;
  if (v.summary != null) d['summary'] = v.summary;
  if (v.target != null) d['target'] = v.target;
  if (v.targetColor != null) d['target_color'] = v.targetColor;
  return d;
}

export function parseObjectSkill(o: Record<string, unknown>): ObjectSkill {
  return {
    allowedTools: asArr(pick(o, 'allowed_tools', 'allowedTools'))?.map(v => asStr(v)!),
    commandName: asStr(pick(o, 'command_name', 'commandName')),
    success: asBool(pick(o, 'success')),
  };
}

export function objectSkillToJSON(v: ObjectSkill): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.allowedTools != null) d['allowed_tools'] = v.allowedTools;
  if (v.commandName != null) d['command_name'] = v.commandName;
  if (v.success != null) d['success'] = v.success;
  return d;
}

export function parseObjectTask(o: Record<string, unknown>): ObjectTask {
  return {
    agentId: asStr(pick(o, 'agent_id', 'agentId')),
    canReadOutputFile: asBool(pick(o, 'can_read_output_file', 'canReadOutputFile')),
    content: asArr(pick(o, 'content'))?.map(v => { const _o = asObj(v); return _o ? parseTaskContent(_o) : undefined; }).filter((v): v is TaskContent => v !== undefined),
    description: asStr(pick(o, 'description')),
    isAsync: asBool(pick(o, 'is_async', 'isAsync')),
    outputFile: asStr(pick(o, 'output_file', 'outputFile')),
    prompt: asStr(pick(o, 'prompt')),
    status: asStr(pick(o, 'status')),
    totalDurationMs: asNum(pick(o, 'total_duration_ms', 'totalDurationMs')),
    totalTokens: asNum(pick(o, 'total_tokens', 'totalTokens')),
    totalToolUseCount: asNum(pick(o, 'total_tool_use_count', 'totalToolUseCount')),
    usage: (() => { const _o = asObj(pick(o, 'usage')); return _o ? parseTaskUsage(_o) : undefined; })(),
  };
}

export function objectTaskToJSON(v: ObjectTask): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.agentId != null) d['agent_id'] = v.agentId;
  if (v.canReadOutputFile != null) d['can_read_output_file'] = v.canReadOutputFile;
  if (v.content != null) d['content'] = v.content.map(v => taskContentToJSON(v));
  if (v.description != null) d['description'] = v.description;
  if (v.isAsync != null) d['is_async'] = v.isAsync;
  if (v.outputFile != null) d['output_file'] = v.outputFile;
  if (v.prompt != null) d['prompt'] = v.prompt;
  if (v.status != null) d['status'] = v.status;
  if (v.totalDurationMs != null) d['total_duration_ms'] = v.totalDurationMs;
  if (v.totalTokens != null) d['total_tokens'] = v.totalTokens;
  if (v.totalToolUseCount != null) d['total_tool_use_count'] = v.totalToolUseCount;
  if (v.usage != null) d['usage'] = taskUsageToJSON(v.usage);
  return d;
}

export function parseTaskContent(o: Record<string, unknown>): TaskContent {
  return {
    text: asStr(pick(o, 'text')),
    type: asStr(pick(o, 'type')),
  };
}

export function taskContentToJSON(v: TaskContent): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.text != null) d['text'] = v.text;
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseTaskUsage(o: Record<string, unknown>): TaskUsage {
  return {
    cacheCreation: (() => { const _o = asObj(pick(o, 'cache_creation', 'cacheCreation')); return _o ? parseCacheCreation(_o) : undefined; })(),
    cacheCreationInputTokens: asNum(pick(o, 'cache_creation_input_tokens', 'cacheCreationInputTokens')),
    cacheReadInputTokens: asNum(pick(o, 'cache_read_input_tokens', 'cacheReadInputTokens')),
    inferenceGeo: asStr(pick(o, 'inference_geo', 'inferenceGeo')),
    inputTokens: asNum(pick(o, 'input_tokens', 'inputTokens')),
    iterations: asArr(pick(o, 'iterations')),
    outputTokens: asNum(pick(o, 'output_tokens', 'outputTokens')),
    serverToolUse: (() => { const _o = asObj(pick(o, 'server_tool_use', 'serverToolUse')); return _o ? parseTaskUsageServerToolUse(_o) : undefined; })(),
    serviceTier: asStr(pick(o, 'service_tier', 'serviceTier')),
    speed: asStr(pick(o, 'speed')),
  };
}

export function taskUsageToJSON(v: TaskUsage): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.cacheCreation != null) d['cache_creation'] = cacheCreationToJSON(v.cacheCreation);
  if (v.cacheCreationInputTokens != null) d['cache_creation_input_tokens'] = v.cacheCreationInputTokens;
  if (v.cacheReadInputTokens != null) d['cache_read_input_tokens'] = v.cacheReadInputTokens;
  if (v.inferenceGeo != null) d['inference_geo'] = v.inferenceGeo;
  if (v.inputTokens != null) d['input_tokens'] = v.inputTokens;
  if (v.iterations != null) d['iterations'] = v.iterations;
  if (v.outputTokens != null) d['output_tokens'] = v.outputTokens;
  if (v.serverToolUse != null) d['server_tool_use'] = taskUsageServerToolUseToJSON(v.serverToolUse);
  if (v.serviceTier != null) d['service_tier'] = v.serviceTier;
  if (v.speed != null) d['speed'] = v.speed;
  return d;
}

export function parseTaskUsageServerToolUse(o: Record<string, unknown>): TaskUsageServerToolUse {
  return {
    webFetchRequests: asNum(pick(o, 'web_fetch_requests', 'webFetchRequests')),
    webSearchRequests: asNum(pick(o, 'web_search_requests', 'webSearchRequests')),
  };
}

export function taskUsageServerToolUseToJSON(v: TaskUsageServerToolUse): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.webFetchRequests != null) d['web_fetch_requests'] = v.webFetchRequests;
  if (v.webSearchRequests != null) d['web_search_requests'] = v.webSearchRequests;
  return d;
}

export function parseObjectTaskCreate(o: Record<string, unknown>): ObjectTaskCreate {
  return {
    task: (() => { const _o = asObj(pick(o, 'task')); return _o ? parseTaskCreateTask(_o) : undefined; })(),
  };
}

export function objectTaskCreateToJSON(v: ObjectTaskCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.task != null) d['task'] = taskCreateTaskToJSON(v.task);
  return d;
}

export function parseTaskCreateTask(o: Record<string, unknown>): TaskCreateTask {
  return {
    id: asStr(pick(o, 'id')),
    subject: asStr(pick(o, 'subject')),
  };
}

export function taskCreateTaskToJSON(v: TaskCreateTask): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.id != null) d['id'] = v.id;
  if (v.subject != null) d['subject'] = v.subject;
  return d;
}

export function parseObjectTaskOutput(o: Record<string, unknown>): ObjectTaskOutput {
  return {
    retrievalStatus: asStr(pick(o, 'retrieval_status', 'retrievalStatus')),
    task: (() => { const _o = asObj(pick(o, 'task')); return _o ? parseTaskOutputTask(_o) : undefined; })(),
  };
}

export function objectTaskOutputToJSON(v: ObjectTaskOutput): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.retrievalStatus != null) d['retrieval_status'] = v.retrievalStatus;
  if (v.task != null) d['task'] = taskOutputTaskToJSON(v.task);
  return d;
}

export function parseTaskOutputTask(o: Record<string, unknown>): TaskOutputTask {
  return {
    description: asStr(pick(o, 'description')),
    exitCode: asNum(pick(o, 'exit_code', 'exitCode')),
    output: asStr(pick(o, 'output')),
    status: asStr(pick(o, 'status')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    taskType: asStr(pick(o, 'task_type', 'taskType')),
  };
}

export function taskOutputTaskToJSON(v: TaskOutputTask): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.description != null) d['description'] = v.description;
  if (v.exitCode != null) d['exit_code'] = v.exitCode;
  if (v.output != null) d['output'] = v.output;
  if (v.status != null) d['status'] = v.status;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.taskType != null) d['task_type'] = v.taskType;
  return d;
}

export function parseObjectTaskStop(o: Record<string, unknown>): ObjectTaskStop {
  return {
    command: asStr(pick(o, 'command')),
    message: asStr(pick(o, 'message')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    taskType: asStr(pick(o, 'task_type', 'taskType')),
  };
}

export function objectTaskStopToJSON(v: ObjectTaskStop): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.command != null) d['command'] = v.command;
  if (v.message != null) d['message'] = v.message;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.taskType != null) d['task_type'] = v.taskType;
  return d;
}

export function parseObjectTaskUpdate(o: Record<string, unknown>): ObjectTaskUpdate {
  return {
    error: asStr(pick(o, 'error')),
    statusChange: (() => { const _o = asObj(pick(o, 'status_change', 'statusChange')); return _o ? parseStatusChange(_o) : undefined; })(),
    success: asBool(pick(o, 'success')),
    taskId: asStr(pick(o, 'task_id', 'taskId')),
    updatedFields: asArr(pick(o, 'updated_fields', 'updatedFields'))?.map(v => asStr(v)!),
    verificationNudgeNeeded: asBool(pick(o, 'verification_nudge_needed', 'verificationNudgeNeeded')),
  };
}

export function objectTaskUpdateToJSON(v: ObjectTaskUpdate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.error != null) d['error'] = v.error;
  if (v.statusChange != null) d['status_change'] = statusChangeToJSON(v.statusChange);
  if (v.success != null) d['success'] = v.success;
  if (v.taskId != null) d['task_id'] = v.taskId;
  if (v.updatedFields != null) d['updated_fields'] = v.updatedFields;
  if (v.verificationNudgeNeeded != null) d['verification_nudge_needed'] = v.verificationNudgeNeeded;
  return d;
}

export function parseStatusChange(o: Record<string, unknown>): StatusChange {
  return {
    from: asStr(pick(o, 'from')),
    to: asStr(pick(o, 'to')),
  };
}

export function statusChangeToJSON(v: StatusChange): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.from != null) d['from'] = v.from;
  if (v.to != null) d['to'] = v.to;
  return d;
}

export function parseObjectTeamCreate(o: Record<string, unknown>): ObjectTeamCreate {
  return {
    leadAgentId: asStr(pick(o, 'lead_agent_id', 'leadAgentId')),
    teamFilePath: asStr(pick(o, 'team_file_path', 'teamFilePath')),
    teamName: asStr(pick(o, 'team_name', 'teamName')),
  };
}

export function objectTeamCreateToJSON(v: ObjectTeamCreate): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.leadAgentId != null) d['lead_agent_id'] = v.leadAgentId;
  if (v.teamFilePath != null) d['team_file_path'] = v.teamFilePath;
  if (v.teamName != null) d['team_name'] = v.teamName;
  return d;
}

export function parseObjectTodoWrite(o: Record<string, unknown>): ObjectTodoWrite {
  return {
    newTodos: asArr(pick(o, 'new_todos', 'newTodos'))?.map(v => { const _o = asObj(v); return _o ? parseNewTodos(_o) : undefined; }).filter((v): v is NewTodos => v !== undefined),
    oldTodos: asArr(pick(o, 'old_todos', 'oldTodos'))?.map(v => { const _o = asObj(v); return _o ? parseNewTodos(_o) : undefined; }).filter((v): v is NewTodos => v !== undefined),
    verificationNudgeNeeded: asBool(pick(o, 'verification_nudge_needed', 'verificationNudgeNeeded')),
  };
}

export function objectTodoWriteToJSON(v: ObjectTodoWrite): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.newTodos != null) d['new_todos'] = v.newTodos.map(v => newTodosToJSON(v));
  if (v.oldTodos != null) d['old_todos'] = v.oldTodos.map(v => newTodosToJSON(v));
  if (v.verificationNudgeNeeded != null) d['verification_nudge_needed'] = v.verificationNudgeNeeded;
  return d;
}

export function parseNewTodos(o: Record<string, unknown>): NewTodos {
  return {
    activeForm: asStr(pick(o, 'active_form', 'activeForm')),
    content: asStr(pick(o, 'content')),
    status: asStr(pick(o, 'status')),
  };
}

export function newTodosToJSON(v: NewTodos): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.activeForm != null) d['active_form'] = v.activeForm;
  if (v.content != null) d['content'] = v.content;
  if (v.status != null) d['status'] = v.status;
  return d;
}

export function parseObjectToolSearch(o: Record<string, unknown>): ObjectToolSearch {
  return {
    matches: asArr(pick(o, 'matches'))?.map(v => asStr(v)!),
    query: asStr(pick(o, 'query')),
    totalDeferredTools: asNum(pick(o, 'total_deferred_tools', 'totalDeferredTools')),
  };
}

export function objectToolSearchToJSON(v: ObjectToolSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.matches != null) d['matches'] = v.matches;
  if (v.query != null) d['query'] = v.query;
  if (v.totalDeferredTools != null) d['total_deferred_tools'] = v.totalDeferredTools;
  return d;
}

export function parseObjectWebFetch(o: Record<string, unknown>): ObjectWebFetch {
  return {
    bytes: asNum(pick(o, 'bytes')),
    code: asNum(pick(o, 'code')),
    codeText: asStr(pick(o, 'code_text', 'codeText')),
    durationMs: asNum(pick(o, 'duration_ms', 'durationMs')),
    result: asStr(pick(o, 'result')),
    url: asStr(pick(o, 'url')),
  };
}

export function objectWebFetchToJSON(v: ObjectWebFetch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.bytes != null) d['bytes'] = v.bytes;
  if (v.code != null) d['code'] = v.code;
  if (v.codeText != null) d['code_text'] = v.codeText;
  if (v.durationMs != null) d['duration_ms'] = v.durationMs;
  if (v.result != null) d['result'] = v.result;
  if (v.url != null) d['url'] = v.url;
  return d;
}

export function parseObjectWebSearch(o: Record<string, unknown>): ObjectWebSearch {
  return {
    durationSeconds: asNum(pick(o, 'duration_seconds', 'durationSeconds')),
    query: asStr(pick(o, 'query')),
    results: asArr(pick(o, 'results'))?.map(v => parseResults(v)),
  };
}

export function objectWebSearchToJSON(v: ObjectWebSearch): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.durationSeconds != null) d['duration_seconds'] = v.durationSeconds;
  if (v.query != null) d['query'] = v.query;
  if (v.results != null) d['results'] = v.results.map(v => resultsToJSON(v));
  return d;
}

export function parseResults(json: unknown): Results {
  if (typeof json === 'string') return json;
  { const _o = asObj(json); if (_o) return parseResultsObject(_o); }
  return json as Results;
}

export function resultsToJSON(v: Results): unknown {
  if (typeof v === 'string') return v;
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) return resultsObjectToJSON(v as ResultsObject);
  return v;
}

export function parseResultsObject(o: Record<string, unknown>): ResultsObject {
  return {
    content: asArr(pick(o, 'content'))?.map(v => { const _o = asObj(v); return _o ? parseObjectContent(_o) : undefined; }).filter((v): v is ObjectContent => v !== undefined),
    toolUseId: asStr(pick(o, 'tool_use_id', 'toolUseID', 'toolUseId')),
  };
}

export function resultsObjectToJSON(v: ResultsObject): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content.map(v => objectContentToJSON(v));
  if (v.toolUseId != null) d['tool_use_id'] = v.toolUseId;
  return d;
}

export function parseObjectContent(o: Record<string, unknown>): ObjectContent {
  return {
    title: asStr(pick(o, 'title')),
    url: asStr(pick(o, 'url')),
  };
}

export function objectContentToJSON(v: ObjectContent): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.title != null) d['title'] = v.title;
  if (v.url != null) d['url'] = v.url;
  return d;
}

export function parseObjectWrite(o: Record<string, unknown>): ObjectWrite {
  return {
    content: asStr(pick(o, 'content')),
    filePath: asStr(pick(o, 'file_path', 'filePath')),
    originalFile: asStr(pick(o, 'original_file', 'originalFile')),
    structuredPatch: asArr(pick(o, 'structured_patch', 'structuredPatch'))?.map(v => { const _o = asObj(v); return _o ? parseStructuredPatch(_o) : undefined; }).filter((v): v is StructuredPatch => v !== undefined),
    type: asStr(pick(o, 'type')),
  };
}

export function objectWriteToJSON(v: ObjectWrite): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.content != null) d['content'] = v.content;
  if (v.filePath != null) d['file_path'] = v.filePath;
  if (v.originalFile != null) d['original_file'] = v.originalFile;
  if (v.structuredPatch != null) d['structured_patch'] = v.structuredPatch.map(v => structuredPatchToJSON(v));
  if (v.type != null) d['type'] = v.type;
  return d;
}

export function parseWorktreeState(o: Record<string, unknown>): WorktreeState {
  return {
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    worktreeSession: (() => { const _o = asObj(pick(o, 'worktree_session', 'worktreeSession')); return _o ? parseWorktreeSession(_o) : undefined; })(),
  };
}

export function worktreeStateToJSON(v: WorktreeState): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.worktreeSession != null) d['worktree_session'] = worktreeSessionToJSON(v.worktreeSession);
  return d;
}

export function parseWorktreeSession(o: Record<string, unknown>): WorktreeSession {
  return {
    originalBranch: asStr(pick(o, 'original_branch', 'originalBranch')),
    originalCwd: asStr(pick(o, 'original_cwd', 'originalCwd')),
    originalHeadCommit: asStr(pick(o, 'original_head_commit', 'originalHeadCommit')),
    sessionId: asStr(pick(o, 'session_id', 'sessionId')),
    worktreeBranch: asStr(pick(o, 'worktree_branch', 'worktreeBranch')),
    worktreeName: asStr(pick(o, 'worktree_name', 'worktreeName')),
    worktreePath: asStr(pick(o, 'worktree_path', 'worktreePath')),
  };
}

export function worktreeSessionToJSON(v: WorktreeSession): Record<string, unknown> {
  const d: Record<string, unknown> = {};
  if (v.originalBranch != null) d['original_branch'] = v.originalBranch;
  if (v.originalCwd != null) d['original_cwd'] = v.originalCwd;
  if (v.originalHeadCommit != null) d['original_head_commit'] = v.originalHeadCommit;
  if (v.sessionId != null) d['session_id'] = v.sessionId;
  if (v.worktreeBranch != null) d['worktree_branch'] = v.worktreeBranch;
  if (v.worktreeName != null) d['worktree_name'] = v.worktreeName;
  if (v.worktreePath != null) d['worktree_path'] = v.worktreePath;
  return d;
}

export class Message2Resolver {
  private resolvedToolIndex = new Map<string, ToolUse>();

  reset(): void {
    this.resolvedToolIndex.clear();
  }

  resolve(json: unknown): Message2 {
    const msg = parseMessage2(json);
    this.buildIndexes(msg);
    return this.resolveFields(msg);
  }

  private buildIndexes(msg: Message2): void {
    if (msg.type === 'assistant') {
      const _variant = msg;
      const _nav0 = (_variant as any).message;
      if (_nav0) {
        for (const _item of (_nav0 as any).content ?? []) {
          if ((_item as any).type === 'tool_use') {
            const _k = (_item as any).id;
            if (_k) this.resolvedToolIndex.set(_k, _item as any);
          }
        }
      }
    }
  }

  private resolveFields(msg: Message2): Message2 {
    let resolved = msg;
    if (resolved.type === 'user') {
      const _obj = (resolved as any).toolUseResult;
      if (_obj && typeof _obj === 'object' && _obj._resolved_tool === 'unknown' && _obj._raw) {
        const _nav0 = (resolved as any).message;
        if (_nav0) {
          const _items = (_nav0).content;
          if (Array.isArray(_items)) {
            for (const _item of _items) {
              if ((_item as any).type === 'tool_result') {
                const _lookupKey = (_item as any).toolUseId;
                if (_lookupKey && this.resolvedToolIndex.has(_lookupKey)) {
                  const _origin = this.resolvedToolIndex.get(_lookupKey)!;
                  const _raw = _obj._raw as Record<string, unknown>;
                  const _caseName = (_origin as any).name ?? 'unknown';
                  switch (_caseName) {
                    case 'AskUserQuestion': resolved = { ...resolved, toolUseResult: { ...parseObjectAskUserQuestion(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Bash': resolved = { ...resolved, toolUseResult: { ...parseObjectBash(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'CronCreate': resolved = { ...resolved, toolUseResult: { ...parseObjectCronCreate(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Edit': resolved = { ...resolved, toolUseResult: { ...parseObjectEdit(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'EnterPlanMode': resolved = { ...resolved, toolUseResult: { ...parseObjectEnterPlanMode(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'EnterWorktree': resolved = { ...resolved, toolUseResult: { ...parseObjectEnterWorktree(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'ExitPlanMode': resolved = { ...resolved, toolUseResult: { ...parseObjectExitPlanMode(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'ExitWorktree': resolved = { ...resolved, toolUseResult: { ...parseObjectExitWorktree(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Glob': resolved = { ...resolved, toolUseResult: { ...parseObjectGlob(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Grep': resolved = { ...resolved, toolUseResult: { ...parseObjectGrep(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'SendMessage': resolved = { ...resolved, toolUseResult: { ...parseObjectSendMessage(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Skill': resolved = { ...resolved, toolUseResult: { ...parseObjectSkill(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Task': resolved = { ...resolved, toolUseResult: { ...parseObjectTask(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TaskCreate': resolved = { ...resolved, toolUseResult: { ...parseObjectTaskCreate(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TaskOutput': resolved = { ...resolved, toolUseResult: { ...parseObjectTaskOutput(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TaskStop': resolved = { ...resolved, toolUseResult: { ...parseObjectTaskStop(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TaskUpdate': resolved = { ...resolved, toolUseResult: { ...parseObjectTaskUpdate(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TeamCreate': resolved = { ...resolved, toolUseResult: { ...parseObjectTeamCreate(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'TodoWrite': resolved = { ...resolved, toolUseResult: { ...parseObjectTodoWrite(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'ToolSearch': resolved = { ...resolved, toolUseResult: { ...parseObjectToolSearch(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'WebFetch': resolved = { ...resolved, toolUseResult: { ...parseObjectWebFetch(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'WebSearch': resolved = { ...resolved, toolUseResult: { ...parseObjectWebSearch(_raw), _origin: _origin as any } } as typeof resolved; break;
                    case 'Write': resolved = { ...resolved, toolUseResult: { ...parseObjectWrite(_raw), _origin: _origin as any } } as typeof resolved; break;
                    default: resolved = { ...resolved, toolUseResult: { _resolved_tool: _caseName, _raw, _origin } as any } as typeof resolved; break;
                  }
                  break;
                }
              }
            }
          }
        }
      }
    }
    return resolved;
  }
}
