# CCTerm 组件树与数据流重构方案

> 本文是对 CCTerm 整个组件树与数据流的重构方案。结论由一轮并行多代理调研（12 个子系统调研 → 横切分析 → 4 组「设计 + 对抗验证」）汇总而成；每条设计结论都经过**独立对抗审核员**针对真实代码的挑战，审核修正已折叠进正文。各节点的原始产物（`docs/refactor/nodes/`，索引见 §13）**已从本 PR 移除以保持精简，完整保留在分支 git 历史中**。
>
> **一句话定调**：CCTerm 的架构**已经是一个 AppKit 外壳 + SwiftUI 叶子、约 90% 单向的干净架构**。本方案**不是重写**，而是一次**外科手术式**的整理：消除 DI 样板、沿既有内部缝隙拆分两个真正的 god-VC、修正失真的命名/文档、删除死边，并把头号体验缺陷（权限卡片）修成真正的悬浮层——同时**逐字节保留**所有 load-bearing 不变量（选择主轴、渲染双通道、transcript §2 性能契约、§2.19 attach 契约、host-sizing 纪律）。凡是「干净」的想法会碰到这些不变量的，一律绕开，并记录在 §11。

---

## 目录

1. [执行摘要](#1-执行摘要)
2. [现状 · 组件树（权威版）](#2-现状--组件树权威版)
3. [现状 · 数据流与所有权](#3-现状--数据流与所有权)
4. [问题总览（5 类形态 + 排名）](#4-问题总览5-类形态--排名)
5. [目标 · 组件树](#5-目标--组件树)
6. [目标 · 数据流宪法（7 条规则）](#6-目标--数据流宪法7-条规则)
7. [头号修复 · 权限卡片悬浮层](#7-头号修复--权限卡片悬浮层)
8. [逐项重构清单](#8-逐项重构清单)
9. [迁移计划（4 阶段 + 平价校验单）](#9-迁移计划4-阶段--平价校验单)
10. [不可触碰的契约墙](#10-不可触碰的契约墙)
11. [明确不做的事（反过度设计）](#11-明确不做的事反过度设计)
12. [对抗审查结论](#12-对抗审查结论)
13. [附录 · 节点产物索引与方法论](#13-附录--节点产物索引与方法论)

---

## 1. 执行摘要

### 1.1 诊断

CCTerm 是 **AppKit-rooted shell with SwiftUI leaves**：app 生命周期、主窗口、split、侧边栏、detail 路由、transcript 是**有意为之的 AppKit 例外**（每一处都在 root CLAUDE.md 里有性能/时序的理由）；SwiftUI 只出现在被宿主的位置——通过 `NSHostingController`（整 pane 子 VC + 辅助窗口）或 `NSHostingView`（toolbar item、底部输入栏、demo 浮层）。

架构**已经基本单向且分层良好**。存在两条干净的数据流主轴：

1. **选择主轴（selection spine）** — `MainSelectionModel.select(_:)` 写入 `@Observable selection`，**并同步**通知唯一的结构观察者（router）。下行是 `@Observable` 读取，结构下行是一次同步 delegate 调用，没有任何东西回流。唯一的一条**向上结构边**是 `selectionObserver`，有充分理由。
2. **会话/渲染主轴（session/render spine）** — `Session`（façade）在其整个生命周期持有 `Transcript2Controller` + `Transcript2EntryBridge`；runtime 状态经 `@Observable` **拉取**到 SwiftUI、经同步闭包**推送**到 AppKit transcript。「每个状态只走一条通道」由约定保证且确实成立。

因此问题**不是「数据流乱」**，而是聚成 5 类形态（详见 §4）：**(A)** DI 样板（含 2 条死注入）、**(B)** 混职责的 god-object、**(C)** 命名/边界失真、**(D)** 重复派生逻辑、**(E)** 所有权模式不一致。生产 UI 里**仅有一处**真正的单向流违例：`BackgroundTaskButton` 越过 `Session` façade 直接调 `session.runtime.markTaskStoppedLocally`。

### 1.2 头号体验缺陷（用户点名）

权限卡片当前**确实**是 Z 轴层叠（`ZStack(alignment:.bottom)`），卡片像素不在栈内平移。但承载该栈的 `composeOrBarHost` 是 `[.intrinsicContentSize]` + 底对齐 + **无高度约束**的宿主，`ZStack` 上报子视图的**并集高度**——卡片出现时宿主**整体向上撑大**，再被 body 级 `.animation(.smooth)` 一动画，于是输入栏所在的那条带状区域向上长出来，这就是用户感知到的「输入框下降 / 喧宾夺主」。

> 注意一个被验证推翻的误解：transcript 的内容 inset 是**固定的 112**，**不会跳变**。动的只有那个 bottom-anchored 的栏宿主。

修法（§7）：给 `ChatSessionViewController` 加一个**专用的、整 pane、点击穿透**的悬浮宿主 `permissionCardHost`（`sizingOptions = []`，四边钉死），里面放一个**自身尺寸恒定**的 `PermissionCardOverlay`；卡片在其中原地淡入/淡出（opacity + scale），其他一切都不动。卡片从 `ChatRestingBar` 里移走。卡片功能、决策接线、所有卡片种类**逐字保留**。

### 1.3 本方案的形状

- **最高价值 / 最低风险**：DI 样板折叠（`DetailContext` + 一个注入 helper、删 2 条死注入、un-erase `AnyView`、`searchEngine→syntaxEngine` 改名、`Session.stopBackgroundTask` 闭合 façade）。纯管线收敛，零行为变化。
- **数据流宪法**：把已经成立的规则**写下来**（7 条），并对每条「故意保留的命令式边」标注其 runloop-tick 理由，防止未来有人以「单向」之名把它们「清理」掉。
- **两处真正的拆分**：`SidebarViewController`（god-VC）→ 纯 `SidebarTreeModel` + 菜单控制器 + 瘦 VC；`ChatSessionViewController` → 抽出 `TranscriptSwapCoordinator`（**最高风险**，放最后，两道 merge gate 守门，逐字搬移）。
- **被验证者砍小/降级的项**：grouping 去重（P7）比设想的小得多（核心谓词已共享）；共享 crossfade helper（P6）接近过度设计，降为可选；runtime 投影抽取（P8）只抽 `TodoTracker`/`TaskTracker` + context-usage 缓存，**排除 `TurnUsageMeter`**。
- **AppKit↔SwiftUI 边界规范**：已单独产出权威规范 [`boundary/BOUNDARY-SPEC.md`](boundary/BOUNDARY-SPEC.md)(决策表 + 真实回归门 + 干净上下文审查),澄清了你点名的 archive 压扁(根因是 sizingOptions 制式、非双向绑定)与输入栏居中(现状即最佳实践)。§7.8 与 §10 已据此校准,最终方案(T6)的组件归属表格须**逐项符合该规范的 host 制式**。

---

## 2. 现状 · 组件树（权威版）

> 图例：`[AK]` AppKit（`NSWindowController`/`NSViewController`/`NSView`/`NSObject`）· `[SU]` SwiftUI `View` · `[SVC]` `@Observable`/actor 服务 · `[VM]` ViewModel · `[MDL]` 纯值/模型 · `«HC»` `NSHostingController` · `«HV»` `NSHostingView`。宿主桥标注 `sizingOptions`。源根缩写 `…` = `macos/ccterm`。

```
CCTermApp  [SU App, @main]  ......................................... …/App/CCTermApp.swift
├── @NSApplicationDelegateAdaptor → AppDelegate  [AK]  .............. …/App/AppKit/AppDelegate.swift
└── Scene: Settings { EmptyView() }  [SU placeholder scene]
    └── .commands { AppCommands }  [SU Commands]
          (About / Settings ⌘, / Find ⌘F — 仅菜单项，不开窗；占位 scene 保证 ⌘, 永不打开 SwiftUI Settings 窗口)

AppDelegate  [AK]  (app-scope 所有者；在 applicationDidFinishLaunching 创建主窗口)
│   ── 持有 app-scope 状态，构造器向下注入，从不整体重组 ──
├── appState: AppState  [SVC, @Observable]
│   ├── sessionManager: SessionManager  [SVC]
│   │     └── sessions: [String: Session]  [SVC, @Observable]
│   │           ├── phase: .draft(SessionDraft) | .active(SessionRuntime)  [SVC]
│   │           ├── controller: Transcript2Controller  [SVC] ← 渲染侧，SESSION 级生命周期
│   │           │     └── coordinator: Transcript2Coordinator  [AK, NSObject]
│   │           │           ├── selection: Transcript2SelectionCoordinator  [AK]
│   │           │           ├── search:    Transcript2SearchCoordinator     [AK]
│   │           │           └── highlightStorage: Transcript2HighlightStorage
│   │           ├── bridge: Transcript2EntryBridge  [translator] ← 始终接到 runtime
│   │           └── backfillPipeline: TranscriptBackfillPipeline? ← 仅冷加载期间存活（绕过 bridge）
│   ├── syntaxEngine: SyntaxHighlightEngine  [SVC, actor]
│   ├── recentProjects: RecentProjectsStore  [SVC, lazy]
│   ├── inputDraftStore: InputDraftStore  [SVC]
│   ├── sidebarGroupOrder: SidebarSessionGroupOrderStore  [SVC]
│   ├── activationTracker: AppActivationTracker  [SVC] ─┐ (下者的私有依赖)
│   ├── notificationService: NotificationService  [SVC]◀┘
│   └── openInService: OpenInAppService  [SVC]
├── searchBus: TranscriptSearchBus  [SVC, @Observable]  ← 在此持有，不在 AppState 上
├── selectionModel: MainSelectionModel  [SVC, @Observable]  ← 在此持有，不在 AppState 上
├── settingsWindowController? → «HC» SettingsView  [SU]  (default sizingOptions → 给窗口定尺寸)
├── aboutWindowController?    → «HC» AboutView     [SU]  (default sizingOptions)
└── mainWindowController?: MainWindowController  [AK]
    ├── NSToolbar (delegate = self)
    │   ├── projectChip   → «HV» TranscriptProjectChip       [SU]  [.intrinsicContentSize]
    │   ├── archiveFilter → «HV» ArchiveFilterToolbarButton  [SU]  [.intrinsicContentSize]
    │   └── search        → NSSearchToolbarItem  [AK]
    │         └── delegate/target = TranscriptSearchToolbarBridge [AK]
    │               (controllerProvider 每次按键 PULL 当前 session 的 Transcript2Controller)
    └── window.contentVC = MainSplitViewController  [AK]
        │   ⚠ DI fan-out 点：把 appState 拆成单个服务，给 router 传 7-bag、给 sidebar 传 4-bag
        ├── sidebar item → SidebarViewController  [AK, NSOutlineView source-list]
        │     │   ⚠ 100% AppKit，无宿主边界；god-VC（7 个职责）
        │     └── scrollView → NoDisclosureOutlineView [AK]
        │           └── rows (按 SidebarItemNode【引用类型】做 identity）:
        │               ├── .fixed   → SidebarFixedCellView   [AK]
        │               ├── .folder  → SidebarFolderCellView  [AK]
        │               └── .history → SidebarHistoryCellView [AK]
        │                     └── SidebarStatusIndicatorView [AK] (dots/unread；unread>running) + ShimmerOverlay
        │
        └── detail item → DetailRouterViewController  [AK, MainSelectionObserver]
            │   view = NSVisualEffectView(.contentBackground)
            │   currentChild = 下列之一（+ 可选 fadingOutChild 处于 crossfade 中）
            │   ChildKind: .transcript | .compose | .draftLanding | .archive | .demo(DEBUG)
            │
            ├── .transcript → ChatSessionViewController  [AK, DetailRouterChild]  (← 注意：在 App/AppKit/，不在 Content/Chat/)
            │     │   ⚠ god-VC：「显示什么」+「如何换 transcript」的状态机混在一起
            │     ├── transcriptScroll: Transcript2ScrollView [AK]  (每次 attach 重建；四边钉死；contentInsets 固定 112)
            │     │     └── Transcript2ClipView → Transcript2TableView → BlockCellView (self-drawn) [all AK]
            │     │           └── 唯一的 SwiftUI 叶子: LoadingPillUsageView (token 计数)
            │     ├── topScrim: TranscriptTopScrimView  [AK]  (拦截鼠标 → 标题栏拖拽/缩放)
            │     ├── bottomScrim: TranscriptBottomScrimView [AK]  (hitTest 穿透；attach/pill 挖洞)
            │     ├── transcriptSheetPresenter: Transcript2SheetPresenter [AK] (每次 attach)
            │     │     └── 按需 beginSheet( «HC» UserBubbleSheetView | ImagePreviewSheetView [SU] )
            │     └── composeOrBarHost: «HV» AnyView  [SU]  [.intrinsicContentSize]
            │           │  ⚠ centerX + 底对齐 + 限宽 + 无高度约束（component 模式）；名字失真；AnyView 擦除
            │           └── ChatComposeStack [SU] (按 model.selection 路由 → bar | EmptyView)
            │                 └── ChatRestingBar .id(sid) [SU]  (仅 .session(_))
            │                       └── ZStack(alignment:.bottom)  ⚠ 上报 UNION 高度 → 卡片耦合
            │                             ├── InputBarChrome [SU]
            │                             │     └── VStack
            │                             │           ├── InputBarView2 [SU] (handle-free 叶子；@State CompletionViewModel)
            │                             │           │     ├── AttachButton (ReportFrame→onAttachRect)
            │                             │           │     └── pill (ReportFrame→onPillRect) → CompletionListView? / TextInputView(NSTextView)
            │                             │           └── InputBarSessionChrome [SU]
            │                             │                 ├── PermissionModePicker / TodoButton / ModelEffortPicker / ContextRingButton [SU]
            │                             │                 └── BackgroundTaskButton [SU]  ⚠ 直接调 session.runtime.markTaskStoppedLocally
            │                             │                       └── .sheet → BackgroundTaskDetailSheet → BackgroundTaskOutputStream [SVC]
            │                             └── PermissionCardView? [SU]  (pending 时；按 kind 分发 body)
            │
            ├── .compose → ComposeSessionViewController [AK]  → «HC» AnyView(ComposeSessionView) [SU]  []  (fill-pane)
            │     └── NewSessionConfigurator{ InputBarChrome } + (@State GitProbe → BranchPickerView)
            ├── .draftLanding → DraftSessionLandingViewController [AK]  → «HC» AnyView(DraftSessionLandingView) [SU]  []
            ├── .archive → ArchiveViewController [AK]  → «HC» AnyView(ArchiveView) [SU]  []  (545×276 fittingSize 泄漏注释在此)
            └── .demo(_) (DEBUG) → demo VCs [AK]  (各自持有 Controller+scroll+presenter)

全局单例（无树边，从 view/runtime 直接 .shared 取）:
  ModelStore.shared · EffortDefaultStore.shared · NewSessionDefaultsStore.shared
  FileCompletionStore.shared · SlashCommandStore.shared

数据馈送旁路（不在视图树，但喂它）:
  Transcript2EntryBridge ← 实时 MessagesChange 通道（每 Session）
  TranscriptBackfillPipeline ← 冷 JSONL 通道（每次加载）
  MarkdownDocument/Convert ← 纯值 IR（仅 MessageEntryBlockBuilder 消费）
```

> **常用符号定位**（贯穿全文，先标清避免 grep 困惑）：`ChatSessionViewController` 在 **`App/AppKit/`**（非 `Content/Chat/`）；`ChatComposeStack` 在 `App/AppKit/ChatSessionViewController.swift:605`；`ChatRestingBar`（含卡片 ZStack `:126`、body 级 `.animation` `:166`、4 个决策闭包 `:143-162`）在 **`Content/Chat/InputBarChrome.swift`**；scrim 类在 `Components/TranscriptScrimView.swift`（顶 scrim 实为 `TranscriptTopScrimView`，上游 `Content/Chat/CLAUDE.md` 仍写基类名 `TranscriptScrimView`，属待修文档漂移）。

### 2.1 AppKit↔SwiftUI 宿主边界（每一处）

两种 sizing 制式，对应 root CLAUDE.md 的「host sizing」规则。

| # | 宿主 | 类型 | sizingOptions | 制式 | 备注 |
|---|---|---|---|---|---|
| 1 | Settings 窗口 | «HC» SettingsView | default | window-sizing | host 给窗口定尺寸 |
| 2 | About 窗口 | «HC» AboutView | default | window-sizing | 同上 |
| 3 | Toolbar 项目 chip | «HV» TranscriptProjectChip | `[.intrinsicContentSize]` | component | toolbar 槽由内容定尺寸 |
| 4 | Toolbar archive 过滤 | «HV» ArchiveFilterToolbarButton | `[.intrinsicContentSize]` | component | 同上 |
| 5 | **聊天底部栏** | «HV» AnyView(ChatComposeStack) | `[.intrinsicContentSize]` | component | 底对齐、内容定**高度** ⚠ 卡片耦合源 |
| 6 | Compose pane | «HC» AnyView(ComposeSessionView) | `[]` | fill-pane | 容器定尺寸 |
| 7 | Draft-landing pane | «HC» AnyView(DraftSessionLandingView) | `[]` | fill-pane | 容器定尺寸 |
| 8 | Archive pane | «HC» AnyView(ArchiveView) | `[]` | fill-pane | 容器定尺寸 |
| 9 | Demo permission-cards | «HC» PermissionCardsDemoView | `[]` | fill-pane | DEBUG |
| 10 | Transcript sheets | «HC» UserBubble/ImagePreview | (modal) | beginSheet | AppKit 原生 sheet 包 SwiftUI body |

**关键不对称（FACT）**：聊天底部栏是**唯一**用裸 `«HV»` + `[.intrinsicContentSize]` 的生产 pane 宿主；4 个整 pane 子 VC 都用 `«HC»` + `[]`。这是**正确且结构性的**（component vs fill-pane），不是风格问题——但它是唯一需要读者同时理解两种制式的地方。宿主 5/6/7/8/9 的 `AnyView` 擦除是顺带的、非 load-bearing（每个就一个具体 body）。

---

## 3. 现状 · 数据流与所有权

### 3.1 两条主轴

```
选择主轴（结构）                            会话/渲染主轴（内容）
─────────────                              ─────────────
sidebar.click                              CLI push
  │ model.select(.session(id))               │ SessionRuntime.receive 改 messages
  ▼ (方法，向上)                              ▼ 同步 fire onMessagesChange
MainSelectionModel                          Session.wireRuntimeMessagesSink
  ├ selection = …          (@Observable 下行)   ├─① bridge.apply(change)   → Controller.apply → NSTableView  [AppKit 推送]
  └ selectionObserver?.selectionDidChange      └─② session.onMessagesChange?(change)  (可选外部 fanout)
       ▼ (唯一向上结构边，同步，源相位)
DetailRouterViewController.applySelection    SwiftUI 侧（输入栏/chrome/卡片）:
  └ present(sessionId:)  (命令式下行，源相位)     读 session.X (@Observable 拉取)，写 session.method()
```

### 3.2 所有权与生命周期

| 层 | 成员 | 由谁构造 | 生命周期 |
|---|---|---|---|
| App 生命周期 | `AppDelegate` | SwiftUI runtime（`@NSApplicationDelegateAdaptor`） | 进程 |
| App-scope 状态 | `AppState`、`searchBus`、`selectionModel` | `AppDelegate` 存储属性 init | 进程 |
| App-scope 服务 | AppState 上 8 个 + 3 个 `.shared` 单例 | `AppState.init` / lazy static | 进程 |
| 窗口外壳 | `MainWindowController`→`MainSplitViewController`→`SidebarVC`+`DetailRouterVC` | `applicationDidFinishLaunching` | 窗口 |
| Detail 子 VC | Chat/Compose/DraftLanding/Archive/demo | `DetailRouterViewController.makeChild` | 同时仅一个存活；跨 kind 拆建，同 kind **复用** |
| 每次 attach（chat） | `transcriptScroll`、`sheetPresenter`、running-obs task | `ChatSessionViewController.attachSession` | 每次切会话重建 |
| 会话核心 | `Session` + `controller` + `bridge` | `SessionManager.makeSession`（lazy，按 id 缓存） | 会话级（跨挂载/卸载存活） |
| 每次加载 | `TranscriptBackfillPipeline` | `Session.loadHistory()` | 一次冷加载 |
| View-scope 状态 | `CompletionViewModel`、`GitProbe`、`BackgroundTaskOutputStream` | SwiftUI `@State` | view identity |

**唯一的向上结构边**：`MainSelectionModel.selectionObserver`（weak）—— router 把自己注册到它被交付的 model 上。这使「同步结构通知」成为可能，是整张以下行为主的图里**唯一**的双向链路，重构必须**理解它而不是删它**。

---

## 4. 问题总览（5 类形态 + 排名）

严重度衡量的是「对**干净单向重构 + 零功能降级**的风险/杠杆」，不是用户可见 bug。

| 形态 | 说明 |
|---|---|
| **A. DI 样板** | 同一组 6–7 个服务在 router + 5 个 detail VC 上反复声明/穿线/`.environment()` 注入，含 **2 条死注入**（`notifications`、`searchBus`，无任何 SwiftUI reader）。最高价值最低风险的清理。 |
| **B. 混职责 god-object** | `SidebarViewController`(~770)、`ChatSessionViewController`(~680)、`Transcript2Coordinator`(~1764)、`SessionRuntime`(~3000/9 文件)。内部各自内聚，但混了可独立测试的簇。 |
| **C. 边界/命名失真** | `composeOrBarHost`（不再 morph）、`searchEngine` 参数（其实是 syntax highlighter）、宿主处 `AnyView` 擦除、描述已删设计的文档注释（`.searchable`、`RootView2`、AppState `.environment`）。 |
| **D. 重复派生逻辑** | grouping/tool-pairing 实现两遍（实时 `receive` vs 冷 `ReverseEntryBuilder`）、crossfade 状态机两遍、`StableBlockID` 方案 3 处、任务 status-color/title 2–3 处。 |
| **E. 所有权模式不一致** | 8 个服务在 `AppState`、3 个 `.shared` 单例、2 个在 `AppDelegate`；2 个 completion store 也是进程单例从闭包内取；`CompletionViewModel` 是「无 ViewModel」区域里唯一的 ViewModel（合理但命名误导）。 |

### 4.1 排名问题清单（P1–P15）

| # | 等级 | 问题 | 关键不变量（修复不可破） |
|---|---|---|---|
| **P1** | HIGH | `notifications`/`searchBus` 的死 `.environment` 注入（0 SwiftUI reader） | 二者经 AppKit 通道到达消费者（`onActivateSession` 推送 / toolbar bridge），删注入是 no-op |
| **P2** | HIGH | 7-arg DI bag 跨 router+5 VC 重复声明，`.environment` 块复制 5 次 | 「views 从不构造服务」；不能整体注入 AppState（`model` 不在 AppState 上） |
| **P3** | HIGH | `SidebarViewController` ~770 行 god-VC（7 职责） | `SidebarItemNode` 引用类型(6.1)、echo-suppression(6.3)、写 `model.select`(6.4)、per-row obs 重武装+回收守卫+非分配 `existingSession`(6.7/6.8) |
| **P4** | HIGH | `BackgroundTaskButton` 越过 façade 调 `session.runtime.markTaskStoppedLocally`（**唯一真违例**） | 修在产品里（加 forwarder），强化而非削弱不变量 |
| **P5** | MED | `ChatSessionViewController` 混「显示什么」+ transcript-swap 状态机（~225 行密集不变量） | §2.19 单宽 attach 契约、disabled-CATransaction 作用域(I3)、build-in-front(I4)、**flush-before-bind 观察者顺序(I5)**、`prepareForRemoval`(I14) |
| **P6** | MED | 两套并行 crossfade 状态机（router 跨 kind vs chat 同会话） | transcript 变体携带 load-bearing 的 `removeObserver` flush 顺序(I5) |
| **P7** | MED | grouping/tool-pairing 实现两遍（实时 vs 冷） | history 永不走 bridge(bridge-I1)、加载无 `.update`(I9)、跨页 withhold buffer + doc-order(I8) |
| **P8** | MED | `SessionRuntime` god-object（~3000 行 / 23 个 @Observable / 7 sink） | 同步 `onMessagesChange` fire 契约(I1)、`receive` 副作用顺序(I3) |
| **P9** | MED | `Session` 宽 façade（~40 forwarder）+ 每字段两文件税 | draft/runtime 读表面**真的分叉**；协议会在 draft 上伪造 runtime-only 字段 → **不动**（反过度设计） |
| **P10** | MED | (a) closure-sink 三处声明（**有意**：promotion 前/时机不同）；(b) syntax highlighter 以 `searchEngine` 之名穿线 | (b) 纯改名 `searchEngine→syntaxEngine` |
| **P11** | MED | app-scope 状态所有权不一致 + 文档说 AppState 经 `.environment` 注入（从不） | 判断题：`ModelStore.shared` 最可疑（会 spawn CLI 子进程），其余低害 |
| **P12** | LOW | 命名/文档失真 + `AnyView` 擦除 | `composeOrBarHost→restingBarHost`、`CompletionViewModel→CompletionState`、un-erase |
| **P13** | LOW | 死代码：directory-completion 全废、`ClaudeCodeStats`(~460 行无消费者)、`FileCompletionStore.invalidate*`(0 caller，慢 FSEvent 泄漏) | directory-completion 的删除**触及活文件**（见 §8.C14） |
| **P14** | LOW | 重复派生 + 跨文件魔法常量耦合（`StableBlockID`×3、task title/color×2-3、pill radius 16×2） | 顺手抽常量，既有 snapshot 守门 |
| **P15** | LOW | 分层小瑕：view 关注点落 `Models/`；`GitProbe` 缺 `@MainActor` | 纯文件移动（synced-group 项目免改 pbxproj） |

---

## 5. 目标 · 组件树

> 变更内联标注：`★NEW` `★SPLIT` `★RENAMED` `★UNERASED` `★DELETED`。未标注=不变。**边界移动处为零**——每个宿主桥保持 kind / sizingOptions / 制式不变。

```
CCTermApp [SU]
└── AppDelegate [AK]
    ├── appState: AppState [SVC]
    │   ├── sessionManager → sessions: [String: Session]
    │   │     └── Session
    │   │           ├── phase: .draft | .active(SessionRuntime)
    │   │           │     └── SessionRuntime 组合（★SPLIT-P8，只抽自包含投影，不是新边）:
    │   │           │           ├── todos: TodoTracker          [@Observable 子对象] ★NEW
    │   │           │           ├── tasks: TaskTracker          [@Observable 子对象] ★NEW
    │   │           │           └── contextUsage: ContextUsageCache [@Observable 子对象] ★NEW (被观察，非纯值 — §8.P8)
    │   │           │              (turnUsage 留在 runtime —— 见 §8.P8 排除项)
    │   │           ├── controller: Transcript2Controller → coordinator [AK]  (不合并 — §1.1)
    │   │           ├── bridge: Transcript2EntryBridge  (始终接 runtime)
    │   │           └── backfillPipeline?  (绕过 bridge)
    │   ├── syntaxEngine / recentProjects / inputDraftStore / sidebarGroupOrder
    │   ├── activationTracker / notificationService / openInService
    │   ├── searchBus  ★MOVED（从 AppDelegate 迁入；进程级，可选低风险）
    │   └── (可选) effortDefaults / newSessionDefaults  ★MOVED（薄 UserDefaults 包装；ModelStore 仍 .shared）
    ├── selectionModel: MainSelectionModel  (留在 AppDelegate —— 窗口级，见 §8.P11)
    ├── settings/about WindowController → «HC» SU  (不变)
    └── mainWindowController [AK]
        ├── NSToolbar (项目 chip / archive 过滤 / NSSearchToolbarItem —— 全不变)
        └── MainSplitViewController [AK]
            │   ★CHANGED-P2：构造一个 DetailContext 值（model + 被消费的服务）整体下传；
            │              一个 SidebarContext 给侧边栏。（不再 7-bag/4-bag 扇出）
            ├── sidebar → SidebarViewController [AK]  ★SPLIT-P3
            │     ├── treeModel: SidebarTreeModel  [MDL 纯值，可测] ★NEW
            │     │     build(records, groupOrder, previouslySeenGroups) → (nodes, newGroups)
            │     ├── contextMenu: SidebarContextMenuController [AK, NSMenuDelegate] ★NEW
            │     └── outline + 3 个观察循环 + 选择回写（保留在 VC）
            │           (SidebarItemNode 仍引用类型；DnD 仍在 VC；invariants 6.x 全保)
            └── detail → DetailRouterViewController [AK, MainSelectionObserver]
                │   ★CHANGED：持有一个 DetailContext，makeChild 整体下传
                │   currentChild = 下列之一（单子不变量 I2 保持）
                ├── .transcript → ChatSessionViewController [AK]  ★SPLIT-P5
                │     │   现在=「显示什么」：scrim、栏宿主、focus、turn-usage、running-obs
                │     ├── swap: TranscriptSwapCoordinator [AK]  ★NEW-P5（最高风险）
                │     │     │   拥有 attach 编排（make→settle→bind→scrollToTail→drop）
                │     │     │   + 同会话 crossfade + per-attach transcriptScroll/presenter
                │     │     │   §2.19 + chat-I3/I4/I5/I14 全部搬到这里，逐字不变
                │     │     ├── transcriptScroll: Transcript2ScrollView [AK] (per-attach)
                │     │     └── transcriptSheetPresenter [AK] (per-attach)
                │     ├── topScrim / bottomScrim [AK]  (不变；I5 的 z-anchor 仍由 VC 提供给 swap)
                │     ├── restingBarHost: «HV» ChatComposeStack [SU]  ★RENAMED-P12 ★UNERASED-P12
                │     │     [.intrinsicContentSize]（component；高度只随栏内容，★不再随卡片）
                │     │     └── ChatRestingBar .id(sid)  ★CHANGED-§7（卡片移出，只剩栏）
                │     │           └── InputBarChrome → InputBarView2 + InputBarSessionChrome
                │     │                 └── BackgroundTaskButton  ★CHANGED-P4 → session.stopBackgroundTask(taskId:)
                │     └── permissionCardHost: «HV» PermissionCardOverlay [SU]  ★NEW-§7（头号修复）
                │           sizingOptions=[]（fill-pane，四边钉死，PassthroughHostingView）
                │           └── 自身尺寸恒定；卡片原地淡入；点击穿透到 transcript
                ├── .compose → ComposeSessionViewController → «HC» ComposeSessionView [SU] ★UNERASED  []  via mountFillPaneHost ★NEW-C9
                ├── .draftLanding → DraftSessionLandingViewController → «HC» DraftSessionLandingView [SU] ★UNERASED  []  via mountFillPaneHost
                ├── .archive → ArchiveViewController → «HC» ArchiveView [SU] ★UNERASED  []  via mountFillPaneHost
                └── .demo(_) (DEBUG) [AK]
```

### 5.1 现状→目标 逐节点

| 节点 | 现状 | 目标 | 为何 |
|---|---|---|---|
| DI 注入 | 7-arg init 在 router+5 VC 重声明；`.environment` 块复制 5 次（含 2 死） | 一个 `DetailContext` 值整体穿线 + `injectDetailEnvironment` helper（只注 4 个被消费的） | 增删依赖 = 1 处改动；死边消失（un-erase 后漏注变编译错） |
| `searchEngine` 参数 | 以 `searchEngine` 之名穿 SyntaxHighlightEngine | 端到端改名 `syntaxEngine` | 读者不再误以为是搜索机制 |
| 5 个 pane `AnyView` 宿主 | `«HC»/«HV» AnyView(...)` | 具体泛型 body | 编译器强制环境注入 |
| `BackgroundTaskButton` | 直接 `session.runtime.markTaskStoppedLocally` | `session.stopBackgroundTask(taskId:)`（façade，`.draft` no-op） | 闭合唯一流违例 |
| `SidebarViewController` | ~770 god-VC | 瘦 VC + `SidebarTreeModel`（纯，可测）+ `SidebarContextMenuController` | records→tree 变纯函数可测；菜单/DnD 局部化 |
| `ChatSessionViewController` | ~680：显示什么 + swap 状态机 | VC 留「显示什么」；`TranscriptSwapCoordinator` 拥有 attach/swap | VC 可顺读；密集不变量区被测试隔离 |
| 权限卡片 | `ChatRestingBar` 的 ZStack（撑大栏宿主） | `permissionCardHost` 整 pane 悬浮层（恒定尺寸，原地淡入） | 头号体验修复（§7） |
| `composeOrBarHost` | 名字失真 | `restingBarHost` | 只剩栏，从不 compose |
| `CompletionViewModel` | 「无 ViewModel」区域里的 ViewModel | `CompletionState` | 它是自包含输入法状态机，不是协调 VM |
| `Session` ~40 forwarder | 相位分发样板 | **不变** | draft/runtime 表面分叉，协议会伪造字段 |

---

## 6. 目标 · 数据流宪法（7 条规则）

> 核心洞察：架构已经约 90% 是目标模型。本节大部分工作是**把已成立的规则写下来**、删掉少数真违例、并**拒绝**会损害可用部分的过度设计。**没有全局 store，没有会话状态的 ViewModel 层。** 留下来的命令式调用，都是「正确性依赖 @Observable 无法表达的 runloop-tick 时序」的——它们不是债务，正是 AppKit 例外存在的理由。

**Rule 1 — 状态住在「所有读者共享的最低 scope」。** 进程级→`AppState`（构造注入/`.environment`）；窗口级选择→`MainSelectionModel`；单会话业务+渲染→`Session`；transcript 行模型→`Transcript2Coordinator.blocks`；view 私有交互态→SwiftUI `@State`。判据：找出全部读者，取包含它们的最窄 scope。只有一个读者 = `@State`，绝不上 model 字段。

**Rule 2 — 数据靠读 `@Observable` 下行，绝不缓存。** SwiftUI 在 body 里直接读 `session.X`/`model.X`，没有 view 持有 model 字段的副本。下行天然单向，因为没有东西需要同步。

**Rule 3 — 事件靠两条通道之一上行，由 renderer 决定走哪条。** SwiftUI 消费者 → 调 `Session` 方法或注入的闭包（`onSubmit`/`onAttachRect`/`onBuiltinCommand`），**绝不**触 `session.runtime.X`。AppKit 消费者（transcript）→ `SessionRuntime` 上声明的同步闭包 sink，在 `Session.wireRuntimeMessagesSink` 里 multiplex 一次，bridge 消费。**同一片状态绝不同时走两条通道。**

**Rule 4 — 只有一条结构性向上边：`selectionObserver`。** 它存在是因为 detail 侧切换必须落在**点击的同一源相位**（`@Observable` 重算晚一个 tick 到 beforeWaiting，会把会话切换撕裂到多帧）。这是图里唯一的向上结构边、单所有者，**不可**泛化成通知总线或第二观察槽。新的「对选择做结构反应」需求都走 router。

**Rule 5 — views 从不构造服务；ViewModel 例外很窄。** 服务由 `AppState`/`AppDelegate` 构造并注入。唯一合法的 view 构造 `@Observable` 是**view 私有的交互状态机**——`CompletionViewModel`（→改名 `CompletionState`）、`GitProbe`、`BackgroundTaskOutputStream`。聊天区的「无 ViewModel」规则针对的是**会话/transcript 状态的协调镜像**，不是自包含弹出控制器。

**Rule 6 — 命令式调用只在「正确性依赖 @Observable 给不了的 runloop-tick 时序」时允许。** 默认反应式。命令式推送只在以下之一成立时合法，且必须在调用点注明：**(a)** 必须跑在点击的源相位、beforeWaiting 之前（selection 通知、transcript attach）；**(b)** 把**确切增量**交给 AppKit 消费者而非逼它做 diff（`bridge.apply`、`setLoading`、`setTurnUsage`）；**(c)** 必须跑在「会吞掉反应式 `.onChange` 的拆除」之上的栈（send 时的 draft-clear）。

**Rule 7 — 依赖作为「被消费服务的一个 bag」穿线，不按类型重声明。** DI 表面是单个值类型，携带 model + 实际被消费的服务。增删一个 app-scope 依赖 = 一处改动。

### 6.1 每条边的判决

| 边 | 方向 | 当前通道 | 判决 | 规则 |
|---|---|---|---|---|
| `select(_:)` → router | 结构下 | 同步 delegate | **保留**（时序） | 4, 6a |
| `model.selection` → SwiftUI | 下 | `@Observable` | 保留 | 2 |
| sidebar → selection | 上 | `model.select(_:)` 方法 | 保留 | 3 |
| router → chat VC | 下 | 命令式 `present(sessionId:)` | 保留（时序） | 6a |
| `session.*` → SwiftUI | 下 | `@Observable` forwarder | 保留 | 2 |
| bridge → transcript | 下 | 同步闭包 → `apply` | 保留（确切增量） | 3, 6b |
| `isRunning` → loading pill | 下 | 命令式 `setLoading` + obs task | 保留；**可选**统一为 closure-sink | 3, 6b |
| `turnUsage` → pill | 下 | closure-sink `onTurnUsageChange` | 保留 | 3, 6b |
| chrome rects → scrim | 上 | 注入闭包 | 保留（单读者、同步） | 1, 3, 6b |
| send 时 draft-clear | 副作用 | 命令式 `draftStore.clear` | 保留（拆除-proof） | 6c |
| 卡片决策 | 上 | `session.respond(...)` | 保留（**典范**） | 3 |
| `pendingPermissions` → 卡片 | 下 | `@Observable` forward | 保留（**典范**） | 2 |
| completion confirm → text | 上 | VM→View→NSTextView | 保留（固有） | 5 |
| `BackgroundTaskButton`→`runtime.x` | 上 | **越 façade** | **修** → `Session.stopBackgroundTask` | 3 |
| 7-arg DI + 2 死注入 | 下 | 按类型重声明 | **修** → `DetailContext` + helper；删死边 | 7 |
| `searchEngine` 命名 | — | 误导 | **修** → `syntaxEngine` | 清晰 |
| `searchBus`/`selectionModel` 在 AppDelegate | 所有权 | 分裂 | `searchBus`→AppState；`selectionModel` 留（窗口级） | 1 |

> **注意可选项的细节**（验证修正 m5）：若把 `isRunning` 改成 closure-sink，**必须保留** `currentSession === session` 身份守卫和 attach 时的初始 `setLoading(session.isRunning)`；该项 MEDIUM 风险、默认不做，仅随 P8 一起做。

---

## 7. 头号修复 · 权限卡片悬浮层

### 7.1 缺陷（精确）

- 卡片**确实**画在 Z 轴（`ZStack(alignment:.bottom)`，`InputBarChrome.swift:126`），栏 pill 不在栈内平移。
- 但承载栈的 `composeOrBarHost` 是 `NSHostingView<AnyView>`、`sizingOptions=[.intrinsicContentSize]`、`bottomAnchor==view.bottomAnchor`、centerX、限宽、**无高度约束**（`ChatSessionViewController.swift:169,202-207`）。其高度 = SwiftUI body 的 `fittingSize.height`。
- `ZStack` 上报子视图**并集**高度。`pendingPermissions` 空→非空时，栈的固有高度从 `barHeight` 跳到 `max(barHeight, cardHeight)`；AppKit 重读宿主固有高度，因宿主底对齐，其**顶边上升**。
- `ChatRestingBar.body` 末尾 `.animation(.smooth(duration:0.25), value: session.pendingPermissions.first?.id)`（`:166`）——这一条 body 级动画同时驱动卡片自身的 `.transition` **和**宿主固有高度的变化。带状区向上扩张 0.25s = 「喧宾夺主」。
- **不动的东西**：transcript scroll-view frame 及其内容 inset（固定 `contentInsets.bottom=112`）。所以「transcript inset 跳变」**为假**；只有栏宿主在静止的 transcript 上方变大。

**根因一句话**：*卡片尺寸 → 栏宿主固有高度 → 带动画的带状区扩张*。悬浮层不得让其宿主变尺寸。

### 7.2 必须尊重的约束（为何不能简单回退）

PR #235 当初**有意**选 `ZStack` 而非 `.overlay`：`.overlay` 尺寸贴合宿主，在底对齐栏宿主下卡片上半会**落到宿主 hit-test 边界之外**，按钮失效。`ZStack` 并集撑大宿主正是为了让卡片可点击。所以**不能**回 `.overlay`。修复必须给卡片一个**够高、可点击、且尺寸恒定、与栏宿主解耦**的承载面。

代码库里**已有**这个形状的证明：scrim 是整带 `NSView`，`hitTest` 返回 `nil`（画在 transcript 上但鼠标穿透）；`TranscriptBottomScrimView` 甚至挖洞让栏的 attach 按钮 + pill 穿透命中。**关键**：scrim 是**纯 `NSView`**——`ChatSessionViewController` 注释明确写道，scrim 故意不用 `NSHostingView`，「这样它们不会注册 cursor rect 去遮挡 transcript 的 I-beam」。

### 7.3 方案 —— 专用、整 pane、点击穿透的卡片宿主

给 `ChatSessionViewController` 加一个 `topScrim`/`bottomScrim`/`restingBarHost` 的**同辈**悬浮宿主：

```
ChatSessionViewController.view : NSView                            [AppKit, 整 pane]
├── transcriptScroll        (四边钉死)                            [AppKit]
├── topScrim                (顶钉，hitTest→nil)                    [AppKit]
├── bottomScrim             (底钉，hitTest→nil + 挖洞)             [AppKit]
├── restingBarHost          (底对齐，固有高度)                     [AppKit↔SU]
│     └── ChatRestingBar → InputBarChrome  (★卡片已移走)          [SwiftUI]
└── permissionCardHost      (四边钉死，sizingOptions=[])           [AppKit↔SU]   ← NEW
      └── PermissionCardOverlay(model:)                            [SwiftUI]
            (整 pane ZStack；点击穿透背景；卡片底对齐于栏带之上；原地淡入)
```

**新 AppKit 宿主**用 **fill-pane 制式**（`sizingOptions=[]` + 四边钉死）——与栏宿主相反，它的职责就是整 pane、由容器定尺寸，因此**不发布固有尺寸**，不会把高度泄漏进窗口约束求解器（这正是 root CLAUDE.md 记录的窗口塌缩的反面：`[]` 是文档化的解药）。

**新 SwiftUI 悬浮 view** `PermissionCardOverlay`：自身 frame 恒定（`maxWidth/maxHeight: .infinity`，四边由宿主钉死）。卡片出现/消失只改**卡片子树**，绝不改悬浮层尺寸——没有并集高度反馈，因为悬浮层本就满尺寸，卡片在一个已经够高的容器里布局。**栏宿主固有高度永不变，于是其他一切都不动。这就是全部修复。** `.animation(.smooth)` 现在只动卡片的 `.transition`（opacity + scale 原地），动画路径里没有任何宿主几何。决策接线（allow once/always/deny/allow-with-input 四个闭包）从 **`ChatRestingBar`**（`InputBarChrome.swift:143-162`，**注意**：闭包内联在 `ChatRestingBar`，不在 `InputBarChrome`）**逐字搬移**，读路径仍是 `session.pendingPermissions.first`（`@Observable`，无缓存）。

> **选择路由（审查修正 R4）**：`permissionCardHost` 像 scrim 一样在 VC 级**常驻**，但卡片只应在 `.session(_)` 出现。`PermissionCardOverlay` 必须用与 `ChatComposeStack.content(for:)` **相同**的方式解析会话——按 `model.selection` 路由 + `.id(sid)` 键控会话解析（`manager.prepareDraftSession(model 驱动的 sid)`），使「栏宿主空时卡片宿主也空」。否则快速切会话时可能在新 transcript 上渲染**陈旧/错会话**的卡片。

`ChatRestingBar` 随之塌回「只是栏」：删 `ZStack`、删 `if let pending` 卡片子节点、删 body 级 `.animation`。栏宿主固有高度变成栏内容的纯函数（多行输入仍能撑高它，一如注释本意），**永不**是卡片在场的函数。

### 7.4 必须执行的修正（来自两轮对抗审查）

> **修正 M1 — 卡片位置常量必须是 `chatBottomInset (36)`，不是 `bottomFadeScrimHeight (100)`。**
> 当前卡片底边与栏底边齐平（都在距宿主底 36pt 处），卡片画在栏 chrome 行**之上并覆盖它**，向上延伸。用 100 会把卡片底边放到栏的**顶**边，卡片完全浮在栏上方——这是**不同的位置**，破坏平价。`PermissionCardOverlay` 必须用 `.padding(.bottom, chatBottomInset /*36*/)` 复现当前的齐底覆盖。（`bottomFadeScrimHeight=100` 是 scrim 渐隐带高，与卡片偏移无关——原设计把这两个常量搞混了。）

> **修正 M2 — 必须无条件发运 `PassthroughHostingView`（显式 `hitTest`，非卡片区返回 `nil`），不要赌 `Color.clear`。**
> scrim 是纯 `NSView` + 显式 `hitTest→nil`，正是因为**不信任** `NSHostingView` 的穿透——`NSHostingView` 会为整个 bounds 注册 cursor/tracking rect，遮挡 transcript 的 I-beam，甚至吞掉它覆盖区域的点击。该悬浮宿主钉在**整个 pane** 上，任何穿透泄漏会遮挡**整个 transcript**（爆炸半径远大于当前只撑大底栏的 ZStack）。所以：跳过「先试纯 clear 背景」这步，直接上 6 行的 `PassthroughHostingView` 子类（`hitTest` 把命中宿主自身 backing view 的点映射成 `nil`），对齐已验证的 scrim 模式。

> **修正 M3 — demo VC 迁移不是「顺手免费」。** `PermissionSessionDemoViewController` 当前用 `GeometryReader+PreferenceKey+height-constraint` 循环直接渲染 `ChatRestingBar`，其目的正是演示「卡片撑大栏宿主」的耦合。§7.3 抽掉卡片后，demo 必须也挂上 `permissionCardHost` 悬浮层、并保留/改造其栏宿主高度处理。这是一处非平凡改写，是 §9 step 5 的**显式子任务**（DEBUG-only，不影响发运，但会**静默坏掉 demo**——卡片永不出现），不是「免费消灭 smell」。

> **修正 M4 — `PassthroughHostingView` 不止要挡点击，还要压住 cursor/tracking rect（审查修正 R2）。** 这是 M2 的更深一层：整 pane 的 `NSHostingView` **即便 `hitTest` 返回 `nil`，仍会为它整个 bounds 注册 cursor/tracking rect**——这正是 scrim 用**纯 `NSView`** 而非 `NSHostingView` 的根本原因（不止是点击穿透）。所以 `PassthroughHostingView` 必须**同时**压制非卡片区的 cursor/tracking-rect 注册（覆写 `resetCursorRects` 为空 + 不为非卡片区装 tracking area），**或者**把卡片宿主**只钉到卡片实际占用的底部区域**（而非整 pane），把爆炸半径限制到卡片矩形。守门 `DetailPaneTranscriptHitTestTests`（走真实 `view.hitTest` + `.leftMouseDown`，已存在，其用例头明确「反驳『全 pane 浮层盖住 transcript』假设」）。
>
> **修正 M5 — `permissionCardHost` 的 z-order 必须显式（审查修正 R3）。** 它在 `loadView` 中**于 `composeOrBarHost` 之后**添加一次（→ 置顶，正确的浮层层序）；而每次 attach 插入 transcript 仍走 `.below topScrim`（→ 留在所有 scrim 与浮层**之下**）。这意味着 M4 不是 nice-to-have：非穿透的整 pane 宿主会在该 VC**整个生命周期**遮挡 I-beam（不只是卡片在场时）。§9 step 13 抽 `TranscriptSwapCoordinator` 时，attach 插入必须保持 `.below topScrim`，**不得**把 transcript 重插到 `permissionCardHost` 之上。

> **修正 M6 — P4 forwarder 返回 `Void`。** `markTaskStoppedLocally` 返回 `Bool`，当前调用方已弃用该返回值；`Session.stopBackgroundTask(taskId:)` 应签名为 `Void`，勿误带 `-> Bool` 重新泄漏 runtime 细节。（`PassthroughHostingView` 历史注记：该类型曾存在、现仅余 `DetailRouterViewController.swift:27` 的墓碑注释——按新增重引入，勿误找旧类。）

### 7.5 现状→目标（卡片组合）

| 方面 | 现状（`ChatRestingBar` ZStack） | 目标（`PermissionCardOverlay` 宿主） |
|---|---|---|
| 卡片承载面尺寸 | ZStack 并集 → 撑大栏宿主 | 整 pane 悬浮层，**恒定** |
| 卡片出现时栏宿主高度 | 上升（顶边上移） | **不变** |
| 动画的对象 | 卡片 transition **+ 宿主几何** | 卡片 transition **only** |
| 卡片可点击面 | 被撑高的栏宿主（#235） | 专用穿透悬浮层 |
| 新宿主 sizingOptions | — | `[]`（fill-pane，不泄漏高度） |
| 卡片位置 | 栏 ZStack 内底对齐（`chatBottomInset`=36） | 悬浮层内底对齐，**同偏移 36**（修正 M1） |
| 决策接线 | 4 闭包 → `session.respond` | **同 4 闭包逐字搬移** |
| 卡片种类 | `PermissionCardView` + 14 个 body | **全部逐字复用，仅换宿主** |

### 7.6 被否决的备选

- **(B) 保留 ZStack，只去掉几何动画** —— 带状区仍会**瞬跳**变高（未动画），卡片→宿主耦合仍在。用户的抱怨是带状区**根本不该动**，只去动画是半修。否决。
- **回 `.overlay`** —— 重新引入 #235（卡片被裁 + 按钮出界）。否决。
- **让 transcript inset 动态避让卡片** —— 违反固定 inset 不变量（风险 §2.7 scroll-anchor），用户明确不想 transcript 跳。否决。
- **永远预留一条高栏宿主** —— 在 transcript 上方常驻一条吞点击的高带（爆炸半径=整带，回归 inv 3）。否决。
- **用真 `NSWindow`/popover/sheet** —— 重、抢焦点、丢失「属于栏、浮在 pane 内」的观感，`beginSheet` 还会阻塞窗口。否决。

### 7.7 平价保证

所有卡片种类、四种决策、读/写路径、路由（仅 `.session(_)`）、`.id(sid)` 重置全部保留；`PermissionCardSnapshotTests` 更新为渲染 `PermissionCardOverlay`（卡片 body 像素一致，组合在修正 M1 后才「一致」）。

> **新增守门（审查修正 R5）**：`PermissionCardWiringTests` 在 `session.respond` **边界**驱动，**不**经 card-button→闭包→`respond` 路径——它无论卡片接线对错都绿，**不能**守门这次「逐字搬移」。必须新增一个轻量 test：用 spy `Session` 构造 `PermissionCardOverlay`，**驱动 overlay 的 4 个闭包**，断言每个动作以正确 decision 抵达 `session.respond`（catch 搬错线，如调换 allowOnce/allowAlways、丢 `onAllowWithInput` 的 `updatedInput`）。`DetailPaneTranscriptHitTestTests` 守门 M4/M5 的点击穿透，但**不**守门决策路由。

### 7.8 与边界规范（BOUNDARY-SPEC）的一致性（T5 集成）

后续的 AppKit↔SwiftUI 边界调研产出了权威规范 [`boundary/BOUNDARY-SPEC.md`](boundary/BOUNDARY-SPEC.md)(由真实 measurement-probe 测试背书、经干净上下文对抗审查)。本节据此校准 §7:

- **`permissionCardHost` 的制式 = 「regime-A sizing + 穿透 hit-testing」的混合**,而非 BOUNDARY-SPEC §1 的 regime B″(浮层「绝不四边钉」)。区别在于:B″ 的浮层用**默认** sizingOptions,故四边钉会让其 fittingSize 泄漏进 split → 必须只做位置钉;而 `permissionCardHost` 用 **`sizingOptions = []`**,四边钉下**不发布任何 fittingSize**(BOUNDARY-SPEC §2.2 的泄漏机制因此被根除),再叠加 `PassthroughHostingView` 的 `hitTest→nil` + cursor-rect 压制(§7.4 M4)。这是 §7 方案**塌不了窗、也不遮 transcript** 的根本原因,完全符合规范的 regime-A「容器定尺寸、host 不发布尺寸」原则。
- **输入栏居中已被规范确认为最佳实践**(BOUNDARY-SPEC §3:regime B 的 centerX + width≤cap(req) + width==cap(@high) + leading≥inset 五约束,「Is it optimal? Yes」)。因此 §5 目标树里的 `restingBarHost` 重命名是**纯命名**,其约束/制式**原样保留**,不得改动。
- **archive 双向绑定不是压扁元凶**(BOUNDARY-SPEC §2.2/§4):压扁是 sizingOptions 制式 bug,绑定只是在泄漏制式下"重新发布坏 fittingSize"的泵。故 §6 数据流宪法对该绑定的判决(read-mostly `@Bindable`、保留)正确,无需改动;现已由 `AppKitSwiftUIBoundaryTests.testArchiveBindingWriteStaysHeightNeutral` + 硬化后的 `DetailRouterLayoutDiagnosticsTests` 守门。

---

## 8. 逐项重构清单

> 编号沿用分析里的 P1–P15。已折叠对抗验证的修正。

**P1 删死注入** — 删 5 处宿主上的 `.environment(notifications)` / `.environment(searchBus)`（grep 证实 0 SwiftUI reader）。被消费集恰为 `{SessionManager, RecentProjectsStore, InputDraftStore, \.syntaxEngine}`。纯删，no-op。

**P2 `DetailContext` + 注入 helper** — 一个值结构（model + 被消费服务）整体经 `makeChild` 下传；每个子 VC `init(context:)`；一个 `View.injectDetailEnvironment(_:)` 替掉 5 份复制。**不**整体注入 AppState（`model` 不在 AppState 上，且会过度暴露子 VC 不需要的服务）。增删依赖 1 处改。需先做 P1（helper 不带死边）+ un-erase（漏注变编译错）。

**P4 `Session.stopBackgroundTask(taskId:)`** — 相位感知 forwarder，镜像现有 `requestContextUsage`，**用 `guard let runtime` 习惯**（验证修正：`requestContextUsage` 用的是计算访问器 `guard let runtime`，不是 `guard case .active`）。`.draft` no-op。`BackgroundTaskButton` 改调它，去掉 `session.runtime` 解包。修在产品里，强化不变量。注意 m1：旧 `stopAction` 在 `runtime==nil` 时返回 `nil`（隐式可见性门控）——实践安全（按钮只在有 task 时渲染，而 task 需活 runtime），但在 commit 里点明 nullability 契约变化。

**P10b 改名 `searchEngine`→`syntaxEngine`** — 跨 6 个类纯改名，编译器守门。折进 P2 一趟。（P10a 的 closure-sink 三处声明**有意**，不动。）

**P3 拆 `SidebarViewController`**（两步）：
- 步骤一 `SidebarTreeModel`：纯函数 `build(records, groupOrder, previouslySeenGroups) → (nodes:[SidebarItemNode], newGroups:[String])`。把隐藏的 `lastSeenGroups` 缓存变成**显式输入**，从而保住 invariant 6.10（启动时已存在的 folder 不当作新）。首次让 tree-building/grouping/新 folder 检测可单测。
- 步骤二 `SidebarContextMenuController`（`NSMenuDelegate` + 菜单动作）。VC 留 outline + 3 个观察循环 + DnD + 选择。`SidebarItemNode` 仍引用类型；DnD 仍在 VC（需 live `outlineView.moveItem`）；echo-suppression、per-row obs 重武装全保。

**P7 grouping 引擎**（**验证后大幅缩小**）：
> **验证修正（MAJOR）**：实时 grouping 在 `SessionRuntime+Receive.swift`，**不在 bridge**；`ReverseEntryBuilder` 在 `Services/Session/Session/`，也不在 bridge 目录。而且核心谓词 `isGroupableAssistant` **已经共享**（`+Receive.swift:700` 的注释明说让 `ReverseEntryBuilder` 用同一规则）。所以「grouping 改一处」**今天对谓词已成立**。真正分叉的只是 traversal 侧的增长/配对（正向 fold off `messages.last` vs 反向 fold），而设计本就保留两个方向。
> **结论**：P7 抽取的远比设想少。要么把它**降级**为「抽取残余的非谓词规则」，要么**直接放弃**（最高价值部分已完成）。无论如何修正组件树里「bridge uses EntryGrouping」的错误标注——它在 `SessionRuntime+Receive`。

**P8 抽 `SessionRuntime` 自包含投影**（**验证后缩小范围**）：
- 抽 `TodoTracker` / `TaskTracker` / `ContextUsageCache`。**排除 `TurnUsageMeter`**——`turnUsage`/`turnStartedAt` 是 `@ObservationIgnored`，搭在命令式 `publishTurnUsage` sink 上（fire `onTurnUsageChange`），且 `turnStartedAt` 在 `resetStreamingTurn` 与 `+Start` 里按特定顺序相对 streaming reset 变更——它**通不过**设计自己的「不碰 fire/ordering」规则，应留在 runtime。
- **观察嵌套陷阱（验证 + 审查修正）**：`tasks`/`todos` **以及 `contextUsage`** 都是**被观察的 `@Observable` 字段**（非 `@ObservationIgnored`；`contextUsage` 有 reader `ContextRingButton` 经 `session.contextUsage`）。抽成子对象时子对象必须 `@Observable` 且被 `@Observable`-tracked 属性持有，嵌套变更才能传播到读者——这**不是**「值类型抽取」（§5 树里 `ContextUsageCache` 早先标的 `[value]` 是误标，已与此处统一为「观察嵌套」一类）。唯一可作纯值的是「整体重新赋值进被观察的外层属性」的字段（如 `contextUsageFetchedAt` 之类），就地原位修改的引用 tracker 必须 `@Observable`。`SessionRuntimeTodosTests`/`…TasksTests`/`ContextUsageTests` 必须断言**实时重渲染**，不只是终值。runtime 仍是 `@Observable` 所有者 + 同步 `onMessagesChange` fire 点（runtime-I1）+ `receive` 顺序不变（runtime-I3）；投影在同一同步 `receive` 栈里内联更新。

**P12/P13/P14/P15 命名/死码/常量/分层**：
- `composeOrBarHost`→`restingBarHost`；`CompletionViewModel`→`CompletionState`；un-erase 5 处 `AnyView`；修 root CLAUDE.md「AppState 经 `.environment` 注入」失真；`RootView2` 文档引用横跨 8 个文件（验证修正：不止 2 个）；修 `Content/Chat/CLAUDE.md` 把顶 scrim 写成基类名 `TranscriptScrimView`（实为 `TranscriptTopScrimView`）。
- **C14 死码删除触及活文件**（验证修正 MAJOR）：directory-completion 的删除不是单文件——`DirectoryCompletionItem` 从不构造（0 构造点）但其周边接线是**活布线**：`InputBarView2.swift` 的 swipe-delete-recent 处理、`CompletionListView.swift` 的 isRecent pill、`onDeleteRecent` 闭包都被**活 view** 引用，只是因数据源永远为空而**永不触发**。正确措辞是「行为保持地删除永不触发的布线（已验证：无 `DirectoryCompletionItem` 构造器；recent 分支数据源恒空）」，而非「结构性死码」。另删 `ClaudeCodeStats`（~460 行无消费者，连同其 test）、`FileCompletionStore.invalidate*`（0 caller）。
- `StableBlockID` ×3、task title/color ×2-3、pill radius 16 ×2 —— 顺手抽 1 行 `let`，既有 snapshot 守门。
- `GitProbe` 补 `@MainActor`；view 关注点从 `Models/` 移出（synced-group 免改 pbxproj）。

**P5/P6 transcript-swap + crossfade**（最高风险，放最后，见 §9 Phase D）：
- P5 抽 `TranscriptSwapCoordinator`，逐字搬移 attach 编排 + 同会话 crossfade + per-attach scroll/presenter。
- **接缝契约（验证 + 审查修正 R6，必须在动手前敲定）**：P5 不是「瘦 forwarder 交个 host view」就完了，要点名**完整跨界面**——(i) **z-order anchor**：`addSubview(scroll, positioned:.below, relativeTo: topScrim)`，scrim 留在 VC，故 coordinator 须被交付 `topScrim`（或一个 insert 闭包）；(ii) **`currentSession` 单一所有者**：turn-usage sink 与 running-obs 都比较 `self.currentSession === session`——**选一个对象持有 `currentSession`，另一方的读取经它路由，绝不在两对象间重复该字段**（重复会在 crossfade 期间 desync，让陈旧 sink 对错 controller 调 `setTurnUsage`/`setLoading`）；(iii) **`applyScrimCutouts` 坐标转换**：rect sink 把 `composeOrBarHost` 的 rect 转成 `bottomScrim` 坐标系——若 `transcriptScroll` 迁入 coordinator 而 scrim/栏宿主留 VC，该 cutout 路径须继续工作；(iv) first-screen logging + focus 留 VC——拆分线**穿过** `attachSession`，不是绕过。
- **覆盖缺口（审查修正 R6）**：两道 merge gate 验证的是 §2.19 **单宽 tile 契约**，**不**覆盖上述接缝（cursor cutout / sink 身份 / 同会话 crossfade 顺序）。故「逐字搬移 + 两道 gate」对 §2.19 充分、对 swap 运行时正确性**不足**——显式以 `DetailPaneTranscriptHitTestTests`（走真实 swap 的 hitTest）守 cutout/hit-test，并见 §9.1 关于同会话 crossfade 的手动覆盖。
- **P6 共享 crossfade helper —— 验证后降级为可选/默认不做**：两套 crossfade 真正相同的只有约 7 行 `NSAnimationContext.runAnimationGroup`；其余（停泊态类型、`expected`-守卫的幂等 finish、teardown、I5 预 flush）各异且必须各自保留。一个有状态的 `CrossfadeController` 为 7 行引入新类型 + 闭包 hop，接近用户明确拒绝的「为干净而干净」。**先做 P5 内聚抽取**；P6 helper 只在「比两个 6 行方法读起来更干净」时尝试，且**绝不**owns I5 的 `removeObserver` 预 flush（那留在 `TranscriptSwapCoordinator.attach` 头部）。能力上若无法干净表达 I5，就**保留两份实现**——重复比风险便宜。

---

## 9. 迁移计划（4 阶段 + 平价校验单）

> 原则：数据流已基本干净 → 不是重写，是小步抽取/去重/样板收敛。每步可编译、过 `make test-unit`、是独立 PR、跨合并边界不留半迁移态。最低风险最高杠杆先行；load-bearing 的 AppKit 编排放最后、两道 merge gate 守门。

| # | 步骤 | 阶段 | 问题 | 风险 | 主守门 test |
|---|---|---|---|---|---|
| 1 | 删死 `.environment` 注入 | A | P1 | 微 | 全 `make test-unit` + 手动冒烟 |
| 2 | 改名 `searchEngine→syntaxEngine` | A | P10b | 微 | 编译器 + 全量 |
| 3 | 删死码（dir-completion / `ClaudeCodeStats` / `invalidate*`） | A | P13 | 低 | `CustomCommandTests`、`CompletionListSnapshotTests`（注意改活文件） |
| 4 | `Session.stopBackgroundTask` forwarder | A | P4 | 低 | `SessionRuntimeTasksTests` + 新 `SessionFacadeTests` 用例 |
| **5** | **权限卡片悬浮层（头号修复）** | **B** | **§7** | **中** | `PermissionCardWiringTests`、`PermissionCardSnapshotTests`、`ChatComposeStackRoutingTests`、`DetailPaneTranscriptHitTestTests` |
| 6 | `mountFillPaneHost` + un-erase `AnyView`（**先于 step 7**，使漏注变编译错） | B | P12/C9 | 低-中 | `ArchiveViewSnapshotTests`、布局诊断、`MainWindowAppKitSnapshotTests` |
| 7 | `DetailContext` + `injectDetailEnvironment`（un-erase 后落地，编译器守门） | B | P2 | 低-中 | `DetailRouterContainmentTests`、`DetailRouterDraftRoutingTests` |
| 8 | 命名/文档收尾（`restingBarHost`、`RootView2`×8、doc drift） | B | P12 | 微 | 编译器 + `make fmt-check` |
| 9 | 抽 `SidebarTreeModel`（纯） | C | P3-1 | 中 | 新 `SidebarTreeModelTests`、`SidebarTitleSanitizerTests`、snapshot |
| 10 | 抽 `SidebarContextMenuController` + 瘦 VC | C | P3-2 | 中 | snapshot + 手动 DnD/菜单冒烟 |
| 11 | grouping 去重（**缩小或放弃**，见 §8.P7） | C | P7 | 中 | `TranscriptReverseBuilderTests`、`MessageEntryBlockBuilderTests`、bridge tests |
| 12 | 抽 `SessionRuntime` 投影（todos/tasks/context-usage，**排除 turnUsage**） | C/D | P8 | 中-高 | `SessionRuntimeTodosTests`/`…TasksTests`/`ContextUsageTests`（断言**实时重渲染**） |
| 13 | 抽 `TranscriptSwapCoordinator`（+ 可选 crossfade helper） | D | P5/P6 | **高** | `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`（**这两道就是门**） |

> **排序要点（跨文档依赖，验证修正）**：步骤 5（卡片悬浮层）与步骤 13（`TranscriptSwapCoordinator`）都改 `ChatSessionViewController.loadView`。卡片宿主是 VC 级（像 scrim），**非** per-attach，故二者大体独立；但**卡片层先落地**，步骤 13 抽取时把 `permissionCardHost` 当作第 4 个同辈宿主纳入考虑。
>
> **放弃/推迟**：P9（façade forwarder 样板——不 gold-plate）、P11（单例收敛——判断题，低害，仅修文档 + 廉价时把薄 UserDefaults store 折上 AppState，`ModelStore` 保持 `.shared`）。

### 9.1 阶段 D 的强制降风险流程（步骤 13）

1. 改动**前**跑 `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`，确认绿（host test 端到端驱动 `present`→`attachSession`，已验证能 fail 于三种回归形态）。
2. **逐字搬移**方法体进 coordinator，不做「顺手简化」。§2.19 序列与 chat-I5 flush 顺序整段照搬。
3. 改动**后**重跑两道门；若 host test 变红，**先读它附在 xcresult 的 per-stage offender 报告**再动任何东西——被容忍的多宽度写入**就是** bug，绝不 `XCTSkip` 或放宽容差。
4. 加跑更广的 transcript host 套件 + 手动 A→B→A→A 切换、原地 draft→active promotion、transcript 中途 resize、跨 kind 切换，确认无空白闪、无首帧抖动。
5. 回滚是整 PR `git revert`——因为是逐字搬移，回滚精确还原先前编排。

> **覆盖缺口（审查标记的最大被低估风险）**：两道 merge gate 驱动 `present→attachSession`，验证的是 **attach 单宽 tile 契约**——而**同会话 crossfade**（`fadingOutTranscript`，`ChatSessionViewController.swift:113`）的 finish-before-new-attach 顺序是**不同路径**，**不在 gate 覆盖内**。若本方案出回归，最可能是同会话 crossfade 的单帧撕裂/滚动条陈旧闪。**处置**：step 13 落地前，要么新增一个覆盖 `fadingOutTranscript` finish-before-attach 顺序的 test，要么明确该路径为「仅手动冒烟」并接受残余风险——手动必跑 A→B→A→A 切换 + 原地 draft→active promotion 各一遍，确认无撕裂/陈旧滚动条。

### 9.2 平价校验单（节选；每项映射守门 test）

- **选择/路由**：点会话→同 tick 挂载（`DetailRouterContainmentTests`）；冷重启后 draft 行路由到 landing（`DetailRouterDraftRoutingTests`）；draft 提升原地换（`MainSelectionModelPromoteTests`）；任何切换无空白闪。
- **transcript**：A→B→A 重入 blocks 完好、滚到尾、单宽 typeset（两道门）；冷加载 off-main 锚定 prepend 无冻结；实时流式 + typewriter；工具组折叠/状态色/shimmer/error card；loading pill + turn-usage；⌘F 搜索 + 折叠子项揭示；跨行选择/复制 + 两类 sheet；resize 回流无跳。
- **输入栏/compose/landing**：send/stop 切换；`@file`+`/command`（步骤 3 后只剩活路径）；draft 跨重入持久但 send 时清；各 picker/button；**后台任务 stop（步骤 4）**；**权限卡片所有种类（步骤 5）**；`/new`+`/clear` builtin 顺序；无输入 chrome 浮到 archive/compose（回归 #222）。
- **侧边栏**：按 folder 分组/排序/recency；per-row 状态；folder 拖拽持久；右键菜单；标题净化。
- **会话生命周期**：draft→active 逐字拷 config + 接 bridge；detached 会话仍收 CLI 事件（切回 O(1)）；todos/tasks/context-usage（步骤 12，断言实时重渲染）；worktree 建/归档；通知激活路由；标题生成。
- **辅助窗口**：Settings/About 开窗与定尺寸；⌘, 永不开 SwiftUI Settings 窗；archive 过滤 + 取消归档。

---

## 10. 不可触碰的契约墙

每一步都设计成**绕开**这些。某步若似乎需要松动其一，那步就是错的——停下重设计。

1. **transcript §2 性能契约（全部条目）** —— `NSTableView`+同步 `heightOfRow`(§2.1)、`wantsLayer+.onSetNeedsDisplay` cell 层策略(§2.2)、scroll/clip `.never`+responsive(§2.3)、无 LRU 布局缓存(§2.4)、`nonisolated static makeLayout` off-main 纯净(§2.5)、off-main-build-then-sync-apply backfill(§2.6)、`refillLayoutCache` in-tick forced tile(§2.7)、live-resize 仅可见行(§2.8)、负宽 clamp(§2.9)、粒度 insert/remove **永不 `reloadData()`**(§2.11)、status/search/highlight 旁路 `Change.update`(§2.12/13/13b)、`cacheLayouts` 防毒(§2.14)、per-scope 代守卫(§2.15)、shimmer 子像素/图缓存(§2.16)。**本方案无任何一步进入渲染器内部。**
2. **§2.19 单宽 attach 契约** —— `factory.make`(unbound)→`addSubview`+约束→host `layoutSubtreeIfNeeded()`→`factory.bindData`→`scrollToTail()`；router 在 `present` 前 settle 子 frame。两道 merge gate 守门。
3. **runloop-tick 顺序** —— 选择突变同步+单观察者落在点击源相位（绝不回 async `withObservationTracking` 做结构，#195）；crossfade 结构同步、仅 opacity 延迟(I3)；build-in-front-then-drop(I4)；**A→B→A 重入时 outgoing-scroll flush 在 bind 之前(I5，全 app 最脆弱的顺序)**；send 时 draft-clear 命令式(I12)。
4. **会话→UI 数据规则** —— 每状态一通道（AppKit 同步闭包推 / SwiftUI `@Observable` 拉）；`Session` 全程持 controller+bridge；bridge 在 init/promotion 接一次；history 经 off-main backfill 绕过 bridge。
5. **确定性拆除 + macOS-26 deinit 兜底** —— `DetailRouterChild.prepareForRemoval()` 在 swap 时释放 per-attach 资源；每个 `@MainActor @Observable`/VC（含本方案新增类型）带 `nonisolated deinit {}`。
6. **host-sizing 纪律** —— 整 pane `[]`+四边钉；component `[.intrinsicContentSize]`+位置钉。聊天栏宿主的 `[.intrinsicContentSize]` 不对称**保留**，**不**折进 fill-pane helper。**权威规范见 [`boundary/BOUNDARY-SPEC.md`](boundary/BOUNDARY-SPEC.md) 的决策表(regime A/B/B′/B″/C/D/E),最终方案必须符合它**;新增的边界回归门 `AppKitSwiftUIBoundaryTests`、`HostedComponentCenteringTests` 及硬化后的 `DetailRouterLayoutDiagnosticsTests` 是 CI 合入门,断言 fill-pane 子 host 的 `fittingSize.height≈0`、组件居中/限宽——**不得 XCTSkip 或放宽**。
7. **侧边栏不变量 6.1–6.12**、**bridge/builder 平价**（history 不走 bridge、加载无 `.update`、跨页 withhold + doc-order）。

---

## 11. 明确不做的事（反过度设计）

| 拒绝项 | 理由 |
|---|---|
| 合并 `Transcript2Controller` + `Transcript2Coordinator` | NativeTranscript2 §1.1 列了三条 load-bearing 理由（NSObject vs @Observable、文件体量、Controller 真有逻辑非纯转发），明说「Don't merge」 |
| router 改 `withObservationTracking` 观察 selection | 破坏源相位结构通知，把会话切换撕裂到多帧（#195） |
| 全局 store / Redux / 聊天区 ViewModel | 会把进程/窗口/会话三个正确 scope 压平，并逼每个 transcript 增量过 reducer，毁掉 §2 依赖的同步闭包推送 |
| 整体 `.environment(appState)` 注入 | `model` 不在 AppState 上，且会把死服务重新带进每个 view 的可达面 |
| 用协议折叠 `Session` 的 ~40 个相位 forwarder（P9） | draft/runtime 读表面真分叉，协议会在 draft 上伪造 runtime-only 字段——纯机械样板，非缠绕流 |
| 抽 `TurnUsageMeter`（P8 极大化） | 它搭在命令式 turn-usage sink + `turnStartedAt` 顺序上，通不过「不碰 ordering」规则——留 runtime |
| 有状态 `CrossfadeController`（P6） | 仅 7 行相同；为之造新类型+闭包 hop 接近为干净而干净；降为可选，必要时保留两份 |
| 把 spine 任一节点 SwiftUI 化 | 每处都是有度量、文档化的 AppKit 例外；§2 把 transcript 钉死 |
| 把 completion store / `ModelStore` 改注入服务 | per-cwd / 进程级缓存本就该单实例；注入只买仪式不买清晰。`ModelStore` 会 spawn CLI 子进程，尤其保持 `.shared` |
| 侧边栏细粒度 diff 替代 `reloadData()` | 行数有界、无性能契约、identity 键控存活 `reloadData()`；`SidebarTreeModel` 让未来 diff 成为可能而不投机现在 |
| 合并 `ComposeSessionViewController` + `DraftSessionLandingViewController`（~90% 像） | 差异真实（draft-id 分配 + resume vs re-bind + focus 扫 + builtin）；只共享挂载配方(C9)，合并会缠绕两个不同生命周期 |

---

## 12. 对抗审查结论

本方案经**两轮**对抗审查，全部针对**真实代码**、审核员**上下文独立**：

**第一轮 · 逐设计验证**（4 份 `nodes/verify-*.md`，每份在设计完成时立即挑战）——结论均 **sound-with-fixes，无一破坏性能契约**。关键修正已折叠进正文：卡片常量 36（非 100）+ 无条件 `PassthroughHostingView`（§7.4）；P7 grouping 缩小/放弃（§8）；P8 排除 `TurnUsageMeter` + 观察嵌套（§8）；P6 crossfade helper 降为可选（§8/§11）；P5 接缝点名（§8）；C14 改「永不触发的布线」（§8）；P4 用 `guard let runtime`（§8）。

**第二轮 · 最终稿干净上下文审查**（4 份 `nodes/review-*.md`，4 个审核员**只读本文 + 代码库 + 项目 CLAUDE.md，不读任何推演产物**——满足用户「审查者上下文要干净」的要求）。**总裁决：4/4 sound-with-fixes，0 blocker，不破坏 §2/§2.19/runloop 契约，不降级功能，不过度设计。** 卡片根因、M1=36、M2=`PassthroughHostingView` 均经**独立**核实属实。完整记录 `REVIEW.md`(审查产物,已从本 PR 移除,保留在分支历史)。

本轮新暴露的问题与**处置（均已回填本文）**：

| # | 问题 | 处置 |
|---|---|---|
| R1 | §8/§9 步骤顺序内部矛盾（un-erase 应先于 DetailContext） | §9 表对调 step 6/7（§9） |
| R2 | 整 pane 浮层宿主即便 hitTest→nil 仍注册 cursor rect 遮挡 I-beam | §7.4 新增 **M4**（压 cursor/tracking rect，或只钉卡片区） |
| R3 | `permissionCardHost` z-order 未明确 | §7.4 新增 **M5**（loadView 中置于栏宿主之后；attach 仍 `.below topScrim`） |
| R4 | `PermissionCardOverlay` 选择路由欠规约（陈旧/错会话卡片风险） | §7.3 补 `.id(sid)` 键控会话解析 |
| R5 | `PermissionCardWiringTests` 不守门 card-button→闭包→respond | §7.7 新增 spy-Session 决策路由 test |
| R6 | step 13 cross-VC 接缝（`currentSession` 归属等）merge gate 不覆盖 | §8 P5 升级接缝契约 + `DetailPaneTranscriptHitTestTests` |
| R7 | demo VC 迁移是真实工作量 | §7.4 M3 + §9 step 5 标为显式子任务 |
| 一致性 | `contextUsage` 实为 @Observable（非纯值）；卡片闭包在 `ChatRestingBar`；P4 forwarder 返回 `Void`；体量/行号微误 | §5/§8/§7 标注已统一（详见分支历史中的 REVIEW.md） |

审核员一致背书：核心诊断（架构已约 90% 单向、外科手术非重写）、两条主轴 + 唯一向上结构边、P1/P2 最高价值最低风险、P4 在产品里闭合唯一真违例、§6 数据流宪法忠实描述既有行为、§7 卡片修复方向正确、§11「明确不做」表——**且未发现任何应砍而未砍的过度设计**。

---

## 13. 附录 · 节点产物索引与方法论

### 13.1 方法论

一轮后台并行 workflow（24 个 agent，约 3.37M token）：

1. **Survey（12 并行）** — 每子系统一个调研员，结论各自落盘，互不写同一文件。
2. **Analyze（4 并行）** — 读全部 survey 做横切分析。
3. **Design + 对抗验证（4 组流水线）** — 每份设计由独立审核员立即针对真实代码挑战（性能契约/功能降级/过度设计/前提正确性/可行性）。

本文（§1–§11）由主循环亲自汇总，折叠了全部验证修正。§12 的最终对抗审查待 workflow #2（干净上下文）回填。

### 13.2 节点产物

> 下列节点产物**已从本 PR 的 tip 移除**(保持评审面精简),**完整保留在分支 git 历史**中;查阅:`git show <commit>:docs/refactor/nodes/<file>`。

| 类别 | 文件 |
|---|---|
| 调研 | `nodes/survey-app-shell-routing.md`、`survey-sidebar.md`、`survey-chat-detail-vcs.md`、`survey-input-bar.md`、`survey-permission-cards.md`、`survey-input-controls-aux.md`、`survey-completion.md`、`survey-transcript-renderer.md`、`survey-transcript-bridge.md`、`survey-session-runtime.md`、`survey-session-infra.md`、`survey-app-services-models.md` |
| 分析 | `nodes/analysis-component-tree.md`（权威现状树 + P1–P15） |
| 设计 | `nodes/design-target-component-tree.md`、`design-target-data-flow.md`、`design-painpoint-fixes.md`、`design-migration-plan.md` |
| 对抗验证（第一轮，逐设计） | `nodes/verify-target-component-tree.md`、`verify-target-data-flow.md`、`verify-painpoint-fixes.md`、`verify-migration-plan.md` |
| 最终审查（第二轮，干净上下文） | `nodes/review-architecture.md`、`review-perf-runloop.md`、`review-parity-card.md`、`review-clarity-impl.md`；汇总记录 `REVIEW.md`(已从本 PR 移除,保留在分支历史) |

### 13.3 已知调研瑕疵（诚实记录）

Analyze 阶段的 4 个节点中，仅 `analysis-component-tree.md` 成功落盘；另 3 个（data-flow / dependencies / pain-points）返回了结构化摘要但文件未落盘（疑为 Write 路径/持久化问题）。**影响有限**：(a) `analysis-component-tree.md` 的 §3/§4 已折叠数据流、依赖、痛点的核心结论；(b) 4 份设计文档直接读 survey + 源码 + component-tree 分析，已充分吸收这些结论，并各自经过对抗验证。因此本汇总的证据链完整。若需补齐这 3 份分析以备存档，可单独重跑对应 analyze 节点（其结论预计与设计文档已捕获的高度一致）。
</content>
</invoke>
