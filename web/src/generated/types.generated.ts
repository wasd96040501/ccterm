// Auto-generated — do not edit

export type Message2CustomTitle = { readonly type: 'custom-title' } & CustomTitle;
export type Message2FileHistorySnapshot = { readonly type: 'file-history-snapshot' } & FileHistorySnapshot;
export type Message2LastPrompt = { readonly type: 'last-prompt' } & LastPrompt;
export type Message2Progress = { readonly type: 'progress' } & Progress;
export type Message2PromptSuggestion = { readonly type: 'prompt_suggestion' } & PromptSuggestion;
export type Message2QueueOperation = { readonly type: 'queue-operation' } & QueueOperation;
export type Message2RateLimitEvent = { readonly type: 'rate_limit_event' } & RateLimitEvent;
export type Message2Result = { readonly type: 'result' } & Result;
export type Message2System = { readonly type: 'system' } & System;
export type Message2WorktreeState = { readonly type: 'worktree-state' } & WorktreeState;
export type Message2Unknown = { readonly type: string; readonly [key: string]: unknown };
export type Message2 = Message2Assistant | Message2CustomTitle | Message2FileHistorySnapshot | Message2LastPrompt | Message2Progress | Message2PromptSuggestion | Message2QueueOperation | Message2RateLimitEvent | Message2Result | Message2System | Message2User | Message2WorktreeState | Message2Unknown;

export interface Message2Assistant {
  readonly type: 'assistant';
  readonly agentId?: string;
  readonly cwd?: string;
  readonly entrypoint?: string;
  readonly error?: string;
  readonly forkedFrom?: ForkedFrom;
  readonly gitBranch?: string;
  readonly isApiErrorMessage?: boolean;
  readonly isSidechain?: boolean;
  readonly line?: number;
  readonly message?: Message2AssistantMessage;
  readonly parentToolUseId?: string;
  readonly parentUuid?: string;
  readonly requestId?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly teamName?: string;
  readonly timestamp?: string;
  readonly usage?: AssistantUsage;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface ForkedFrom {
  readonly messageUuid?: string;
  readonly sessionId?: string;
}

export interface Message2AssistantMessage {
  readonly container?: unknown;
  readonly content?: Message2AssistantMessageContent[];
  readonly contextManagement?: ContextManagement;
  readonly id?: string;
  readonly model?: string;
  readonly role?: string;
  readonly stopReason?: string;
  readonly stopSequence?: string;
  readonly type?: string;
  readonly usage?: MessageUsage;
}

export type Message2AssistantMessageContentText = { readonly type: 'text' } & Text;
export type Message2AssistantMessageContentThinking = { readonly type: 'thinking' } & Thinking;
export type Message2AssistantMessageContentToolUse = { readonly type: 'tool_use' } & ToolUse;
export type Message2AssistantMessageContentUnknown = { readonly type: string; readonly [key: string]: unknown };
export type Message2AssistantMessageContent = Message2AssistantMessageContentText | Message2AssistantMessageContentThinking | Message2AssistantMessageContentToolUse | Message2AssistantMessageContentUnknown;

export interface Text {
  readonly text?: string;
}

export interface Thinking {
  readonly signature?: string;
  readonly thinking?: string;
}

export type ToolUseAgent = { readonly name: 'Agent' } & Agent;
export type ToolUseUnknown = { readonly name: string; readonly [key: string]: unknown };
export type ToolUse = ToolUseAgent | ToolUseAskUserQuestion | ToolUseBash | ToolUseCronCreate | ToolUseEdit | ToolUseEnterPlanMode | ToolUseEnterWorktree | ToolUseExitPlanMode | ToolUseExitWorktree | ToolUseGlob | ToolUseGrep | ToolUseRead | ToolUseSendMessage | ToolUseSkill | ToolUseTask | ToolUseTaskCreate | ToolUseTaskOutput | ToolUseTaskStop | ToolUseTaskUpdate | ToolUseTeamCreate | ToolUseTodoWrite | ToolUseToolSearch | ToolUseWebFetch | ToolUseWebSearch | ToolUseWrite | ToolUseUnknown;

export interface Agent {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: AgentInput;
}

export interface Caller {
  readonly type?: string;
}

export interface AgentInput {
  readonly description?: string;
  readonly isolation?: string;
  readonly mode?: string;
  readonly model?: string;
  readonly name?: string;
  readonly prompt?: string;
  readonly resume?: string;
  readonly runInBackground?: boolean;
  readonly subagentType?: string;
  readonly teamName?: string;
}

export interface ToolUseAskUserQuestion {
  readonly name: 'AskUserQuestion';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: AskUserQuestionInput;
}

export interface AskUserQuestionInput {
  readonly questions?: InputQuestions[];
}

export interface InputQuestions {
  readonly header?: string;
  readonly multiSelect?: boolean;
  readonly options?: Options[];
  readonly question?: string;
}

export interface Options {
  readonly description?: string;
  readonly label?: string;
  readonly preview?: string;
}

export interface ToolUseBash {
  readonly name: 'Bash';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolUseBashInput;
}

export interface ToolUseBashInput {
  readonly command?: string;
  readonly context?: number;
  readonly description?: string;
  readonly outputMode?: string;
  readonly path?: string;
  readonly pattern?: string;
  readonly runInBackground?: boolean;
  readonly timeout?: number;
}

export interface ToolUseCronCreate {
  readonly name: 'CronCreate';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: CronCreateInput;
}

export interface CronCreateInput {
  readonly cron?: string;
  readonly prompt?: string;
  readonly recurring?: boolean;
}

export interface ToolUseEdit {
  readonly name: 'Edit';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: EditInput;
}

export interface EditInput {
  readonly filePath?: string;
  readonly newString?: string;
  readonly oldString?: string;
  readonly replaceAll?: boolean;
}

export interface ToolUseEnterPlanMode {
  readonly name: 'EnterPlanMode';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: Record<string, unknown>;
}

export interface ToolUseEnterWorktree {
  readonly name: 'EnterWorktree';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: EnterWorktreeInput;
}

export interface EnterWorktreeInput {
  readonly name?: string;
}

export interface ToolUseExitPlanMode {
  readonly name: 'ExitPlanMode';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ExitPlanModeInput;
}

export interface ExitPlanModeInput {
  readonly allowedPrompts?: AllowedPrompts[];
  readonly plan?: string;
  readonly planFilePath?: string;
}

export interface AllowedPrompts {
  readonly prompt?: string;
  readonly tool?: string;
}

export interface ToolUseExitWorktree {
  readonly name: 'ExitWorktree';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ExitWorktreeInput;
}

export interface ExitWorktreeInput {
  readonly action?: string;
}

export interface ToolUseGlob {
  readonly name: 'Glob';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: GlobInput;
}

export interface GlobInput {
  readonly path?: string;
  readonly pattern?: string;
}

export interface ToolUseGrep {
  readonly name: 'Grep';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolUseGrepInput;
}

export interface ToolUseGrepInput {
  readonly A?: number;
  readonly B?: number;
  readonly C?: number;
  readonly I?: boolean;
  readonly N?: boolean;
  readonly context?: number;
  readonly filePath?: string;
  readonly glob?: string;
  readonly headLimit?: number;
  readonly limit?: number;
  readonly offset?: number;
  readonly outputMode?: string;
  readonly path?: string;
  readonly pattern?: string;
  readonly query?: string;
  readonly type?: string;
}

export interface ToolUseRead {
  readonly name: 'Read';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolUseReadInput;
}

export interface ToolUseReadInput {
  readonly filePath?: string;
  readonly limit?: Limit;
  readonly offset?: ToolUseReadInputOffset;
}

export type Limit = string | number | unknown;

export type ToolUseReadInputOffset = string | number | unknown;

export interface ToolUseSendMessage {
  readonly name: 'SendMessage';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: SendMessageInput;
}

export interface SendMessageInput {
  readonly approve?: boolean;
  readonly content?: string;
  readonly message?: InputMessage;
  readonly recipient?: string;
  readonly requestId?: string;
  readonly summary?: string;
  readonly to?: string;
  readonly type?: string;
}

export type InputMessage = string | MessageObject | unknown;

export interface MessageObject {
  readonly approve?: boolean;
  readonly reason?: string;
  readonly requestId?: string;
  readonly type?: string;
}

export interface ToolUseSkill {
  readonly name: 'Skill';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: SkillInput;
}

export interface SkillInput {
  readonly args?: string;
  readonly skill?: string;
}

export interface ToolUseTask {
  readonly name: 'Task';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TaskInput;
}

export interface TaskInput {
  readonly description?: string;
  readonly model?: string;
  readonly prompt?: string;
  readonly resume?: string;
  readonly runInBackground?: boolean;
  readonly subagentType?: string;
}

export interface ToolUseTaskCreate {
  readonly name: 'TaskCreate';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TaskCreateInput;
}

export interface TaskCreateInput {
  readonly activeForm?: string;
  readonly description?: string;
  readonly subject?: string;
}

export interface ToolUseTaskOutput {
  readonly name: 'TaskOutput';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TaskOutputInput;
}

export interface TaskOutputInput {
  readonly block?: boolean;
  readonly taskId?: string;
  readonly timeout?: number;
}

export interface ToolUseTaskStop {
  readonly name: 'TaskStop';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TaskStopInput;
}

export interface TaskStopInput {
  readonly taskId?: string;
}

export interface ToolUseTaskUpdate {
  readonly name: 'TaskUpdate';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TaskUpdateInput;
}

export interface TaskUpdateInput {
  readonly activeForm?: string;
  readonly addBlockedBy?: string[];
  readonly description?: string;
  readonly owner?: string;
  readonly status?: string;
  readonly taskId?: string;
}

export interface ToolUseTeamCreate {
  readonly name: 'TeamCreate';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TeamCreateInput;
}

export interface TeamCreateInput {
  readonly agentType?: string;
  readonly description?: string;
  readonly teamName?: string;
}

export interface ToolUseTodoWrite {
  readonly name: 'TodoWrite';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: TodoWriteInput;
}

export interface TodoWriteInput {
  readonly todos?: Todos;
}

export type Todos = string | TodosItem[] | unknown;

export interface TodosItem {
  readonly activeForm?: string;
  readonly content?: string;
  readonly status?: string;
}

export interface ToolUseToolSearch {
  readonly name: 'ToolSearch';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolSearchInput;
}

export interface ToolSearchInput {
  readonly maxResults?: number;
  readonly query?: string;
}

export interface ToolUseWebFetch {
  readonly name: 'WebFetch';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolUseWebFetchInput;
}

export interface ToolUseWebFetchInput {
  readonly prompt?: string;
  readonly url?: string;
}

export interface ToolUseWebSearch {
  readonly name: 'WebSearch';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolUseWebSearchInput;
}

export interface ToolUseWebSearchInput {
  readonly allowedDomains?: string[];
  readonly query?: string;
  readonly searchQuery?: string;
}

export interface ToolUseWrite {
  readonly name: 'Write';
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: WriteInput;
}

export interface WriteInput {
  readonly content?: string;
  readonly filePath?: string;
}

export interface ContextManagement {
  readonly appliedEdits?: unknown[];
}

export interface MessageUsage {
  readonly cacheCreation?: CacheCreation;
  readonly cacheCreationInputTokens?: number;
  readonly cacheReadInputTokens?: number;
  readonly inferenceGeo?: string;
  readonly inputTokens?: number;
  readonly iterations?: unknown[];
  readonly outputTokens?: number;
  readonly serverToolUse?: MessageUsageServerToolUse;
  readonly serviceTier?: string;
  readonly speed?: string;
}

export interface CacheCreation {
  readonly ephemeral1hInputTokens?: number;
  readonly ephemeral5mInputTokens?: number;
}

export interface MessageUsageServerToolUse {
  readonly webFetchRequests?: number;
  readonly webSearchRequests?: number;
}

export interface AssistantUsage {
  readonly cacheCreation?: CacheCreation;
  readonly cacheCreationInputTokens?: number;
  readonly cacheReadInputTokens?: number;
  readonly inferenceGeo?: string;
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly serviceTier?: string;
}

export interface CustomTitle {
  readonly customTitle?: string;
  readonly sessionId?: string;
}

export interface FileHistorySnapshot {
  readonly isSnapshotUpdate?: boolean;
  readonly messageId?: string;
  readonly snapshot?: Snapshot;
}

export interface Snapshot {
  readonly messageId?: string;
  readonly timestamp?: string;
  readonly trackedFileBackups?: Record<string, TrackedFileBackupsValue>;
}

export interface TrackedFileBackupsValue {
  readonly backupFileName?: string;
  readonly backupTime?: string;
  readonly version?: number;
}

export interface LastPrompt {
  readonly lastPrompt?: string;
  readonly sessionId?: string;
}

export interface Progress {
  readonly agentId?: string;
  readonly cwd?: string;
  readonly data?: Data;
  readonly entrypoint?: string;
  readonly forkedFrom?: ForkedFrom;
  readonly gitBranch?: string;
  readonly isSidechain?: boolean;
  readonly parentToolUseId?: string;
  readonly parentUuid?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly teamName?: string;
  readonly timestamp?: string;
  readonly toolUseId?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export type DataAgentProgress = { readonly type: 'agent_progress' } & AgentProgress;
export type DataBashProgress = { readonly type: 'bash_progress' } & BashProgress;
export type DataHookProgress = { readonly type: 'hook_progress' } & HookProgress;
export type DataQueryUpdate = { readonly type: 'query_update' } & QueryUpdate;
export type DataSearchResultsReceived = { readonly type: 'search_results_received' } & SearchResultsReceived;
export type DataWaitingForTask = { readonly type: 'waiting_for_task' } & WaitingForTask;
export type DataUnknown = { readonly type: string; readonly [key: string]: unknown };
export type Data = DataAgentProgress | DataBashProgress | DataHookProgress | DataQueryUpdate | DataSearchResultsReceived | DataWaitingForTask | DataUnknown;

export interface AgentProgress {
  readonly agentId?: string;
  readonly message?: AgentProgressMessage;
  readonly normalizedMessages?: unknown[];
  readonly prompt?: string;
  readonly resume?: string;
}

export type AgentProgressMessageAssistant = { readonly type: 'assistant' } & MessageAssistant;
export type AgentProgressMessageUser = { readonly type: 'user' } & MessageUser;
export type AgentProgressMessageUnknown = { readonly type: string; readonly [key: string]: unknown };
export type AgentProgressMessage = AgentProgressMessageAssistant | AgentProgressMessageUser | AgentProgressMessageUnknown;

export interface MessageAssistant {
  readonly message?: MessageAssistantMessage;
  readonly requestId?: string;
  readonly timestamp?: string;
  readonly uuid?: string;
}

export interface MessageAssistantMessage {
  readonly content?: MessageAssistantMessageContent[];
  readonly contextManagement?: unknown;
  readonly id?: string;
  readonly model?: string;
  readonly role?: string;
  readonly stopReason?: string;
  readonly stopSequence?: unknown;
  readonly type?: string;
  readonly usage?: AssistantUsage;
}

export type MessageAssistantMessageContentBash = { readonly name: 'Bash' } & ContentBash;
export type MessageAssistantMessageContentEdit = { readonly name: 'Edit' } & ContentEdit;
export type MessageAssistantMessageContentGlob = { readonly name: 'Glob' } & ContentGlob;
export type MessageAssistantMessageContentGrep = { readonly name: 'Grep' } & ContentGrep;
export type MessageAssistantMessageContentRead = { readonly name: 'Read' } & ContentRead;
export type MessageAssistantMessageContentToolSearch = { readonly name: 'ToolSearch' } & ContentToolSearch;
export type MessageAssistantMessageContentWebFetch = { readonly name: 'WebFetch' } & ContentWebFetch;
export type MessageAssistantMessageContentWebSearch = { readonly name: 'WebSearch' } & ContentWebSearch;
export type MessageAssistantMessageContentWrite = { readonly name: 'Write' } & ContentWrite;
export type MessageAssistantMessageContentUnknown = { readonly name: string; readonly [key: string]: unknown };
export type MessageAssistantMessageContent = MessageAssistantMessageContentBash | MessageAssistantMessageContentEdit | MessageAssistantMessageContentGlob | MessageAssistantMessageContentGrep | MessageAssistantMessageContentRead | MessageAssistantMessageContentToolSearch | MessageAssistantMessageContentWebFetch | MessageAssistantMessageContentWebSearch | MessageAssistantMessageContentWrite | MessageAssistantMessageContentUnknown;

export interface ContentBash {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ContentBashInput;
  readonly type?: string;
}

export interface ContentBashInput {
  readonly command?: string;
  readonly context?: number;
  readonly description?: string;
  readonly outputMode?: string;
  readonly path?: string;
  readonly pattern?: string;
  readonly timeout?: number;
}

export interface ContentEdit {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: EditInput;
  readonly type?: string;
}

export interface ContentGlob {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: GlobInput;
  readonly type?: string;
}

export interface ContentGrep {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ContentGrepInput;
  readonly type?: string;
}

export interface ContentGrepInput {
  readonly A?: number;
  readonly C?: number;
  readonly I?: boolean;
  readonly N?: boolean;
  readonly context?: number;
  readonly glob?: string;
  readonly headLimit?: number;
  readonly outputMode?: string;
  readonly path?: string;
  readonly pattern?: string;
  readonly type?: string;
}

export interface ContentRead {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ContentReadInput;
  readonly type?: string;
}

export interface ContentReadInput {
  readonly filePath?: string;
  readonly limit?: number;
  readonly offset?: ContentReadInputOffset;
}

export type ContentReadInputOffset = string | number | unknown;

export interface ContentToolSearch {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ToolSearchInput;
  readonly type?: string;
}

export interface ContentWebFetch {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ContentWebFetchInput;
  readonly type?: string;
}

export interface ContentWebFetchInput {
  readonly prompt?: string;
  readonly url?: string;
}

export interface ContentWebSearch {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: ContentWebSearchInput;
  readonly type?: string;
}

export interface ContentWebSearchInput {
  readonly allowedDomains?: string[];
  readonly query?: string;
}

export interface ContentWrite {
  readonly caller?: Caller;
  readonly id?: string;
  readonly input?: WriteInput;
  readonly type?: string;
}

export interface MessageUser {
  readonly message?: MessageUserMessage;
  readonly timestamp?: string;
  readonly toolUseResult?: string;
  readonly uuid?: string;
}

export interface MessageUserMessage {
  readonly content?: MessageUserMessageContent[];
  readonly role?: string;
}

export type MessageUserMessageContentText = { readonly type: 'text' } & Text;
export type MessageUserMessageContentToolResult = { readonly type: 'tool_result' } & ContentToolResult;
export type MessageUserMessageContentUnknown = { readonly type: string; readonly [key: string]: unknown };
export type MessageUserMessageContent = MessageUserMessageContentText | MessageUserMessageContentToolResult | MessageUserMessageContentUnknown;

export interface ContentToolResult {
  readonly content?: ContentToolResultContent;
  readonly isError?: boolean;
  readonly toolUseId?: string;
}

export type ContentToolResultContent = string | ContentToolResultContentItem[] | unknown;

export interface ContentToolResultContentItem {
  readonly toolName?: string;
  readonly type?: string;
}

export interface BashProgress {
  readonly elapsedTimeSeconds?: number;
  readonly fullOutput?: string;
  readonly output?: string;
  readonly taskId?: string;
  readonly timeoutMs?: number;
  readonly totalBytes?: number;
  readonly totalLines?: number;
}

export interface HookProgress {
  readonly command?: string;
  readonly hookEvent?: string;
  readonly hookName?: string;
}

export interface QueryUpdate {
  readonly query?: string;
}

export interface SearchResultsReceived {
  readonly query?: string;
  readonly resultCount?: number;
}

export interface WaitingForTask {
  readonly taskDescription?: string;
  readonly taskType?: string;
}

export interface PromptSuggestion {
  readonly sessionId?: string;
  readonly suggestion?: string;
  readonly uuid?: string;
}

export type QueueOperationDequeue = { readonly operation: 'dequeue' } & Dequeue;
export type QueueOperationEnqueue = { readonly operation: 'enqueue' } & Enqueue;
export type QueueOperationRemove = { readonly operation: 'remove' } & Dequeue;
export type QueueOperationUnknown = { readonly operation: string; readonly [key: string]: unknown };
export type QueueOperation = QueueOperationDequeue | QueueOperationEnqueue | QueueOperationRemove | QueueOperationUnknown;

export interface Dequeue {
  readonly sessionId?: string;
  readonly timestamp?: string;
}

export interface Enqueue {
  readonly content?: string;
  readonly sessionId?: string;
  readonly timestamp?: string;
}

export interface RateLimitEvent {
  readonly rateLimitInfo?: RateLimitInfo;
  readonly sessionId?: string;
  readonly uuid?: string;
}

export interface RateLimitInfo {
  readonly isUsingOverage?: boolean;
  readonly overageDisabledReason?: string;
  readonly overageStatus?: string;
  readonly rateLimitType?: string;
  readonly resetsAt?: number;
  readonly status?: string;
}

export type ResultErrorDuringExecution = { readonly subtype: 'error_during_execution' } & ErrorDuringExecution;
export type ResultSuccess = { readonly subtype: 'success' } & Success;
export type ResultUnknown = { readonly subtype: string; readonly [key: string]: unknown };
export type Result = ResultErrorDuringExecution | ResultSuccess | ResultUnknown;

export interface ErrorDuringExecution {
  readonly durationApiMs?: number;
  readonly durationMs?: number;
  readonly errors?: string[];
  readonly fastModeState?: string;
  readonly isError?: boolean;
  readonly modelUsage?: Record<string, ModelUsageValue>;
  readonly numTurns?: number;
  readonly permissionDenials?: ErrorDuringExecutionPermissionDenials[];
  readonly sessionId?: string;
  readonly stopReason?: string;
  readonly totalCostUsd?: number;
  readonly usage?: ErrorDuringExecutionUsage;
  readonly uuid?: string;
}

export interface ModelUsageValue {
  readonly cacheCreationInputTokens?: number;
  readonly cacheReadInputTokens?: number;
  readonly contextWindow?: number;
  readonly costUsd?: number;
  readonly inputTokens?: number;
  readonly maxOutputTokens?: number;
  readonly outputTokens?: number;
  readonly webSearchRequests?: number;
}

export interface ErrorDuringExecutionPermissionDenials {
  readonly toolInput?: ErrorDuringExecutionPermissionDenialsToolInput;
  readonly toolName?: string;
  readonly toolUseId?: string;
}

export interface ErrorDuringExecutionPermissionDenialsToolInput {
  readonly allowedPrompts?: AllowedPrompts[];
  readonly command?: string;
  readonly description?: string;
  readonly filePath?: string;
  readonly newString?: string;
  readonly oldString?: string;
  readonly plan?: string;
  readonly planFilePath?: string;
  readonly replaceAll?: boolean;
  readonly timeout?: number;
}

export interface ErrorDuringExecutionUsage {
  readonly cacheCreation?: CacheCreation;
  readonly cacheCreationInputTokens?: number;
  readonly cacheReadInputTokens?: number;
  readonly inferenceGeo?: string;
  readonly inputTokens?: number;
  readonly iterations?: unknown[];
  readonly outputTokens?: number;
  readonly serverToolUse?: MessageUsageServerToolUse;
  readonly serviceTier?: string;
  readonly speed?: string;
}

export interface Success {
  readonly durationApiMs?: number;
  readonly durationMs?: number;
  readonly fastModeState?: string;
  readonly isError?: boolean;
  readonly modelUsage?: Record<string, ModelUsageValue>;
  readonly numTurns?: number;
  readonly permissionDenials?: SuccessPermissionDenials[];
  readonly result?: string;
  readonly sessionId?: string;
  readonly stopReason?: string;
  readonly totalCostUsd?: number;
  readonly usage?: ErrorDuringExecutionUsage;
  readonly uuid?: string;
}

export interface SuccessPermissionDenials {
  readonly toolInput?: SuccessPermissionDenialsToolInput;
  readonly toolName?: string;
  readonly toolUseId?: string;
}

export interface SuccessPermissionDenialsToolInput {
  readonly content?: string;
  readonly filePath?: string;
  readonly plan?: string;
  readonly planFilePath?: string;
}

export type SystemApiError = { readonly subtype: 'api_error' } & ApiError;
export type SystemCompactBoundary = { readonly subtype: 'compact_boundary' } & CompactBoundary;
export type SystemInformational = { readonly subtype: 'informational' } & Informational;
export type SystemInit = { readonly subtype: 'init' } & Init;
export type SystemLocalCommand = { readonly subtype: 'local_command' } & LocalCommand;
export type SystemMicrocompactBoundary = { readonly subtype: 'microcompact_boundary' } & MicrocompactBoundary;
export type SystemStatus = { readonly subtype: 'status' } & Status;
export type SystemTaskNotification = { readonly subtype: 'task_notification' } & TaskNotification;
export type SystemTaskProgress = { readonly subtype: 'task_progress' } & TaskProgress;
export type SystemTaskStarted = { readonly subtype: 'task_started' } & TaskStarted;
export type SystemTurnDuration = { readonly subtype: 'turn_duration' } & TurnDuration;
export type SystemUnknown = { readonly subtype: string; readonly [key: string]: unknown };
export type System = SystemApiError | SystemCompactBoundary | SystemInformational | SystemInit | SystemLocalCommand | SystemMicrocompactBoundary | SystemStatus | SystemTaskNotification | SystemTaskProgress | SystemTaskStarted | SystemTurnDuration | SystemUnknown;

export interface ApiError {
  readonly cause?: Cause;
  readonly cwd?: string;
  readonly entrypoint?: string;
  readonly error?: ApiErrorError;
  readonly gitBranch?: string;
  readonly isSidechain?: boolean;
  readonly level?: string;
  readonly maxRetries?: number;
  readonly parentUuid?: string;
  readonly retryAttempt?: number;
  readonly retryInMs?: number;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface Cause {
  readonly code?: string;
  readonly errno?: number;
  readonly path?: string;
}

export interface ApiErrorError {
  readonly cause?: Cause;
  readonly headers?: ErrorHeaders;
  readonly requestId?: unknown;
  readonly status?: number;
}

export interface ErrorHeaders {
  readonly cfCacheStatus?: string;
  readonly cfRay?: string;
  readonly connection?: string;
  readonly contentLength?: string;
  readonly contentSecurityPolicy?: string;
  readonly contentType?: string;
  readonly date?: string;
  readonly server?: string;
  readonly xRobotsTag?: string;
}

export interface CompactBoundary {
  readonly compactMetadata?: CompactMetadata;
  readonly content?: string;
  readonly cwd?: string;
  readonly gitBranch?: string;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly level?: string;
  readonly logicalParentUuid?: string;
  readonly parentUuid?: unknown;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface CompactMetadata {
  readonly preCompactDiscoveredTools?: string[];
  readonly preTokens?: number;
  readonly trigger?: string;
}

export interface Informational {
  readonly content?: string;
  readonly cwd?: string;
  readonly gitBranch?: string;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly level?: string;
  readonly parentUuid?: string;
  readonly sessionId?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface Init {
  readonly agents?: string[];
  readonly apiKeySource?: string;
  readonly claudeCodeVersion?: string;
  readonly cwd?: string;
  readonly fastModeState?: string;
  readonly mcpServers?: McpServers[];
  readonly model?: string;
  readonly outputStyle?: string;
  readonly permissionMode?: string;
  readonly plugins?: Plugins[];
  readonly sessionId?: string;
  readonly skills?: string[];
  readonly slashCommands?: string[];
  readonly tools?: string[];
  readonly uuid?: string;
}

export interface McpServers {
  readonly name?: string;
  readonly status?: string;
}

export interface Plugins {
  readonly name?: string;
  readonly path?: string;
}

export interface LocalCommand {
  readonly agentId?: string;
  readonly content?: string;
  readonly cwd?: string;
  readonly entrypoint?: string;
  readonly forkedFrom?: ForkedFrom;
  readonly gitBranch?: string;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly level?: string;
  readonly parentUuid?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly teamName?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface MicrocompactBoundary {
  readonly content?: string;
  readonly cwd?: string;
  readonly gitBranch?: string;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly level?: string;
  readonly microcompactMetadata?: MicrocompactMetadata;
  readonly parentUuid?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface MicrocompactMetadata {
  readonly clearedAttachmentUuiDs?: unknown[];
  readonly compactedToolIds?: unknown[];
  readonly preTokens?: number;
  readonly tokensSaved?: number;
  readonly trigger?: string;
}

export interface Status {
  readonly permissionMode?: string;
  readonly sessionId?: string;
  readonly status?: unknown;
  readonly uuid?: string;
}

export interface TaskNotification {
  readonly outputFile?: string;
  readonly sessionId?: string;
  readonly status?: string;
  readonly summary?: string;
  readonly taskId?: string;
  readonly toolUseId?: string;
  readonly usage?: TaskNotificationUsage;
  readonly uuid?: string;
}

export interface TaskNotificationUsage {
  readonly durationMs?: number;
  readonly toolUses?: number;
  readonly totalTokens?: number;
}

export interface TaskProgress {
  readonly description?: string;
  readonly lastToolName?: string;
  readonly sessionId?: string;
  readonly taskId?: string;
  readonly toolUseId?: string;
  readonly usage?: TaskNotificationUsage;
  readonly uuid?: string;
}

export interface TaskStarted {
  readonly description?: string;
  readonly prompt?: string;
  readonly sessionId?: string;
  readonly taskId?: string;
  readonly taskType?: string;
  readonly toolUseId?: string;
  readonly uuid?: string;
}

export interface TurnDuration {
  readonly cwd?: string;
  readonly durationMs?: number;
  readonly entrypoint?: string;
  readonly forkedFrom?: ForkedFrom;
  readonly gitBranch?: string;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly messageCount?: number;
  readonly parentUuid?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly teamName?: string;
  readonly timestamp?: string;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface Message2User {
  readonly type: 'user';
  readonly agentId?: string;
  readonly cwd?: string;
  readonly entrypoint?: string;
  readonly forkedFrom?: ForkedFrom;
  readonly gitBranch?: string;
  readonly imagePasteIds?: number[];
  readonly isCompactSummary?: boolean;
  readonly isMeta?: boolean;
  readonly isSidechain?: boolean;
  readonly isSynthetic?: boolean;
  readonly isVisibleInTranscriptOnly?: boolean;
  readonly message?: Message2UserMessage;
  readonly origin?: Origin;
  readonly parentToolUseId?: string;
  readonly parentUuid?: string;
  readonly permissionMode?: string;
  readonly planContent?: string;
  readonly promptId?: string;
  readonly sessionId?: string;
  readonly slug?: string;
  readonly sourceToolAssistantUuid?: string;
  readonly sourceToolUseId?: string;
  readonly teamName?: string;
  readonly timestamp?: string;
  readonly todos?: unknown[];
  readonly toolUseResult?: ToolUseResult;
  readonly userType?: string;
  readonly uuid?: string;
  readonly version?: string;
}

export interface Message2UserMessage {
  readonly content?: Message2UserMessageContent;
  readonly role?: string;
}

export type Message2UserMessageContent = string | MessageContentItem[] | unknown;

export type MessageContentItemImage = { readonly type: 'image' } & Image;
export type MessageContentItemText = { readonly type: 'text' } & Text;
export type MessageContentItemToolResult = { readonly type: 'tool_result' } & ItemToolResult;
export type MessageContentItemUnknown = { readonly type: string; readonly [key: string]: unknown };
export type MessageContentItem = MessageContentItemImage | MessageContentItemText | MessageContentItemToolResult | MessageContentItemUnknown;

export interface Image {
  readonly source?: Source;
}

export interface Source {
  readonly data?: string;
  readonly mediaType?: string;
  readonly type?: string;
}

export interface ItemToolResult {
  readonly content?: ItemToolResultContent;
  readonly isError?: boolean;
  readonly toolUseId?: string;
}

export type ItemToolResultContent = string | ItemToolResultContentItem[] | unknown;

export type ItemToolResultContentItemImage = { readonly type: 'image' } & Image;
export type ItemToolResultContentItemText = { readonly type: 'text' } & Text;
export type ItemToolResultContentItemToolReference = { readonly type: 'tool_reference' } & ToolReference;
export type ItemToolResultContentItemUnknown = { readonly type: string; readonly [key: string]: unknown };
export type ItemToolResultContentItem = ItemToolResultContentItemImage | ItemToolResultContentItemText | ItemToolResultContentItemToolReference | ItemToolResultContentItemUnknown;

export interface ToolReference {
  readonly toolName?: string;
}

export interface Origin {
  readonly kind?: string;
}

export type ToolUseResult = string | ToolUseResultObject | unknown;

export type ToolUseResultObjectAskUserQuestion = { readonly _resolved_tool: 'AskUserQuestion' } & ObjectAskUserQuestion & { readonly _origin?: ToolUseAskUserQuestion };
export type ToolUseResultObjectBash = { readonly _resolved_tool: 'Bash' } & ObjectBash & { readonly _origin?: ToolUseBash };
export type ToolUseResultObjectCronCreate = { readonly _resolved_tool: 'CronCreate' } & ObjectCronCreate & { readonly _origin?: ToolUseCronCreate };
export type ToolUseResultObjectEdit = { readonly _resolved_tool: 'Edit' } & ObjectEdit & { readonly _origin?: ToolUseEdit };
export type ToolUseResultObjectEnterPlanMode = { readonly _resolved_tool: 'EnterPlanMode' } & ObjectEnterPlanMode & { readonly _origin?: ToolUseEnterPlanMode };
export type ToolUseResultObjectEnterWorktree = { readonly _resolved_tool: 'EnterWorktree' } & ObjectEnterWorktree & { readonly _origin?: ToolUseEnterWorktree };
export type ToolUseResultObjectExitPlanMode = { readonly _resolved_tool: 'ExitPlanMode' } & ObjectExitPlanMode & { readonly _origin?: ToolUseExitPlanMode };
export type ToolUseResultObjectExitWorktree = { readonly _resolved_tool: 'ExitWorktree' } & ObjectExitWorktree & { readonly _origin?: ToolUseExitWorktree };
export type ToolUseResultObjectGlob = { readonly _resolved_tool: 'Glob' } & ObjectGlob & { readonly _origin?: ToolUseGlob };
export type ToolUseResultObjectGrep = { readonly _resolved_tool: 'Grep' } & ObjectGrep & { readonly _origin?: ToolUseGrep };
export type ToolUseResultObjectSendMessage = { readonly _resolved_tool: 'SendMessage' } & ObjectSendMessage & { readonly _origin?: ToolUseSendMessage };
export type ToolUseResultObjectSkill = { readonly _resolved_tool: 'Skill' } & ObjectSkill & { readonly _origin?: ToolUseSkill };
export type ToolUseResultObjectTask = { readonly _resolved_tool: 'Task' } & ObjectTask & { readonly _origin?: ToolUseTask };
export type ToolUseResultObjectTaskCreate = { readonly _resolved_tool: 'TaskCreate' } & ObjectTaskCreate & { readonly _origin?: ToolUseTaskCreate };
export type ToolUseResultObjectTaskOutput = { readonly _resolved_tool: 'TaskOutput' } & ObjectTaskOutput & { readonly _origin?: ToolUseTaskOutput };
export type ToolUseResultObjectTaskStop = { readonly _resolved_tool: 'TaskStop' } & ObjectTaskStop & { readonly _origin?: ToolUseTaskStop };
export type ToolUseResultObjectTaskUpdate = { readonly _resolved_tool: 'TaskUpdate' } & ObjectTaskUpdate & { readonly _origin?: ToolUseTaskUpdate };
export type ToolUseResultObjectTeamCreate = { readonly _resolved_tool: 'TeamCreate' } & ObjectTeamCreate & { readonly _origin?: ToolUseTeamCreate };
export type ToolUseResultObjectTodoWrite = { readonly _resolved_tool: 'TodoWrite' } & ObjectTodoWrite & { readonly _origin?: ToolUseTodoWrite };
export type ToolUseResultObjectToolSearch = { readonly _resolved_tool: 'ToolSearch' } & ObjectToolSearch & { readonly _origin?: ToolUseToolSearch };
export type ToolUseResultObjectWebFetch = { readonly _resolved_tool: 'WebFetch' } & ObjectWebFetch & { readonly _origin?: ToolUseWebFetch };
export type ToolUseResultObjectWebSearch = { readonly _resolved_tool: 'WebSearch' } & ObjectWebSearch & { readonly _origin?: ToolUseWebSearch };
export type ToolUseResultObjectWrite = { readonly _resolved_tool: 'Write' } & ObjectWrite & { readonly _origin?: ToolUseWrite };
export type ToolUseResultObjectUnknown = { readonly _resolved_tool: string; readonly _raw?: Record<string, unknown>; readonly _origin?: ToolUse; readonly [key: string]: unknown };
export type ToolUseResultObject = ToolUseResultObjectAskUserQuestion | ToolUseResultObjectBash | ToolUseResultObjectCronCreate | ToolUseResultObjectEdit | ToolUseResultObjectEnterPlanMode | ToolUseResultObjectEnterWorktree | ToolUseResultObjectExitPlanMode | ToolUseResultObjectExitWorktree | ToolUseResultObjectGlob | ToolUseResultObjectGrep | ToolUseResultObjectSendMessage | ToolUseResultObjectSkill | ToolUseResultObjectTask | ToolUseResultObjectTaskCreate | ToolUseResultObjectTaskOutput | ToolUseResultObjectTaskStop | ToolUseResultObjectTaskUpdate | ToolUseResultObjectTeamCreate | ToolUseResultObjectTodoWrite | ToolUseResultObjectToolSearch | ToolUseResultObjectWebFetch | ToolUseResultObjectWebSearch | ToolUseResultObjectWrite | ToolUseResultObjectUnknown;

export interface ObjectAskUserQuestion {
  readonly annotations?: Record<string, AnnotationsValue>;
  readonly answers?: Record<string, string>;
  readonly questions?: AskUserQuestionQuestions[];
}

export interface AnnotationsValue {
  readonly notes?: string;
  readonly preview?: string;
}

export interface AskUserQuestionQuestions {
  readonly header?: string;
  readonly multiSelect?: boolean;
  readonly options?: Options[];
  readonly question?: string;
}

export interface ObjectBash {
  readonly assistantAutoBackgrounded?: boolean;
  readonly backgroundTaskId?: string;
  readonly backgroundedByUser?: boolean;
  readonly interrupted?: boolean;
  readonly isImage?: boolean;
  readonly noOutputExpected?: boolean;
  readonly persistedOutputPath?: string;
  readonly persistedOutputSize?: number;
  readonly returnCodeInterpretation?: string;
  readonly stderr?: string;
  readonly stdout?: string;
  readonly tokenSaverOutput?: string;
}

export interface ObjectCronCreate {
  readonly durable?: boolean;
  readonly humanSchedule?: string;
  readonly id?: string;
  readonly recurring?: boolean;
}

export interface ObjectEdit {
  readonly filePath?: string;
  readonly newString?: string;
  readonly oldString?: string;
  readonly originalFile?: string;
  readonly replaceAll?: boolean;
  readonly structuredPatch?: StructuredPatch[];
  readonly userModified?: boolean;
}

export interface StructuredPatch {
  readonly lines?: string[];
  readonly newLines?: number;
  readonly newStart?: number;
  readonly oldLines?: number;
  readonly oldStart?: number;
}

export interface ObjectEnterPlanMode {
  readonly message?: string;
}

export interface ObjectEnterWorktree {
  readonly message?: string;
  readonly worktreeBranch?: string;
  readonly worktreePath?: string;
}

export interface ObjectExitPlanMode {
  readonly filePath?: string;
  readonly isAgent?: boolean;
  readonly plan?: string;
}

export interface ObjectExitWorktree {
  readonly action?: string;
  readonly message?: string;
  readonly originalCwd?: string;
  readonly worktreeBranch?: string;
  readonly worktreePath?: string;
}

export interface ObjectGlob {
  readonly durationMs?: number;
  readonly filenames?: string[];
  readonly numFiles?: number;
  readonly truncated?: boolean;
}

export interface ObjectGrep {
  readonly appliedLimit?: number;
  readonly appliedOffset?: number;
  readonly content?: string;
  readonly filenames?: string[];
  readonly mode?: string;
  readonly numFiles?: number;
  readonly numLines?: number;
  readonly numMatches?: number;
}

export interface ObjectSendMessage {
  readonly message?: string;
  readonly requestId?: string;
  readonly routing?: Routing;
  readonly success?: boolean;
  readonly target?: string;
}

export interface Routing {
  readonly content?: string;
  readonly sender?: string;
  readonly senderColor?: string;
  readonly summary?: string;
  readonly target?: string;
  readonly targetColor?: string;
}

export interface ObjectSkill {
  readonly allowedTools?: string[];
  readonly commandName?: string;
  readonly success?: boolean;
}

export interface ObjectTask {
  readonly agentId?: string;
  readonly canReadOutputFile?: boolean;
  readonly content?: TaskContent[];
  readonly description?: string;
  readonly isAsync?: boolean;
  readonly outputFile?: string;
  readonly prompt?: string;
  readonly status?: string;
  readonly totalDurationMs?: number;
  readonly totalTokens?: number;
  readonly totalToolUseCount?: number;
  readonly usage?: TaskUsage;
}

export interface TaskContent {
  readonly text?: string;
  readonly type?: string;
}

export interface TaskUsage {
  readonly cacheCreation?: CacheCreation;
  readonly cacheCreationInputTokens?: number;
  readonly cacheReadInputTokens?: number;
  readonly inferenceGeo?: string;
  readonly inputTokens?: number;
  readonly iterations?: unknown[];
  readonly outputTokens?: number;
  readonly serverToolUse?: TaskUsageServerToolUse;
  readonly serviceTier?: string;
  readonly speed?: string;
}

export interface TaskUsageServerToolUse {
  readonly webFetchRequests?: number;
  readonly webSearchRequests?: number;
}

export interface ObjectTaskCreate {
  readonly task?: TaskCreateTask;
}

export interface TaskCreateTask {
  readonly id?: string;
  readonly subject?: string;
}

export interface ObjectTaskOutput {
  readonly retrievalStatus?: string;
  readonly task?: TaskOutputTask;
}

export interface TaskOutputTask {
  readonly description?: string;
  readonly exitCode?: number;
  readonly output?: string;
  readonly status?: string;
  readonly taskId?: string;
  readonly taskType?: string;
}

export interface ObjectTaskStop {
  readonly command?: string;
  readonly message?: string;
  readonly taskId?: string;
  readonly taskType?: string;
}

export interface ObjectTaskUpdate {
  readonly error?: string;
  readonly statusChange?: StatusChange;
  readonly success?: boolean;
  readonly taskId?: string;
  readonly updatedFields?: string[];
  readonly verificationNudgeNeeded?: boolean;
}

export interface StatusChange {
  readonly from?: string;
  readonly to?: string;
}

export interface ObjectTeamCreate {
  readonly leadAgentId?: string;
  readonly teamFilePath?: string;
  readonly teamName?: string;
}

export interface ObjectTodoWrite {
  readonly newTodos?: NewTodos[];
  readonly oldTodos?: NewTodos[];
  readonly verificationNudgeNeeded?: boolean;
}

export interface NewTodos {
  readonly activeForm?: string;
  readonly content?: string;
  readonly status?: string;
}

export interface ObjectToolSearch {
  readonly matches?: string[];
  readonly query?: string;
  readonly totalDeferredTools?: number;
}

export interface ObjectWebFetch {
  readonly bytes?: number;
  readonly code?: number;
  readonly codeText?: string;
  readonly durationMs?: number;
  readonly result?: string;
  readonly url?: string;
}

export interface ObjectWebSearch {
  readonly durationSeconds?: number;
  readonly query?: string;
  readonly results?: Results[];
}

export type Results = string | ResultsObject | unknown;

export interface ResultsObject {
  readonly content?: ObjectContent[];
  readonly toolUseId?: string;
}

export interface ObjectContent {
  readonly title?: string;
  readonly url?: string;
}

export interface ObjectWrite {
  readonly content?: string;
  readonly filePath?: string;
  readonly originalFile?: string;
  readonly structuredPatch?: StructuredPatch[];
  readonly type?: string;
}

export interface WorktreeState {
  readonly sessionId?: string;
  readonly worktreeSession?: WorktreeSession;
}

export interface WorktreeSession {
  readonly originalBranch?: string;
  readonly originalCwd?: string;
  readonly originalHeadCommit?: string;
  readonly sessionId?: string;
  readonly worktreeBranch?: string;
  readonly worktreeName?: string;
  readonly worktreePath?: string;
}
