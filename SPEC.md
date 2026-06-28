# 交付物规格：CCTerm 项目架构导览（面向小白的 HTML）

本文件是所有 workflow 节点的**单一事实来源**。每个写作 / 校对 / 润色节点都必须把本文件的相关章节作为硬约束。任何偏离都视为缺陷。

---

## 0. 用户原始需求（原文，不得改写其意图）

> 我是小白，我刚接触这个项目。请用 html 写一下这个项目的大框架，组件树。每个组件可以简要介绍，不要太深入细节（但是，要能让小白读者能从直觉上理解）。
> 需要图文结合，每个地方你都要用最合适的表现方式（这个你要思考一下，列一个表格，什么情况用什么表达方式，什么地方用什么类型的图）。
> 最终搞一个 html，写到本目录下。
> 行文要符合中文习惯，杜绝翻译腔。术语统一，且精确定义。每个句子都要严格遵照中文语法，尤其不要丢失主谓宾。
> workflow 写好后，需要用一个干净上下文的 agent 来对抗性审查。
> 反应代码原原本本的信息，以及为什么这么做（当然，不见得当前架构/实现就是最优的，假设可以优化，可以提一嘴）。

---

## 1. 读者画像与目标（决定一切取舍）

- **读者**：第一次接触本项目的开发者（"小白"）。可能懂一点编程，但**不了解** macOS 原生开发、SwiftUI/AppKit 的分工、也不了解本项目的任何术语。
- **读者要带走的三样东西**：
  1. **一张心智地图**——这个 App 由哪几大块组成，它们怎么拼在一起。
  2. **每一块是干什么的**——用直觉能理解的比喻，而不是 API 清单。
  3. **为什么这么设计**——关键的架构决策背后的原因（尤其 SwiftUI vs AppKit 的取舍、单向数据流、runloop 时序）。
- **明确不要的东西**：逐函数 API 文档、源码行级解读、把每个文件都列一遍。**深度要克制**——宁可少讲透，不可多讲晕。

---

## 2. 项目事实基线（写作必须忠于这些事实，禁止臆造）

> 以下是从源码与 CLAUDE.md 提炼的**权威事实**。写作节点只能在此基础上"翻译成人话"，不得编造未列出的机制。如需更多细节，节点应自行读源码核实，但不得与下列事实冲突。

### 2.1 一句话定位
CCTerm 是 Claude Code 的**原生 macOS 客户端**——把"终端里的一个标签页"变成一个真正的 Mac App：左侧有会话侧边栏（可分组、可拖拽排序），中间是能瞬间滚动的长对话记录，回复实时流式刷出，Claude 要执行命令时弹出原生的权限确认框。技术栈 SwiftUI + AppKit，最低支持 macOS 14 (Sonoma)。

### 2.2 核心架构原则
- **UI 框架策略：默认 SwiftUI，AppKit 是例外。** 只有当 SwiftUI 满足不了需求（性能、生命周期时序、缺失能力）时才下沉到 AppKit。
- **当前用 AppKit 的地方（及原因）**：
  - **聊天记录（transcript）**：`NSTableView` + Core Text 自绘（`NativeTranscript2`）。SwiftUI 的 `List`/`LazyVStack` 扛不住行数、自定义布局和选择语义。
  - **主窗口骨架**：`MainWindowController` → `MainSplitViewController` → `DetailRouterViewController` → `ChatSessionViewController`。transcript 的挂载和 `frameDidChange` 级联必须跑在 AppKit 的 source 阶段，而不是 SwiftUI 的 commit 阶段。
  - **侧边栏**：`SidebarViewController`，基于 `NSOutlineView`（source-list 风格）。直接用 AppKit 才能拿到标准的文件夹拖拽（`pasteboardWriterForItem`/`validateDrop`/`acceptDrop`）和内建的展开/折叠动画。
  - **窗口工具栏**：`NSToolbar` + `NSSearchToolbarItem`。SwiftUI 的 `.searchable` 给不了 transcript 搜索需要的首响应者 + ⌘F 语义。
  - **App 生命周期**：`AppDelegate`（经 `@NSApplicationDelegateAdaptor`）持有进程级状态，在 `applicationDidFinishLaunching` 里创建主窗口。
  - 其它一切（输入栏、配置器、各种浮层、设置/关于窗口、所有可复用组件）都是 SwiftUI，通过 `NSHostingController`（整个面板）或 `NSHostingView`（工具栏项/浮层）寄宿。
- **分层**：Model（朴素数据，`struct` 优先，跨边界用 `Codable`）／View（SwiftUI 声明式）／Service（`@Observable`，靠初始化器或 `.environment()` 注入，View 绝不自己 new Service）／AppState（进程级容器，由 `AppDelegate` 持有，**靠初始化器逐级下传**，而不是 `.environment(appState)` 整包注入）。
- **确定性销毁**：每个 `@MainActor @Observable`/VC 都带一个空的 `nonisolated deinit {}`（绕开 macOS-26 的一个 `@MainActor` deinit 崩溃）。每个 `DetailRouterChild` 实现 `prepareForRemoval()`，让 router 在切换时确定性地释放每次挂载的资源。

### 2.3 启动链路（从双击图标到看见界面）
`@main CCTermApp`（SwiftUI `App`）→ `@NSApplicationDelegateAdaptor(AppDelegate.self)` → `MainWindowController` → `MainSplitViewController`（侧边栏项 + 详情项）→ `DetailRouterViewController`。router 根据当前选择，挂载**恰好一个** `DetailRouterChild` VC：
- `.session(_)` / `.none` → `ChatSessionViewController`
- `.newSession` → `ComposeSessionViewController`
- 还是草稿的 `.session` → `DraftSessionLandingViewController`
- `.archive` → `ArchiveViewController`
- DEBUG 下还有若干 demo VC。

选择/草稿状态住在 `MainSelectionModel`（`@Observable`）。AppKit 的 `SidebarViewController` 通过 `select(_:)` 写入它；router 是它**唯一的结构性观察者**——`select(_:)` 在点击的同一 source 阶段同步驱动详情侧切换。

### 2.4 AppState 持有的服务
`SessionManager`、`SyntaxHighlightEngine`、`RecentProjectsStore`、`InputDraftStore`、`SidebarSessionGroupOrderStore`、`AppActivationTracker`、`NotificationService`、`OpenInAppService`。
注意：`TranscriptSearchBus` **不在** AppState 上——它住在 `AppDelegate`，由工具栏搜索桥接和 ⌘F 命令读取。
`MainSplitViewController` 拆包 AppState：侧边栏需求打包成 `SidebarContext`，四个详情级服务打包成 `DetailContext`（经 `injectDetailEnvironment(_:)` 到达 SwiftUI 子树）。

### 2.5 会话运行时（Session 层）
- `Session`（`@Observable`）是一次对话的数据真相：消息时间线、状态、todos、tasks、上下文用量。
- `SessionRuntime` 是行为侧，按职责切成多个扩展文件：`+Start`/`+Messaging`/`+Receive`/`+Streaming`/`+History`/`+ContextUsage`/`+Todos`/`+Tasks`/`+SideQuestion`/`+Configuration`。
- `SessionManager` 管理所有会话的集合与生命周期；`SessionRepository` 负责持久化；`Worktree*` 负责 git worktree 隔离。
- 与底层 CLI 的通信走 `CLIClient`（真实实现 `AgentSDKCLIClient`，测试用 `CLIClient+Fake`），底层是 `AgentSDK`（独立 Swift Package）。
- 流式装配：`StreamingTurnAssembler`、`TypewriterReveal`、`StreamPacer`、`FrameTicker` 等把 SDK 吐出的增量组装成可渲染的逐字效果。
- todos/tasks/上下文用量经 `TodoTracker`/`TaskTracker`/`ContextUsageCache` 投影成 `@Observable` 追踪器。

### 2.6 聊天记录渲染（NativeTranscript2）
- `NSTableView` + Core Text 自绘。`Transcript2Coordinator.blocks` 是行数据真相，`Transcript2Controller` 驱动表格。
- 配套协调器：`Transcript2SearchCoordinator`（搜索）、`Transcript2SelectionCoordinator`（选择）、`Transcript2HighlightStorage`（语法高亮存储）、`Sheets/`（弹窗呈现）、`Layout/`（布局）、`Model/`（块模型）。
- **桥接层 `NativeTranscript2Bridge`**：把 `MessageEntry` 翻译成 `Block`。关键文件：`MessageEntryBlockBuilder`、`MarkdownToBlocks`、`StreamingMarkdownCommit`、`ToolUseToChild`、`StableBlockID`、`Transcript2EntryBridge`、`PipelineInbox`、回填管线 `TranscriptBackfillPipeline`、反向分页 `JSONLReversePageSource`/`ReverseLineReader`。
- transcript 的挂载/落定/绑定/`scrollToTail`/同会话淡入由 `TranscriptSwapCoordinator` 独占负责（它是 `currentSession` 以及每次挂载的 scroll view + sheet presenter 的**单一所有者**）。

### 2.7 输入与补全
- 输入栏 `InputBarView2`（SwiftUI），配 `InputBarControls`/`InputBarChrome`/`AttachButton`。
- 新会话配置器 `NewSessionConfigurator`。内建斜杠命令 `BuiltinSlashCommandHandler`。
- 补全：UI 侧 `CompletionState`/`CompletionListView`/`CompletionItem`/`CompletionTriggerRule`；服务侧 `FileCompletionStore`/`SlashCommandStore`/`DirectoryTreeMonitor`/`CompletionPrewarmer`。`FileCompletionStore`/`SlashCommandStore` 保持 `.shared`（per-cwd 缓存，不走注入）。

### 2.8 Markdown
`Components/Markdown/`：GFM 解析器 → 内部 IR（`MarkdownDocument`/`MarkdownTypes`/`MarkdownConvert`/`MarkdownAutolink`/`MarkdownMath`），供 NativeTranscript2 消费。

### 2.9 runloop 时序模型（关键的"为什么"）
macOS 上 AppKit、SwiftUI、CoreAnimation 共享同一个 runloop 迭代。一个迭代分三段：
- **source 阶段**：你的代码在这里跑（NSEvent 派发、`DispatchQueue.main.async` 排空、Observation Task 恢复、通知、Timer、IBAction）。`setNeedsLayout`/frame 写入在此刻"登记"，真正的布局/绘制发生在下一段。
- **beforeWaiting 观察者**：AppKit + CoreAnimation flush。SwiftUI 在这里重算失效视图的 body；布局→显示遍历视图树；NSTableView 首次显示时惰性查询 `numberOfRows`/`heightOfRow` 并 `tile()`；CATransaction 隐式提交到渲染服务。
- **sleep**：线程阻塞等下一个事件。
- 承重结论：① `@Observable` 写入**不会**在同一 tick 到达 SwiftUI body（body 在 beforeWaiting 才重算）；② `selectionObserver` 是**唯一**的结构性向上边，必须在点击的 source 阶段同步触发，否则会话切换会跨帧撕裂；③ 聊天区是约 90% 单向数据流：AppKit 外壳 + SwiftUI 叶子。

### 2.10 构建与测试
- 一律走 `make`：`make build`/`make release`/`make clean`/`make fmt`。
- 测试只有单元测试一个 target `cctermTests`：逻辑测试（默认跑）+ 快照测试（默认/CI 跳过，按需开）。没有 XCUITest。
- 文件系统同步的 Xcode group（`PBXFileSystemSynchronizedRootGroup`）：磁盘上增删文件自动进 build，**绝不手改** `project.pbxproj`。

### 2.11 "可优化"候选（节点可"提一嘴"，必须标注为观点而非事实）
> 这些是**主观改进空间**，写作时必须明确措辞为"可以考虑/或许能优化"，不得写成既定事实。**最多在专门的小节里点 2~3 处**，点到为止：
- AppKit 与 SwiftUI 的边界处处依赖 runloop tick 时序，心智负担重；文档已很努力地把规则写在代码旁，但这类隐式时序契约本身是脆弱点。
- `TranscriptSwapCoordinator` 等协调器承担了很多"单一所有者"职责，类比上接近一个聚焦的小型状态机；好处是边界清晰，代价是新人要先理解这套所有权划分才能动它。
- 不要无中生有地批评。没有把握的点不要写。

---

## 3. 文档结构（**最重要**——决定小白能否顺畅理解）

采用**"由整体到局部、由直觉到机制"**的递进结构。读者应当能像剥洋葱一样，一层层深入而不迷路。强制章节顺序如下：

| # | 章节 | 作用（读者读完应该获得什么） | 主表现形式 |
|---|---|---|---|
| 0 | 顶部导航 + 一句话简介 | 30 秒内知道"这是什么、这篇文章带我看什么" | 文字 + 锚点目录 |
| 1 | 这是个什么 App | 用截图式的文字描述 + 类比，建立直觉印象 | 文字 + 类比卡片 |
| 2 | 鸟瞰：四大区域 | 一张全局图，把 App 切成读者能记住的几大块 | **分区示意图（HTML/CSS 盒子图）** |
| 3 | 启动链路：从双击到见面 | 理解对象是怎么一个接一个被创建/挂载的 | **纵向流程图/时间线** |
| 4 | 组件树总览 | 一棵清晰的树，标出每块用 SwiftUI 还是 AppKit | **树形图** + 图例 |
| 5 | 逐块讲解（每块一节） | 每块"是什么、打个比方像什么、为什么这么做" | 卡片 + 小图 + 表格 |
| 6 | 一条消息的旅程（数据流） | 把静态结构串成动态故事：用户敲字→Claude 回复怎么流过这些组件 | **横向数据流图（带泳道/箭头）** |
| 7 | 关键设计抉择（为什么） | 集中讲 3 个"为什么"：SwiftUI vs AppKit、单向数据流、runloop 时序 | 对比表 + 时序图 |
| 8 | 可以怎么更好（克制的优化建议） | 让读者知道"现状不等于最优"，建立批判性视角 | 文字（明确标注为观点） |
| 9 | 名词表 / 术语对照 | 一站式查词，巩固"术语统一" | 表格 |

**结构硬规则**：
- 每一节开头必须有**一句话主旨**（"本节讲什么"），让读者随时知道自己在哪。
- 概念引入顺序严格遵守"先整体后局部"：第 2 章的鸟瞰图必须先于第 4 章的组件树，第 4 章必须先于第 5 章的逐块细节。
- 每个新术语**第一次出现**时必须就地用一句话定义，之后才能直接使用。
- 善用"类比"降低门槛，但类比之后必须紧跟一句"对应到代码里就是 XXX"，避免只停在比喻、落不了地。
- 章节之间要有**过渡句**承上启下，禁止生硬跳转。

---

## 4. 语言规范（中文质量）

- **杜绝翻译腔**。禁止"被…所"滥用、"进行一个 X 的操作"、"…的话"口头禅堆叠、英式长定语从句直译。
- **每句话主谓宾完整**，不丢主语、不丢谓语。长句拆短句。
- **术语统一**：同一概念全文用同一个词（见第 9 节术语表）。代码标识符（类名/方法名）保留英文原形，用 `<code>` 包裹。
- 中英文之间、中文与数字之间按中文排版习惯处理（代码标识符不强行加空格）。
- 主动语态优先。能用"它把 X 交给 Y"就不要写"X 被 Y 所处理"。
- 比喻要贴切、本土化，避免生造的洋比喻。

---

## 5. 图文结合规范（表现方式选择表）

**核心要求**：每处内容都用"最合适"的表现方式。下表是强制对照——写作节点必须按"内容类型→表现方式"选型，不得一律用文字流水账，也不得滥用图把简单的事复杂化。

| 内容类型 | 最合适的表现方式 | 理由 | 实现方式（HTML/CSS） |
|---|---|---|---|
| 整体定位、类比、设计理由 | **正文段落 + 高亮卡片** | 叙述性内容图反而碍事 | `<p>` + `.callout` 卡片 |
| App 分成几大区域（空间关系） | **分区示意图** | 空间布局用图一眼懂 | CSS Grid/Flex 盒子图，带标注 |
| 父子/包含层级（组件树） | **树形图** | 层级关系树形最直观 | 嵌套 `<ul>` + CSS 连线，或缩进盒子 |
| 启动顺序、对象创建链（线性时序） | **纵向流程图/时间线** | 强调"先后" | 竖直排列的节点 + 向下箭头 |
| 数据如何流过多个组件（多方参与） | **横向数据流图 + 泳道** | 强调"谁传给谁" | Flex 横向节点 + 箭头连线 |
| 两种方案对比（SwiftUI vs AppKit 等） | **对比表格** | 并列维度表格最清楚 | `<table>` 双列对比 |
| 一个迭代内的时间分段（runloop） | **时序条带图** | 强调"同一帧内的先后段" | 横向分段条 + 标注 |
| 同类项的属性罗列（服务清单、术语） | **表格** | 结构化查阅 | `<table>` |
| 关键提示、注意事项、"为什么" | **彩色 callout 卡片** | 视觉上跳出正文 | `.callout.note` / `.callout.why` |
| 代码标识符、文件名 | **行内代码 / 代码块** | 区分代码与正文 | `<code>` / `<pre>` |

**图的实现底线**：
- 所有图用**纯 HTML + 内联 CSS** 画（盒子、箭头、连线用 CSS borders/伪元素/SVG 内联）。**不依赖任何外部 JS 库、不联网**（离线可打开）。允许内联少量 SVG。
- 图必须有**标题**和**图例**（如颜色代表 SwiftUI/AppKit）。
- 配色无障碍：不能只靠颜色区分，要配文字/图标标签。
- 图与正文必须**互相呼应**：图里出现的每个块，正文都要讲到；正文讲的关键块，图里要能找到。

---

## 6. HTML / 视觉规范（统一词汇表，保证多节点产出可拼接）

为保证并行写作的各 section 风格一致、可无缝拼接，所有节点**必须复用**下列约定，不得自创 class 名或配色：

- 单文件 `architecture.html`，自包含（`<style>` 内联在 `<head>`，无外部依赖、无 CDN、无 JS 框架；允许极少量原生 JS 仅用于锚点平滑滚动，可省略）。
- 响应式：桌面优先，窄屏不破版。
- **配色语义（固定）**：
  - SwiftUI 相关 → 蓝色系 `--swiftui: #2563eb`
  - AppKit 相关 → 橙色系 `--appkit: #ea580c`
  - 服务/数据层 → 绿色系 `--service: #16a34a`
  - 中性/外壳 → 灰色系 `--neutral: #64748b`
- **统一 class 名**：`.section`（章节容器）、`.section-lead`（每节开头一句话主旨）、`.callout`（提示卡，修饰 `.note`/`.why`/`.tip`）、`.diagram`（图容器）、`.diagram-title`、`.legend`（图例）、`.tree`（树形图）、`.node`（流程/树节点）、`.lane`（泳道）、`.tag.swiftui`/`.tag.appkit`/`.tag.service`（技术标签）、`.compare`（对比表）、`.termtable`（术语表）。
- 每个 section 产出**只含 `<section class="section" id="...">…</section>` 片段**（不含 `<html>/<head>/<body>`），由组装节点拼进统一骨架。section 内部允许定义该图专用的 `<style scoped>`-风格类（但前缀化，如 `.s3-...`，避免冲突）。
- 字体用系统字体栈，正文行高 ≥1.7，代码用等宽字体。
- 中文排版：段落不首行缩进（Web 习惯），段间距拉开。

---

## 7. 分块定义（workflow 的并行单元）

每块产出一个 `<section>` 片段。块之间内容不重叠，边界如下：

| 块ID | id 属性 | 标题 | 覆盖第 3 节的章节 |
|---|---|---|---|
| S0 | `intro` | 这是个什么 App + 文章导读 | 0、1 |
| S1 | `birdseye` | 鸟瞰：四大区域 | 2 |
| S2 | `bootstrap` | 启动链路：从双击到见面 | 3 |
| S3 | `tree` | 组件树总览 | 4 |
| S4 | `parts-shell` | 逐块讲解（一）：窗口外壳与导航（Window/Split/Router/Sidebar/Toolbar） | 5（部分） |
| S5 | `parts-chat` | 逐块讲解（二）：聊天区（ChatSessionVC/TranscriptSwapCoordinator/NativeTranscript2/Bridge/InputBar/Completion/Markdown） | 5（部分） |
| S6 | `parts-session` | 逐块讲解（三）：会话与数据层（Session/SessionRuntime/SessionManager/CLIClient/AgentSDK/Worktree） | 5（部分） |
| S7 | `dataflow` | 一条消息的旅程（数据流） | 6 |
| S8 | `decisions` | 关键设计抉择（为什么） | 7 |
| S9 | `improve` | 可以怎么更好（克制的优化建议） | 8 |
| S10 | `glossary` | 名词表 / 术语对照 | 9 |

组装顺序：S0→S1→S2→S3→S4→S5→S6→S7→S8→S9→S10，外加顶部导航目录。

---

## 8. 文章质量定义（验收标准 / 审查 checklist）

对抗性审查 agent 必须逐条核对，任一不达标即打回：

### 8.1 技术准确性（最高优先级）
- [ ] 每个出现的类名/文件名/机制都与第 2 节事实基线或源码一致，**无臆造**。
- [ ] SwiftUI/AppKit 的归属标注正确（transcript=AppKit、侧边栏=AppKit、输入栏=SwiftUI 等）。
- [ ] "为什么"的解释与代码注释/CLAUDE.md 的理由一致，没有张冠李戴。
- [ ] 优化建议被明确标注为"观点/可考虑"，没有伪装成事实。

### 8.2 结构（对小白最关键）
- [ ] 严格"先整体后局部"：鸟瞰→树→细节的顺序没有倒置。
- [ ] 每节有一句话主旨；每个术语首次出现就地定义。
- [ ] 章节间有过渡句，读起来是连贯的一条线，不是拼凑。
- [ ] 顶部有可点击目录；锚点可用。

### 8.3 图文结合
- [ ] 每种内容用了第 5 节表里"最合适"的表现方式，没有该用图却堆文字、也没有滥用图。
- [ ] 每张图有标题 + 图例；图与正文互相呼应（图里的块正文都讲了）。
- [ ] 配色语义统一（蓝=SwiftUI、橙=AppKit、绿=服务），且不只靠颜色区分。
- [ ] 离线可打开，无外部依赖。

### 8.4 中文语言
- [ ] 无翻译腔；无"被…所"滥用、无"进行 X 操作"式赘语。
- [ ] 每句主谓宾完整，无残句。
- [ ] 术语全文统一（对照第 9 节）。
- [ ] 代码标识符保留英文并用 `<code>` 包裹。

### 8.5 深度把控
- [ ] 面向小白，克制深度：没有逐函数 API 罗列；该简略处简略。
- [ ] 但每块都"能让小白从直觉上理解"，不是只丢一个类名。

---

## 9. 术语统一表（全文必须一致使用）

| 统一中文术语 | 含义 | 对应代码 | 禁止的其它叫法 |
|---|---|---|---|
| 会话 | 一次完整的对话 | `Session` | 对话、session、聊天 |
| 聊天记录 | 滚动显示历史消息的区域 | `NativeTranscript2` / transcript | 文字记录、对话流、transcript（中文行文里） |
| 侧边栏 | 左侧会话列表 | `SidebarViewController` | 边栏、sidebar |
| 输入栏 | 底部输入框区域 | `InputBarView2` | 输入框、input bar |
| 主窗口骨架 | 窗口→分栏→路由→面板这条骨架链 | `MainWindowController` 等 | 主框架 |
| 详情路由器 | 按选择挂载对应面板的那一层 | `DetailRouterViewController` | 路由 VC |
| 会话运行时 | 驱动一次会话行为的对象 | `SessionRuntime` | 运行时、runtime |
| 进程级状态容器 | 全 App 共享的状态袋子 | `AppState` | 全局状态、app state |
| 寄宿 | 把 SwiftUI 视图放进 AppKit 容器 | `NSHostingController`/`NSHostingView` | 嵌入、托管、host |
| source 阶段 / beforeWaiting | runloop 一个迭代内的时间段 | runloop tick model | 源阶段、等待前（保留英文术语） |
| 单向数据流 | 状态向下流、事件少量向上 | data-flow rules | 单向绑定 |
| 块 | 聊天记录里的一行/一个渲染单元 | `Block` | block、条目 |

---

## 10. 交付

- 最终文件：`architecture.html`，写到仓库**本目录**（worktree 根）。
- 自包含、离线可打开、无外部依赖。
- 通过第 8 节全部 checklist 后方可交付。
