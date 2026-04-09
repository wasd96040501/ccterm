# CCTerm WebView (React)

macOS 原生应用 CCTerm 的主对话渲染层。运行在 WKWebView 中，Swift 通过 callAsyncJavaScript 传入渲染就绪的 JSON 数据，React 负责纯渲染。

## 技术栈

- React 19 + TypeScript
- zustand 状态管理
- Bun 打包（`bun build`），产出单个 JS bundle 加载到 WKWebView
- react-markdown + remark-gfm + rehype-highlight 渲染 Markdown
- highlight.js 代码高亮（auto light/dark theme）
- 与 Swift 通信通过 bridge.ts（callAsyncJavaScript + JSON，见 Bridge 通信章节）

## 构建

```bash
bun run build   # 产出 dist/index.js (minified)
bun run dev     # watch 模式
```

## 目录结构

```
src/
├── index.tsx              # 入口，挂载 React root，注册 bridge 事件分发
├── bridge.ts              # Swift↔React 双向通信
├── App.tsx                # 顶层组件，管理会话切换
├── types/
│   ├── message.ts         # ChatMessage discriminated union（UserMessage | AssistantMessage）
│   └── bridge.ts          # NativeEvent / WebEvent 事件类型
├── stores/
│   └── conversationStore.ts
├── components/
│   ├── MessageList/       # 消息列表（虚拟滚动容器）
│   ├── ChatMessage/       # 单条消息（区分 user/assistant）
│   └── MarkdownRenderer/  # Markdown 渲染器
├── hooks/                 # 自定义 hooks（按需添加）
├── services/              # 业务逻辑服务（高度预估等）
└── styles/                # CSS 文件
```

## 界面规范

### 消息类型与布局

这是一个**聊天界面**，所有消息/组件在一个纵向列表中从上到下排列：

| 类型 | 对齐 | 宽度 | 样式 |
|------|------|------|------|
| `user` | 右对齐 | 最大 80% 容器宽度 | 聊天气泡，带背景色和圆角 |
| `assistant` | 左对齐 | 100% 容器宽度 | 无气泡，直接渲染 Markdown |

### 层级间距系统 (L-level spacing)

组件有层级概念：L1 是顶级组件，L2 是 L1 展开的子项，L3 是 L2 展开的子项，依此类推。

间距规则（**指相邻同级或跨级组件之间的垂直距离**）：
- **L1 与 L1 之间**：16pt
- **L1 头部与其第一个 L2 子项之间**：8pt
- **L2 与 L2 之间**：8pt
- **通用公式**：第 N 层级的间距 = max(4, 16 / 2^(N-1)) pt，即 L1=16, L2=8, L3=4, L4+=4

实现方式：通过 CSS class `.l1-item`, `.l2-item`, `.l3-item` 控制 `padding-top`，不在组件内硬编码。L2/L3 保留 `:first-child { padding-top: 0 }` 规则。

### 会话切换

- 单个 WebView 内承载多个会话，通过 bridge 事件（switchConversation）切换，不重新创建 WebView
- 每个会话独立维护滚动位置：
  - **首次打开**的会话：自动滚动到底部
  - **再次切换回**的会话：恢复到上次离开时的滚动位置
- 切换时旧会话的 DOM 可以卸载（不需要保留在 DOM 中），但状态（消息数据 + 滚动位置）必须保留在内存中

## Bridge 通信

React 运行在 WKWebView 中，通过 `bridge.ts` 与 Swift 侧双向通信。

### 接收 Swift 事件
Swift 通过 `callAsyncJavaScript` 调用 `window.__bridge(type, json)`。
`bridge.ts` 解码后分发到 `onNativeEvent` handler（在 `index.tsx` 中注册）。

### 发送事件到 Swift
统一使用 `postToNative()` 函数。

### 规范
- 禁止将 store 函数或组件方法挂载到 `window`。外部入口统一通过 `bridge.ts`
- 禁止直接调用 `window.webkit.messageHandlers`，统一使用 `postToNative()`
- 类型定义在 `types/bridge.ts`（事件）和 `types/message.ts`（数据），修改时需与 Swift 侧 `BridgeMessages.swift` 同步
- React 不做数据处理。`ChatMessage.content` 是渲染就绪的 string

## 性能要求

目标：支持单个会话 1000+ 条 Markdown 消息，首次载入时延 < 50ms，滚动流畅无撕裂/jitter。

核心策略：
1. **`content-visibility: auto`**：浏览器原生跳过不可见元素的 layout/paint，配合 `contain-intrinsic-size` 给预估高度
2. **避免不必要的 re-render**：使用 `React.memo`，消息组件以 `message.id` 为 key
3. **粘底与位置恢复**：手动检测 scrollTop 距底部距离，新消息到达时自动滚动；切换会话时保存/恢复 scrollTop

## 代码规范

- 函数组件 + hooks，不使用 class 组件
- 组件文件使用 PascalCase：`ChatMessage.tsx`
- hooks 文件使用 camelCase：`useVirtualScroll.ts`
- 类型定义集中在 `types/` 目录，组件 props 类型与组件同文件定义
- CSS 使用普通 CSS 文件（不使用 CSS-in-JS），通过 `import './style.css'` 引入
- 状态管理使用 zustand

## 依赖选型原则

- 优先使用高质量、维护活跃的库
- 拒绝低质量库（如 react-ansi：输出质量差、边界情况多、不如手写 ANSI 解析）
- 如果某个功能的可用库质量都不高且实现简单，手写优于引入依赖
- 新增依赖前需确认
