# Transcript Outline — 已确认规格

> 本文件记录**已拍板**的需求、边界与组件职责（决策清单见 §8）。实现时严格照此，
> 不得擅自展开，也不得用旧代码惯例补全——本文件未覆盖的点先问，别自作主张。

## 1. 目标

- 为「打开历史 session」这条路径实现一个基于原生 `NSOutlineView` 的新 transcript，
  替换现有 `NativeTranscript2`（扁平 `NSTableView`，`macos/ccterm/Content/Chat/NativeTranscript2/`）。
- 本轮只做**最小可跑**版本。

## 2. 硬约束

- 树化在 **store** 内完成。
- **无 ViewModel**。
- 底层渲染直接复用现有纯布局层 `RowLayout`
  （`macos/ccterm/Content/Chat/NativeTranscript2/Layout/RowLayout.swift`）。
- **一次性阻塞加载**：不做分页 backfill，不做 live-resize。
- 原生 `NSOutlineView` disclosure 三角，**不自绘 chevron**。
- `Block`（`macos/ccterm/Content/Chat/NativeTranscript2/Model/Block.swift`）可改以适配树结构。
- 严格按根 `CLAUDE.md` 分层规范：Model / View / Controller / Store；数据向下、事件向上；
  DI（initializer 注入）；每个 `NSView`/`NSViewController` 子类 `init(coder:)` 标
  `@available(*, unavailable)` + `fatalError`。
- 未被明确要求的旧组件一律**舍弃**：不作为地基、不 import。
- **依赖注入**：所有协作者经 `init` 注入（持 protocol 类型）；**禁止** `.shared`、
  全局可变单例、或在方法体内自取全局。store 的数据来源经注入的 `TranscriptHistoryService`
  (protocol，见 §3) 取得，不在 store 内部硬调 `SessionHistory`（留测试 seam）。
  composition root（谁在何处 new 出对象图）见 §8 决策 6。

## 3. 数据源

- 唯一输入：AgentSDK 对外的 `Message2`
  （`macos/AgentSDK/Sources/AgentSDK/Generated/Message2.generated.swift`；枚举，
  主要 case：`.assistant(Message2Assistant)`、`.user(Message2User)`、`.result(...)`、`.system(...)` 等）。
- 历史读取入口：`SessionHistory.loadMessages(sessionId: String) -> [Message2]`
  （`macos/AgentSDK/Sources/AgentSDK/SessionHistory.swift`，AgentSDK **public** API；内部
  `findSessionFile` + 逐行 `Message2Resolver`）。
- **DI 接口（在 ccterm 侧定义，AgentSDK 不改）**：protocol `TranscriptHistoryService`，
  首个方法 `static func loadMessages(sessionId:) -> [Message2]`，预留后续分页 / stream 等方法。
  因 `SessionHistory` 是无 case 的 static enum，直接在 ccterm 侧
  `extension SessionHistory: TranscriptHistoryService {}` 零体 conform（static 方法已存在），
  **不新建任何适配类型**。store 注入 `TranscriptHistoryService.Type`（生产传 `SessionHistory.self`，
  测试传 fake `enum`，喂假 `[Message2]`）。
- **舍弃**（不 import、不依赖）：`Session` / `SessionRuntime` /
  `MessageEntry`(`SingleEntry`/`GroupEntry`) / bridge（`Transcript2EntryBridge`、
  `MessageEntryBlockBuilder`、`ToolUseToChild`）/ `Transcript2Controller` /
  `Transcript2Coordinator` / `TranscriptSwapCoordinator` / backfill pipeline。
- 分组与 `tool_use`↔`tool_result` 配对：由 store 从 `[Message2]` **直接完成**。
  规则可参考旧实现，但须在新代码中重写，不 import 旧类型。

## 4. Outline 层级

树由 `[Message2]` 按 content block **顺序**拆分而成：

- **assistant message** 按其 content block 顺序拆：text / thinking 段 → markdown 顶级节点
  （每个解析出的 block 各一个顶级节点）；`tool_use` 段 → 进 tool 分组。一条 message 里
  text 与 tool_use 混合时分别落到上述两类，互不吞并。
- **user message**：真实文本 / 图片 block → user 气泡（顶级）；`tool_result` block **不出气泡**，
  只用于按 `tool_use_id` 配对到对应 tool。两类可能同在一条 message。
- **tool 分组**：**tool group header 总是生成**（相邻的 `tool_use` 段合成一组，单个也成组）。层级：
  - tool group header（顶级，native 三角）
    - tool header —— 每个 `tool_use` 一个（native 三角）
      - tool body —— 叶子
- **header 节点渲染**：group header / tool header 只画 title 文本（native 三角负责箭头），
  沿用 `BlockStyle.toolHeader*` 常量（见 §7）。
- 展开 / 折叠由原生 `NSOutlineView` 负责；store 只回答 children / isExpandable。
- **初始状态：tool group 默认折叠**（顶级 user / markdown 全显示）；加载后 `scrollToTail` 到底。

## 5. 居中（v2 修订 —— 全宽 outline + 行内定宽居中）

> **修订记录**：v1 方案（定宽 [460,780] documentView + `TranscriptClipView` 居中 +
> 四条宽度约束）已被实证否决：`NSTableView` 族 documentView 的 frame 由自身 tile +
> clip 直接管理，宽度约束不生效（outline 被撑满全宽、居中分支永不触发）；且
> `translates=false` 下**动画展开**（点击三角）只更新 `intrinsicContentSize` 不写
> frame，文档高度卡死、无法下滚。clip 居中手法本身是官方 pattern（Apple 示例
> `Exhibition/CenteringClipView.swift`），但它适用于自由尺寸文档，不适用于 table 族。
> 成熟先例（TelegramSwift 聊天表格、旧 NativeTranscript2）均为「全宽表格 + 行内定宽居中」。

**outline 是全宽、frame-based 的 documentView**（table 族的原生契约：宽度随 clip、
高度由自身 tile 管理，动画展开正常长高）。居中的 460–780 内容列只存在于**行内部**：

- **单一几何事实源 `TranscriptOutlineMetrics`**：列左沿 = `BlockStyle.cellOriginX`（与旧
  renderer 同一函数）；每级缩进 `indentStep = 16`；header 行三角槽 `chevronSlot = 24`；
  排版宽度 = `clamp(行宽, 460, 780) − 2×16 − level×16 (− chevronSlot)`。store / VC /
  cell / outline 子类全部经它取数，宽度与原点不可能失配。
- **cell 是居中唯一关口**：`OutlineBlockCellView.layoutOrigin` 换算列偏移（减掉自身
  frame.x，抵消 native 缩进），draw / cursor / hit 全走它；`draw(_:)` 内 `ctx.clip`
  到列槽 —— layout 物理上画不出居中列（硬边界，非约定），另有 DEBUG 断言拦截
  排版超宽。layout 层对居中零感知。
- **`TranscriptOutlineView`（最小子类）**：仅 override `frameOfOutlineCell(atRow:)`
  （Apple 文档明示的定制点），把原生三角摆进内容列（x = 本行 content x，与上一级
  文本左沿对齐；y 对准 24pt header 标题带）。三角的绘制与旋转动画仍全部原生。
  `indentationPerLevel = 0` —— 缩进全部由 Metrics 表达。

**`NSScrollView`（host）配置**：`wantsLayer = true` + `layerContentsRedrawPolicy = .never`；
`hasVerticalScroller = true` + `autohidesScrollers = true`；`hasHorizontalScroller = false`；
`scrollerStyle = .overlay`；`drawsBackground = false` + `borderType = .noBorder`；
`automaticallyAdjustsContentInsets = false`；stock `NSClipView`（layer-backed `.never`）；
`contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)`；4 边 pin 到 `view`。
documentView **不加任何约束**。

**纵向节奏（L1/L2/L3，常量在 Metrics）**：L1 组头行 (top 8, bottom 2)；L2 tool header
行 (2, 2)；L3 body 行 (2, 2) —— 相邻 header↔header / header↔body 间距均为规范的
`toolHeaderChildSpacing`(4pt)，组头顶部走 hard-edged 块级 8pt 档。

## 6. 组件（职责 + 需暴露的能力）

新组件按 feature 组织，落在 `macos/ccterm/Content/Chat/TranscriptOutline/`。
下面只钉**职责与边界**；精确方法签名待实现时定（§8）。

1. **`TranscriptStore`** — `@MainActor` Store。
   - 拥 I/O + state：入口 `load(sessionId:)`，经注入的 `TranscriptHistoryService`(protocol，见 §3)
     取数（生产传 `SessionHistory.self`；测试传 fake，喂假 `[Message2]`）。
   - 树化：`[Message2]` → outline 树（含分组、tool 配对）。
   - 缓存每个节点的 `RowLayout`。
   - 查询面（供 controller 的 dataSource/delegate 用）：roots、某节点的 children、
     是否可展开、按宽度取 / 算节点 layout、节点高度。
   - 无 UI、不持 `NSView`。

2. **`TranscriptViewController`** — `NSViewController`。
   - `loadView` 建 `NSScrollView`(host) + `TranscriptOutlineView` 视图树（不调 `super.loadView`）。
   - `viewDidLoad` 绑 dataSource/delegate、一次性配置。
   - 持有 `store`；**自身兼任** outline 的 `NSOutlineViewDataSource` /
     `NSOutlineViewDelegate`（同文件 extension），从 store 取数。
   - 对外：`present(sessionId:)`、`scrollToTail()`。
   - `init(coder:)` 封死。

3. **`TranscriptOutlineMetrics`** — 几何单一事实源（列位置 / 缩进 / 排版宽度 / L1-L3
   纵向节奏），store / VC / cell / outline 子类共用（§5 v2）。

4. **outline 视图 + cell** — `TranscriptOutlineView`（最小 `NSOutlineView` 子类，仅
   override `frameOfOutlineCell(atRow:)` 摆放原生三角，见 §5 v2）；cell 自绘（用
   `RowLayout.draw` 绘制），**cell 是行内居中唯一关口**（layoutOrigin + ctx.clip 硬边界）。

5. **`HistorySessionViewController`**（现有，`macos/ccterm/App/AppKit/HistorySessionViewController.swift`）
   瘦成容器：
   - 用 containment 持 `TranscriptViewController` 作 child VC（`addChild` → 加 view → 约束）。
   - `present(sessionId:)` 转发给它；input bar placeholder 保留。
   - 删除其对 `TranscriptSwapCoordinator` / `Transcript2ScrollView` / `Session` /
     `DetailContext.sessionManager` 的依赖。
   - **`TranscriptSwapCoordinator` 删除**。
   - `DetailFlowCoordinator.route(to:)` 的 `.history` 路由**不变**。

## 7. 复用 / 舍弃（原则）

- 复用（原样）：`RowLayout` 下的 per-kind 布局（text / codeBlock / list / table / blockquote /
  image / userBubble），`BlockStyle` 常量；markdown 解析 —— `Components/Markdown/` 的 GFM
  parser + `NativeTranscript2Bridge/MarkdownToBlocks.swift`（纯 markdown→`[Block]`，不依赖
  Session / entry）。
- **复用 + 适当改造**：tool body —— per-kind body 布局（`ToolGroupChildLayout` + 各
  `XxxChildLayout`）与 `Block.ToolGroupBlock.Child` 负载可复用，但现有实现是为「巨石
  toolGroup 一个 row 内画 header + body」设计的（body 坐标相对 group origin、header 由
  `ToolGroupLayout` 拥有）。搬到 outline 里当**独立叶子节点**须相应改造：坐标系 / 尺寸 /
  去掉对 group header 的耦合。
- **新增**：header 布局 —— 轻量「只画 title」布局（native 三角负责箭头，沿用
  `BlockStyle.toolHeader*` 常量），group header 与 tool header 共用；给 `RowLayout` 加 `header` case。
- **`RowLayout` / `Block` 可改**：删 / 停用巨石 `toolGroup` case（改由 header + body 节点表达）与
  `loadingPill` case（无 live）；加 `header` case。
- 舍弃：§3 列出的整条 Session / entry / bridge / 旧 controller / coordinator / swap 链路。
- 具体文件的删除按「保持可编译、逐步剥离」执行，不在本文件逐文件钉死命运。

## 8. 已定决策（本轮拍板）

1. 节点模型：独立 `TranscriptNode`（值类型，树 + 每节点一份渲染负载）。
2. 树化规则：连续的纯 `tool_use` assistant 合成一组（单个也成组）；`tool_result` 按
   `tool_use_id` 从后续 user message 的 `tool_result` 配对。
3. tool body：**复用 + 适当改造**（见 §7）。
4. cell：复用 `BlockCellView` 的绘制路数（自绘 + `.onSetNeedsDisplay` layer 缓存），去掉居中偏移。
5. 历史数据源经 protocol `TranscriptHistoryService` 注入（`extension SessionHistory` conform，
   注入 `.Type`；见 §3），无适配 struct。
6. composition root：`DetailFlowCoordinator.makeChild(.history)` 把 `TranscriptHistorySource`
   注入 `HistorySessionViewController`；后者 new 出 `TranscriptStore(historySource:)` +
   `TranscriptViewController(store:)`。

（方法签名 / 绘制像素等纯实现细节实现时自定，不在本文件钉死。）
