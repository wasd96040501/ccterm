import type { ChatMessage } from './src/types/message.ts'

let id = 0
const nextId = () => `msg-${id++}`
const ts = () => Date.now() - (200 - id) * 60000

const msg = (type: 'user' | 'assistant', content: string): ChatMessage => ({
  type,
  id: nextId(),
  content,
  timestamp: ts(),
} as ChatMessage)

export const fixtureMessages: ChatMessage[] = [
  // --- User question ---
  msg('user', '帮我把 utils.ts 里的 formatDate 函数改成支持自定义格式'),

  msg('assistant', '好的，让我先读取文件看看当前的实现。'),

  // --- Read tool: running ---
  {
    type: 'readTool',
    id: nextId(),
    filePath: 'src/utils/formatDate.ts',
    content: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Read tool: success ---
  {
    type: 'readTool',
    id: nextId(),
    filePath: 'src/utils/formatDate.ts',
    content: `export function formatDate(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return \`\${year}-\${month}-\${day}\`
}`,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  msg('assistant', '了解了，现在来修改这个函数。'),

  // --- Edit tool: success (existing) ---
  {
    type: 'editTool',
    id: nextId(),
    filePath: 'src/utils/formatDate.ts',
    structuredPatch: [
      {
        oldStart: 1,
        newStart: 1,
        lines: [
          '-export function formatDate(date: Date): string {',
          '-  const year = date.getFullYear()',
          '-  const month = String(date.getMonth() + 1).padStart(2, \'0\')',
          '-  const day = String(date.getDate()).padStart(2, \'0\')',
          "-  return `${year}-${month}-${day}`",
          '+export function formatDate(date: Date, format = \'YYYY-MM-DD\'): string {',
          '+  const year = String(date.getFullYear())',
          '+  const month = String(date.getMonth() + 1).padStart(2, \'0\')',
          '+  const day = String(date.getDate()).padStart(2, \'0\')',
          '+  const hours = String(date.getHours()).padStart(2, \'0\')',
          '+  const minutes = String(date.getMinutes()).padStart(2, \'0\')',
          '+  const seconds = String(date.getSeconds()).padStart(2, \'0\')',
          '+  return format',
          '+    .replace(\'YYYY\', year)',
          '+    .replace(\'MM\', month)',
          '+    .replace(\'DD\', day)',
          '+    .replace(\'HH\', hours)',
          '+    .replace(\'mm\', minutes)',
          '+    .replace(\'ss\', seconds)',
          ' }',
        ],
      },
    ],
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Write tool: new file ---
  {
    type: 'writeTool',
    id: nextId(),
    filePath: 'src/utils/__tests__/formatDate.test.ts',
    isNewFile: true,
    structuredPatch: [
      {
        oldStart: 0,
        newStart: 1,
        lines: [
          "+import { formatDate } from '../formatDate'",
          '+',
          "+describe('formatDate', () => {",
          "+  it('should format with default pattern', () => {",
          "+    const date = new Date('2024-03-14T10:30:00')",
          "+    expect(formatDate(date)).toBe('2024-03-14')",
          '+  })',
          '+',
          "+  it('should format with custom pattern', () => {",
          "+    const date = new Date('2024-03-14T10:30:45')",
          "+    expect(formatDate(date, 'DD/MM/YYYY HH:mm')).toBe('14/03/2024 10:30')",
          '+  })',
          '+})',
        ],
      },
    ],
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  msg('assistant', '现在运行测试看看。'),

  // --- Bash tool: running ---
  {
    type: 'bashTool',
    id: nextId(),
    command: 'bun test src/utils/__tests__/formatDate.test.ts',
    stdout: null,
    stderr: null,
    interrupted: false,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Bash tool: success ---
  {
    type: 'bashTool',
    id: nextId(),
    command: 'bun test src/utils/__tests__/formatDate.test.ts',
    stdout: `bun test v1.1.0

  src/utils/__tests__/formatDate.test.ts:
    formatDate
      ✓ should format with default pattern (0.12ms)
      ✓ should format with custom pattern (0.05ms)

  2 pass
  0 fail`,
    stderr: null,
    interrupted: false,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Bash tool: error ---
  {
    type: 'bashTool',
    id: nextId(),
    command: 'npm run build',
    stdout: null,
    stderr: `Error: Module not found: Can't resolve './missing-module'
    at /src/index.ts:3:1`,
    interrupted: false,
    isRunning: false,
    isError: true,
    errorMessage: 'Command failed with exit code 1',
    timestamp: ts(),
  },

  msg('user', '搜索一下项目里有没有其他地方用到 formatDate'),

  // --- Grep tool: success ---
  {
    type: 'grepTool',
    id: nextId(),
    pattern: 'formatDate',
    filenames: [
      'src/utils/formatDate.ts',
      'src/utils/__tests__/formatDate.test.ts',
      'src/components/DateDisplay.tsx',
      'src/pages/Dashboard.tsx',
      'src/pages/Profile.tsx',
    ],
    numFiles: 5,
    numMatches: 8,
    content: null,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Glob tool: success ---
  {
    type: 'globTool',
    id: nextId(),
    pattern: 'src/**/*.test.ts',
    filenames: [
      'src/utils/__tests__/formatDate.test.ts',
      'src/utils/__tests__/string.test.ts',
      'src/utils/__tests__/math.test.ts',
      'src/components/__tests__/Button.test.ts',
      'src/components/__tests__/Modal.test.ts',
      'src/services/__tests__/api.test.ts',
    ],
    numFiles: 6,
    truncated: false,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Glob tool: running ---
  {
    type: 'globTool',
    id: nextId(),
    pattern: 'src/**/*.css',
    filenames: null,
    numFiles: null,
    truncated: false,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  msg('assistant', '找到了 5 个文件引用了 `formatDate`。让我检查一下 `DateDisplay` 的用法。'),

  // --- Read tool: error ---
  {
    type: 'readTool',
    id: nextId(),
    filePath: '/etc/shadow',
    content: null,
    isRunning: false,
    isError: true,
    errorMessage: 'Permission denied: /etc/shadow',
    timestamp: ts(),
  },

  // --- Agent tool: running ---
  {
    type: 'agentTool',
    id: nextId(),
    description: 'Analyzing date formatting usage',
    prompt: 'Search the codebase for all usages of formatDate and check if any callers pass a format parameter',
    status: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Agent tool: completed ---
  {
    type: 'agentTool',
    id: nextId(),
    description: 'Analyzing date formatting usage',
    prompt: 'Search the codebase for all usages of formatDate and check if any callers pass a format parameter',
    status: 'completed',
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- WebFetch tool: success ---
  {
    type: 'webFetchTool',
    id: nextId(),
    url: 'https://api.github.com/repos/facebook/react/releases/latest',
    statusCode: 200,
    statusText: 'OK',
    result: `{
  "tag_name": "v19.1.0",
  "name": "React 19.1.0",
  "published_at": "2025-03-28T00:00:00Z",
  "body": "## What's Changed\\n- Improved Server Components..."
}`,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- WebFetch tool: running ---
  {
    type: 'webFetchTool',
    id: nextId(),
    url: 'https://docs.example.com/api/v2/reference',
    statusCode: null,
    statusText: null,
    result: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- WebSearch tool: success ---
  {
    type: 'webSearchTool',
    id: nextId(),
    query: 'TypeScript date formatting library lightweight',
    results: `1. date-fns - Modern JavaScript date utility library
   https://date-fns.org/
   Modular, tree-shakeable date utility library with 200+ functions.

2. dayjs - 2kB immutable date-time library
   https://day.js.org/
   Fast 2kB alternative to Moment.js with same API.

3. tempo - The easiest way to work with dates in JS
   https://tempo.formkit.com/
   A new, lightweight date library from the FormKit team.`,
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- WebSearch tool: running ---
  {
    type: 'webSearchTool',
    id: nextId(),
    query: 'WKWebView callAsyncJavaScript best practices',
    results: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Generic tools ---
  {
    type: 'genericTool',
    id: nextId(),
    toolName: 'TodoWrite',
    description: 'Updated TODO list with 3 items',
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  {
    type: 'genericTool',
    id: nextId(),
    toolName: 'NotebookEdit',
    description: 'Editing cell 5 in analysis.ipynb',
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  {
    type: 'genericTool',
    id: nextId(),
    toolName: 'CronCreate',
    description: 'Creating cron job: backup-db every 6 hours',
    isRunning: false,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Edit tool: error ---
  {
    type: 'editTool',
    id: nextId(),
    filePath: 'src/config/database.ts',
    structuredPatch: null,
    isRunning: false,
    isError: true,
    errorMessage: 'old_string not found in file. The file may have been modified since last read.',
    timestamp: ts(),
  },

  // --- Write tool: running ---
  {
    type: 'writeTool',
    id: nextId(),
    filePath: 'src/types/api.ts',
    isNewFile: true,
    structuredPatch: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Grep tool: running ---
  {
    type: 'grepTool',
    id: nextId(),
    pattern: 'TODO|FIXME|HACK',
    filenames: null,
    numFiles: null,
    numMatches: null,
    content: null,
    isRunning: true,
    isError: false,
    errorMessage: null,
    timestamp: ts(),
  },

  // --- Grep tool: error ---
  {
    type: 'grepTool',
    id: nextId(),
    pattern: '[invalid regex',
    filenames: null,
    numFiles: null,
    numMatches: null,
    content: null,
    isRunning: false,
    isError: true,
    errorMessage: 'Invalid regex pattern: unclosed character class',
    timestamp: ts(),
  },

  // --- Agent tool: error ---
  {
    type: 'agentTool',
    id: nextId(),
    description: 'Running complex analysis',
    prompt: 'Analyze all test files',
    status: null,
    isRunning: false,
    isError: true,
    errorMessage: 'Agent timed out after 120 seconds',
    timestamp: ts(),
  },

  // --- WebFetch tool: error ---
  {
    type: 'webFetchTool',
    id: nextId(),
    url: 'https://internal.corp.example.com/api/secret',
    statusCode: null,
    statusText: null,
    result: null,
    isRunning: false,
    isError: true,
    errorMessage: 'Host not allowed by sandbox: internal.corp.example.com',
    timestamp: ts(),
  },

  msg('assistant', `所有修改已完成。总结一下：

1. **修改了** \`formatDate\` 函数，添加了自定义格式参数
2. **创建了** 测试文件并验证通过
3. **搜索了** 项目中的所有引用，确认兼容性

默认格式 \`YYYY-MM-DD\` 保持不变，所以现有代码不需要修改。`),
]
