# CCTerm 重构 · 最终交付（FINAL-PLAN）

> **这是什么。** 本文档是 CCTerm 组件树/数据流重构的**最终、可执行**交付物,合并了
> 三件东西并以 **总 → 分** 组织:
> 1. **绑定规范(spec)** — 组件树/数据流/host 制式/不可触碰契约的一致性规则集;
> 2. **完整组件归属表** — 全代码库**每一个类/模块一行**,使用固定列模式;
> 3. **多-PR 执行计划** — 13 个按风险梯度排序、各自独立可发布的 PR。
>
> 配套权威文档(本文档不复制其内容,只引用):
> - 重构动机与目标树:[`REFACTOR-PLAN.md`](REFACTOR-PLAN.md)(§5 目标树 / §6 数据流宪法 / §8 逐项 / §9 迁移 / §10 契约墙 / §11 不做)
> - AppKit↔SwiftUI 边界 host 制式:[`boundary/BOUNDARY-SPEC.md`](boundary/BOUNDARY-SPEC.md)(A/B/B′/B″/C/D/E 决策表 + 回归门)
> - 现状组件树 + P1–P15 问题排名:[`nodes/analysis-component-tree.md`](nodes/analysis-component-tree.md)

---

## 1. 执行摘要

**目标。** 最终架构的"干净"判据是:**每一个模块/类都能被清晰地放进一张表的一行**。如果
某个类无法干净落位(所有者不明、数据进/出通道不清、host 制式错误/未知、跨两层),那就是
**设计缺陷**,以 `✗ + 一句话问题` 标注 —— 因为无法落位意味着设计错了,而不是表错了。

**本交付保证:**

- **每个类都已制表且符合规范。** 全部生产类落位于唯一一层、唯一所有者、唯一数据进通道、
  唯一数据出通道、正确 host 制式(或"—")。完整表见 §3。
- **可分发 PR。** 13 个 PR(PR1–PR13)按风险梯度排序(机械/死代码/改名 → 头号卡片悬浮层
  → 边界卫生 + DI 合并 → god-object 拆分 → 最高危的 transcript-swap 抽取垫底),**每个 PR
  独立编译、`make test-unit` 通过、应用保持绿色、可单独 `git revert`**。见 §4。
- **每行的非符合(✗)状态都被某个 PR 翻转为 ✓。** as-is 的 ✗ 行(`BackgroundTaskButton`
  穿透façade、`ChatRestingBar` 尺寸泵、`SidebarViewController` god-VC、`SyntaxHighlightEngine`
  误名、死注入、死代码、`Models/` 分层 nit)各自映射到一个修复 PR。

**诚实声明 · 剩余 ✗ 项。** 经对抗审查(§5)修订后,**生产树中不存在停留在 ✗ 的可放置类**:

- **`CrossfadeController`** —— 唯一的 ✗ 是一个**声明性设计缺陷**:它**不被引入**(无对应行)。
  两个现存 crossfade 状态机各自干净落位;对二者的*抽象*才是缺陷,方案明确拒绝该抽象
  (REFACTOR-PLAN §8 P6 / §11)。"声明不建造"不等于"留在树里的 ✗ 类"。
- **5 个 `.shared` store**(`ModelStore` / `SlashCommandStore` / `FileCompletionStore` /
  `EffortDefaultStore` / `NewSessionDefaultsStore`)—— 依审查 D1 已统一计为
  **✓ + 带理由的 `.shared` 例外**(与 inputbar 片段对其*消费者*的计分一致):它们是按设计
  保留的、单一所有者的进程级缓存/CLI 子进程宿主(spec §5 DNT-8 批准)。"刻意保留 + 文档化
  例外"是 ✓,不是 ✗。其中两个 UserDefaults 包装器仍**可选**折叠进 `AppState`(PR8,低风险)。
- **DEBUG 演示类**(4 个 VC + 2 个 `@Observable` helper)—— 依审查 C1/C2 已补行(§3.8);
  全部 ✓。

---

## 2. 组件树/数据流 规范(一致性规则集)

> 这是其余部分所遵循的**规范**。来源:REFACTOR-PLAN §3/§4(所有权/分层)、§6(7 条数据流
> 宪法)、§7(权限卡片悬浮层)、§10(契约墙)、§11(不做)、BOUNDARY-SPEC(host 制式)。
> 凡本规范与某源 `CLAUDE.md` 冲突,以源 `CLAUDE.md` 为准、本规范为缺陷。

### 2.0 归属表模式(一致性目标)

每个组件 MUST 恰好表达为一行:

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |

封闭词表(各列只能取这些值):

- **Layer** ∈ {App-lifecycle, App-scope-state, App-scope-service, Window-shell,
  DI-context, Detail-child-VC, Per-attach, AppKit-coordinator, Session-core,
  Per-load, Pure-value, SwiftUI-view, View-scope-state, Renderer-internal}。
- **Kind** ∈ {AK-VC, AK-View, AK-NSObject, SU-View, @Observable-SVC, actor-SVC,
  value/MDL, translator}。
- **Reads state via** ∈ {@Observable pull, closure sink, ctor-injected, n/a}。
- **Emits via** ∈ {Session method, injected closure, model.select, imperative
  controller call, @Observable write, none}。
- **Host regime** ∈ {A, B, B′, B″, C, D, E}(BOUNDARY-SPEC)或 "—"(非 host 边界)。
- **Target Δ (PR#)** = §4 多-PR 计划中的 PR 编号,或 "unchanged"。
  > (修订 S1:PR 编号的权威表在 §4 / [`nodes/pr-plan.md`](final/nodes/pr-plan.md);spec 早期版本误写"§7 below",此处已校正。)
- **Conformant** = ✓,或 ✗ + 一句话问题。

### 2.1 分层模型(允许的层 + 依赖方向)

**严格向下。** 组件只能持有/依赖同层或**任一更低层**的组件。**唯一允许的向上边**是
`selectionObserver`(规则 D-4)。其他任何向上指针都是缺陷。

层,自上(最长寿/最外)而下:

| Layer | 这里住的东西 | 可向下依赖 |
|---|---|---|
| **App-lifecycle** | `AppDelegate` | 以下全部 |
| **App-scope-state** | `AppState`、`searchBus`、`selectionModel` | App-scope-service、Session-core、Pure-value |
| **App-scope-service** | AppState 各服务 + `.shared` 单例 | App-scope-service(同层)、Session-core、Pure-value |
| **Window-shell** | `MainWindowController`、`MainSplitViewController`、`SidebarViewController`、`DetailRouterViewController`、toolbar 桥 | DI-context、Detail-child-VC、App-scope-*(ctor 注入)、Session-core |
| **DI-context** | `DetailContext`、`SidebarContext`(model + 被消费服务的值袋) | App-scope-service、App-scope-state(携带,不拥有) |
| **Detail-child-VC** | `ChatSessionViewController`、`ComposeSessionViewController`、`DraftSessionLandingViewController`、`ArchiveViewController`、demo VC | AppKit-coordinator、Per-attach、SwiftUI-view(host)、Session-core(经 context)、DI-context |
| **Per-attach** | `transcriptScroll`、`transcriptSheetPresenter`、running-obs task | Session-core、Renderer-internal |
| **AppKit-coordinator** | `TranscriptSwapCoordinator`、`SidebarContextMenuController`、`SidebarTreeModel`(纯)、`Transcript2Coordinator`、toolbar 桥 | Session-core、Per-attach、Pure-value、Renderer-internal |
| **Session-core** | `Session`、`SessionRuntime`(+ 抽取的 trackers)、`Transcript2Controller`、`Transcript2EntryBridge` | Session-core(组合子对象)、Pure-value、Renderer-internal |
| **Per-load** | `TranscriptBackfillPipeline` | Session-core、Renderer-internal、Pure-value |
| **SwiftUI-view** | 每个 `[SU]` view | 向下读 `@Observable`;只经闭包/Session 方法向上发 |
| **View-scope-state** | `CompletionState`、`GitProbe`、`BackgroundTaskOutputStream` | Pure-value、Session-core(经 `@Observable` 读) |
| **Pure-value** | `MarkdownDocument`、`StableBlockID`、`SedEditParser`、`SidebarItemNode`、枚举/主题 | 无(纯) |
| **Renderer-internal** | `Transcript2TableView`、`BlockCellView`、layout/diff 内部 | 仅 Pure-value;封闭(§2.5) |

**一致性检查 L1。** 若某组件声明的 Layer 触及不到它实际**向下**引用的全部组件,即缺陷
(向上/横向泄漏)。唯一豁免是 `selectionObserver`。

### 2.2 构造与所有权规则

- **C-1 单一所有者。** 每对象恰有一个所有者控制其生命周期("Owner / lifetime"格)。不共有。
- **C-2 服务只由 `AppState`/`AppDelegate`(进程域)或其文档化所有者构造**
  (`SessionManager.makeSession` 构 Session-core;`DetailRouterViewController.makeChild`
  构 Detail-child-VC;`…attachSession` 构 Per-attach)。**View 永不构造服务。**
- **C-3 唯一窄例外:view 私有交互状态机** 经 SwiftUI `@State` 创建:`CompletionState`
  (`CompletionViewModel` 改名)、`GitProbe`、`BackgroundTaskOutputStream`。它们**不是**
  session/transcript 状态的协调 ViewModel —— 该角色被禁止(§11 / D-镜像禁令)。
- **C-4 生命周期类**:process / window / detail-child(同时只活一个,同类复用)/ per-attach /
  session(跨挂载/卸载存活)/ per-load / view-identity。
- **C-5 依赖以单一值袋穿线,不按类型逐个声明。** App-scope 依赖以单个 `DetailContext`
  经 `makeChild` 抵达 Detail-child-VC;sidebar 以单个 `SidebarContext`。增删一个 app-scope
  依赖是一处编辑(= 规则 D-7)。
- **C-6 确定性拆除。** 每个 Detail-child-VC 实现 `DetailRouterChild.prepareForRemoval()`,
  在 swap 时释放 per-attach 资源。每个 `@MainActor @Observable`/VC 类型(含任何新
  coordinator/tracker)带 `nonisolated deinit {}`(macOS-26 abort 绕过)。缺者即缺陷。

### 2.3 数据流规则(7 条宪法,精简)

> 默认是响应式(`@Observable` 向下拉、方法/闭包向上)。命令式边是罕见例外,必须在调用点注释。

- **D-1 状态住在其全部读者共享的最低作用域。** process → `AppState`;窗口选择 →
  `MainSelectionModel`;单 session 业务+渲染 → `Session`;transcript 行模型 →
  `Transcript2Coordinator.blocks`;view 私有交互 → `@State`。单读者 ⇒ `@State`,绝不入模型字段。
- **D-2 数据向下经读 `@Observable` 流动,绝不缓存。** SwiftUI body 直接读 `session.X`/
  `model.X`。无 view 持模型字段的影子副本。
- **D-3 事件向上经渲染器选定的两条通道之一。** SwiftUI 消费者 → 调 `Session` 方法或注入闭包
  (`onSubmit`/`onAttachRect`/`onBuiltinCommand`);**绝不**碰 `session.runtime.X`。AppKit 消费者
  (transcript)→ `SessionRuntime` 上的同步闭包 sink,在 `Session.wireRuntimeMessagesSink` 多路
  复用一次,由 bridge 消费。**同一状态绝不走两条通道。**
- **D-4 唯一结构性向上边:`selectionObserver`。** 因 detail 侧切换必须落在点击的*同一 source
  phase*(`@Observable` 重算晚一 tick 到 `beforeWaiting`,会把 session 切换撕裂跨帧)。单所有者、
  weak;**不得**泛化为通知总线或第二观察者槽。新"结构性响应选择"需求走 router。
- **D-5 View 永不构造服务;ViewModel 例外是窄的**(= C-2 + C-3)。无 session/transcript 协调 VM。
- **D-6 命令式调用仅当正确性依赖 `@Observable` 无法表达的 runloop-tick 时序时允许。** 合法仅当
  以下之一成立,且**必须在调用点注释**:
  - **(a)** 必须跑在点击的 source phase、`beforeWaiting` 之前(选择通知、transcript attach、
    `present(sessionId:)`);
  - **(b)** 把**精确 delta** 交给 AppKit 消费者而非强制 diff(`bridge.apply`、`setLoading`、
    `setTurnUsage`);
  - **(c)** 必须跑在一个响应式 `.onChange` 拆除之上的栈帧(否则会吞掉它)(发送时清草稿)。
- **D-7 依赖以一袋被消费服务穿线,不按类型逐型重声明。**(= C-5。)DI 面是单一值类型,
  携带 model + 实际被消费的服务。

**逐边裁决(行据此被检查)。** 每行的"Emits via"/"Reads state via" 必须匹配此处的边裁决:

| Edge | 方向 | 通道 | 裁决 | 规则 |
|---|---|---|---|---|
| `select(_:)` → router | 结构向下 | sync delegate | keep(时序) | D-4, D-6a |
| `model.selection` → SwiftUI | 向下 | `@Observable` | keep | D-2 |
| sidebar → selection | 向上 | `model.select(_:)` | keep | D-3 |
| router → chat VC | 向下 | imperative `present(sessionId:)` | keep(时序) | D-6a |
| `session.*` → SwiftUI | 向下 | `@Observable` forwarder | keep | D-2 |
| bridge → transcript | 向下 | sync closure → `apply` | keep(精确 delta) | D-3, D-6b |
| `isRunning` → loading pill | 向下 | imperative `setLoading` + obs task | keep | D-3, D-6b |
| `turnUsage` → pill | 向下 | closure-sink `onTurnUsageChange` | keep | D-3, D-6b |
| chrome rects → scrim | 向上 | injected closure | keep(单读者,sync) | D-1, D-3, D-6b |
| send-time draft-clear | 副作用 | imperative `draftStore.clear` | keep(防拆除) | D-6c |
| card decision | 向上 | `session.respond(...)` | keep(范例) | D-3 |
| `pendingPermissions` → card | 向下 | `@Observable` forward | keep(范例) | D-2 |
| completion confirm → text | 向上 | State→View→NSTextView | keep(固有) | D-5 |
| `BackgroundTaskButton` → `runtime.x` | 向上 | **穿透façade** | **FIX → `Session.stopBackgroundTask`** | D-3 |
| 7-arg DI + 2 死注入 | 向下 | 按类型重声明 | **FIX → `DetailContext` + helper;删死** | D-7 |
| `searchEngine` 命名 | — | 误导 | **FIX → `syntaxEngine`** | clarity |
| `searchBus` 所有权 | ownership | 拆分 | 移到 `AppState`;`selectionModel` 留(窗口) | D-1 |

### 2.4 Host 制式规则(BOUNDARY-SPEC)

> 首要规则:**决定谁拥有尺寸。** `sizingOptions` + 约束模式随之机械确定。选错就压扁窗口。

每个 host 边界 MUST 声明恰一制式,其 `sizingOptions` + 约束 MUST 匹配:

| Regime | 何时 | `sizingOptions` | 约束 |
|---|---|---|---|
| **A** 填满 pane | host *就是* detail pane 内容 | `[]` | pin 四边 |
| **B** 居中组件 | 已填满 pane 的 transcript 之上的 bar | `[.intrinsicContentSize]` | centerX + width≤cap(req) + width==cap(@high) + leading≥inset + bottom== |
| **B′** Toolbar 槽 | `NSToolbar` item | `[.intrinsicContentSize]` | 无(toolbar 自测) |
| **B″** 浮层 | 角/底中;DEBUG demo | default(无害) | 仅定位 —— **绝不四边** |
| **C** 窗口内容 | `NSWindow.contentViewController` | default(刻意) | 窗口适配内容 |
| **D** 模态 sheet | `beginSheet` | default(刻意) | sheet 适配内容 |
| **E** 单元格叶 | AppKit row 内的 SwiftUI 叶 | `[.intrinsicContentSize]` | pin 到 cell inset;喂 `heightOfRow`(无生产实例) |

- **H-1 填满-pane host 绝不用 default `sizingOptions`。** default 把 body 的 `fittingSize`
  上推至 split → 窗口压扁。Regime A 永远是 `[]`。(archive 压扁的根因是*制式*,非绑定。)
- **H-2 chat 静息 bar 是 regime B 且保持非对称。** 其 `[.intrinsicContentSize]` + 五约束
  居中/cap 配方已确认最优;`composeOrBarHost → restingBarHost` 是**纯改名** —— 约束/制式不变。
- **H-3 跨边界双向 `Binding`/`@Bindable` 允许,绝非压扁元凶。** 两闭包用 `[weak self]`。
  Regime A `[]` 下高度中性。
- **H-4 权限卡片悬浮层是"regime-A 尺寸 + 穿透 hit-test"** —— **不是** B″。它用
  `sizingOptions = []` + 四边 pin(发布零 `fittingSize`),叠以 `PassthroughHostingView`
  (`hitTest → nil` 卡外 **且** 抑制 cursor/tracking rect),z-序在 bar host 之上但 transcript
  重插于 `.below topScrim`。这使它既不压窗也不遮挡 transcript。
- **H-5 在 pane host 处解除 `AnyView`。** 5 个 pane host 用具体泛型 body,使编译器强制
  environment 注入(漏注入即编译错)。填满-pane host 经 `mountFillPaneHost` helper 挂载。

**回归门(CI 合并门;不得 `XCTSkip` 或放宽):** `AppKitSwiftUIBoundaryTests`、
`HostedComponentCenteringTests`、加固的 `DetailRouterLayoutDiagnosticsTests`
(`fittingSize.height <= 1`)。

### 2.5 不可触碰契约(硬约束)

每个重构步都设计为**绕开**这些。若某步似乎需要放宽其一,则该步是错的 —— 停下重设计。

- **DNT-1 Transcript §2 性能契约(全部项)。** 同步 `heightOfRow`、`wantsLayer +
  .onSetNeedsDisplay`、scroll/clip `.never` + responsive、无 LRU layout cache、
  `nonisolated static makeLayout` 离主纯度、离主构建-同步应用 backfill、in-tick 强制 tile、
  live-resize 仅可见行、负宽 clamp、粒度 insert/remove(**绝不 `reloadData()`**)、
  status/search/highlight 经 `Change.update` 旁路、`cacheLayouts` 毒丸守卫、per-scope 代守卫、
  shimmer 子像素/图像缓存。**无步进入渲染器内部。**
- **DNT-2 §2.19 单宽 attach 契约。** `factory.make`(未绑)→ `addSubview` + 约束 →
  host `layoutSubtreeIfNeeded()` → `factory.bindData` → `scrollToTail()`;router 在 `present`
  前安顿 child frame。两个 reentry-layout 合并门守卫。
- **DNT-3 Runloop-tick 排序。** 选择突变同步 + 单观察者于点击 source phase(结构绝不用
  async `withObservationTracking`,#195);crossfade 结构同步,仅 opacity 延后(chat-I3);
  build-in-front-then-drop(chat-I4);**A→B→A reentry 时 outgoing-scroll flush 跑在 bind 之前
  (chat-I5 —— 全应用最脆弱排序)**;发送时清草稿命令式(chat-I12)。
- **DNT-4 Session→UI 数据规则。** 每状态一通道(AppKit sync-closure push / SwiftUI
  `@Observable` pull);`Session` 全生命持 controller+bridge;bridge 在 init/promotion 接线一次;
  history 经离主 backfill pipeline 旁路 bridge。
- **DNT-5 确定性拆除 + macOS-26 deinit 绕过**(= C-6)。
- **DNT-6 Host 尺寸纪律**(= §2.4):填满-pane `[]` + 四边;组件 `[.intrinsicContentSize]` +
  定位 pin;chat-bar 非对称保留,不折进填满-pane helper。BOUNDARY-SPEC 决策表权威,其门为合并门。
- **DNT-7 Sidebar 不变量 6.1–6.12** 与 **bridge/builder parity**(history 不走 bridge;load
  无 `.update`;跨页 withhold + 文档序解析)。
- **DNT-8 明确不做(反过度设计)。** 不要:合并 `Transcript2Controller` + `Transcript2Coordinator`;
  让 router 经 `withObservationTracking` 观察选择;引入全局 store / Redux / chat-area ViewModel;
  整体注入 `AppState`;把 `Session` ~40 个 phase 转发器藏到协议后(P9);抽 `TurnUsageMeter`(P8 上限);
  造有状态 `CrossfadeController`(P6);把任一 spine 节点 SwiftUI 化;把 `ModelStore`/completion
  store 变成注入服务;用细粒度 diff 替换 sidebar `reloadData()`;合并 Compose + DraftLanding VC。

### 2.6 一致性测试(✓/✗ 判据)

**每个类 MUST 可放进 §2.0 表模式,每格取自其封闭词表,且满足 §2.1–§2.5。** 类
**符合(✓)** 当且仅当全部:① 可放置(恰一 Layer、一 Kind、一 Owner/lifetime;不跨两层);
② 单所有者(C-1)且合法构造器(C-2/C-3);③ 已知数据进通道 + 已知数据出通道,各匹配其 §2.3
边裁决;④ 无非法依赖方向(L1):仅向下,除单一 `selectionObserver`;⑤ 正确 host 制式(§2.4)
或"—";⑥ 不违反任何不可触碰契约(§2.5)。

**无法放置的类是设计缺陷,不是表缺陷。** 标 `✗ + 一句话问题`;修法是修设计(拆分/给单一所有者/
定通道与制式)—— 绝不放宽词表或发明混合格来"凑合"。

---

## 3. 组件归属表(完整)

> 这是最重要的产物:**每个模块/类一行**,固定列模式。按区域分节。
> TARGET 行反映目标设计(REFACTOR-PLAN §5/§8);as-is 在括号内注明。
> FACT = 源码已读;INFERENCE = 判断。✗ 行的修复 PR 见各节末与 §3.9 汇总。

### 3.1 App shell · 路由 · DI(`App/` + `App/AppKit/`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `CCTermApp` | App-lifecycle | SU-View | Swift `@main` runtime | OS process | n/a(持 `@NSApplicationDelegateAdaptor`) | none(委派 AppDelegate) | C(Settings 占位 scene) | unchanged | ✓ |
| `AppCommands` | App-lifecycle | SU-View (`Commands`) | `CCTermApp.body`(挂占位 `Settings` scene) | scene lifetime | ctor-injected(`searchBus` + 两闭包) | injected closure(`openSettings`/`openAbout`);`@Observable write`(`searchBus.requestFocus()`) | — | unchanged | ✓ |
| `AppDelegate` | App-lifecycle | AK-NSObject (`NSApplicationDelegate`) | SwiftUI runtime 经 `@NSApplicationDelegateAdaptor` | OS process | n/a(根所有者) | imperative controller call(建 `MainWindowController`;`show*Window`) | — | unchanged | ✓ |
| `AppState` | App-scope-state | @Observable-SVC | `AppDelegate` stored-prop init | process | n/a(它*就是*状态容器) | `@Observable write`(子服务);closure wiring(`onTurnEndedNotice`) | — | PR8(可选:`searchBus`/UserDefaults 包装移入;`ModelStore` 留 `.shared`) | ✓ |
| `MainSelectionModel` | App-scope-state | @Observable-SVC | `AppDelegate` stored-prop init | process / window | n/a(真源) | `@Observable write`(`selection=`)+ 同步 `selectionObserver.selectionDidChange`(唯一向上结构边) | — | unchanged(留在 AppDelegate —— 窗口级,§8.P11) | ✓ |
| `MainSelection` | Pure-value | value/MDL | inline(enum literal) | per-value | n/a | n/a | — | unchanged | ✓ |
| `DemoKind`(DEBUG) | Pure-value | value/MDL | inline(enum literal) | per-value | n/a | n/a | — | unchanged | ✓ |
| `MainSelectionObserver`(protocol) | DI-context | value/MDL(protocol) | n/a | n/a | n/a | n/a(定义唯一向上结构边) | — | unchanged | ✓ |
| `TranscriptSearchBus` | App-scope-service | @Observable-SVC | `AppDelegate` stored-prop init | process | n/a | `@Observable write`(`focusRequestCounter`)— 由 AppKit `TranscriptSearchToolbarBridge` 经 `withObservationTracking` 拉 | — | PR8(可选 ★MOVED AppDelegate→AppState;doc 现说 `.searchable`,陈旧,PR8 修) | ✓ |
| `SettingsWindowController` | Window-shell | AK-VC (`NSWindowController`) | `AppDelegate.showSettingsWindow()`(lazy) | process(存活 close→reopen) | n/a | imperative controller call(host `SettingsView`) | C(窗口内容,default sizing) | unchanged | ✓ |
| `AboutWindowController` | Window-shell | AK-VC (`NSWindowController`) | `AppDelegate.showAboutWindow()`(lazy) | process | n/a | imperative controller call(host `AboutView`) | C(窗口内容,default sizing) | unchanged | ✓ |
| `MainWindowController` | Window-shell | AK-VC (`NSWindowController`, `NSToolbarDelegate`) | `AppDelegate.applicationDidFinishLaunching` | window(= process) | ctor-injected(`model`/`appState`/`searchBus`);`@Observable pull`(`model.selection` 经 `withObservationTracking`) | imperative controller call(建 split + toolbar) | —(拥有下方 toolbar host) | unchanged | ✓ |
| `TranscriptProjectChip` | SwiftUI-view | SU-View | `MainWindowController.toolbar(_:itemForItemIdentifier:)` 经 `NSHostingView` | toolbar-item lifetime | `@Observable pull`(`@Bindable model`、`sessionManager.existingSession`) | none(只读 chip) | B′(toolbar 槽,`[.intrinsicContentSize]`;`:253`) | unchanged | ✓ |
| `ArchiveFilterToolbarButton` | SwiftUI-view | SU-View | `MainWindowController.toolbar(...)` 经 `NSHostingView` | toolbar-item lifetime | `@Observable pull`(`@Bindable model`、`sessionManager.archivedFolderOptions`) | `@Observable write`(`model.archiveSelectedFolderPath`) | B′(toolbar 槽,`[.intrinsicContentSize]`;`:280`) | unchanged | ✓ |
| `TranscriptSearchToolbarBridge` | AppKit-coordinator | AK-NSObject (`NSSearchFieldDelegate`) | `MainWindowController.makeSearchBridgeIfNeeded` | window | `@Observable pull`(`searchBus.focusRequestCounter`);per-keystroke 拉 live `Transcript2Controller` | imperative controller call(`controller.runSearch/nextSearchHit/previousSearchHit`) | — | unchanged | ✓ |
| `MainSplitViewController` | Window-shell | AK-VC (`NSSplitViewController`) | `MainWindowController.init` | window | ctor-injected(`model`/`appState`/`searchBus`) | imperative controller call(建 sidebar + router;**DI 扇出点**) | — | PR7 ★CHANGED(建一个 `DetailContext` + 一个 `SidebarContext`;停止把 AppState 解构成 7-袋/4-袋) | ✓ |
| `DetailContext` ★NEW | DI-context | value/MDL(struct) | `MainSplitViewController.init` | window(经 `makeChild` 按值传) | n/a(携带 `model` + 4 个被消费服务:`SessionManager`/`RecentProjectsStore`/`InputDraftStore`/`\.syntaxEngine`) | ctor-injected(交予各 detail child) | — | PR7 ★NEW(替 7-arg 袋;死 `notifications`/`searchBus` env 边在 PR1 删) | ✓ |
| `DetailRouterViewController` | Window-shell(Detail-child-VC owner) | AK-VC (`NSViewController`, `MainSelectionObserver`) | `MainSplitViewController.init` | window | ctor-injected(DI 袋 → `DetailContext`);仅经同步 observer 回调读 `model.selection`(绝不 `withObservationTracking`) | `model.select`(转发 `notifications.onActivateSession`);imperative controller call(`makeChild`、child `present(sessionId:)`) | —(绘 `NSVisualEffectView`;挂 child 四边 pin) | PR7 ★CHANGED(持 + 整体穿 `DetailContext`);PR2 ★RENAMED(`searchEngine`→`syntaxEngine`) | ✓ |
| `DetailRouterChild`(protocol) | Detail-child-VC | value/MDL(protocol) | n/a | n/a | n/a | n/a(`prepareForRemoval()` 确定性拆除契约) | — | unchanged | ✓ |
| `CrossfadeController`(提议,P6) | AppKit-coordinator | AK-NSObject | `DetailRouterViewController` + `TranscriptSwapCoordinator`(若采纳) | window / per-attach | n/a(有状态动画 helper) | imperative controller call(`NSAnimationContext.runAnimationGroup`) | — | PR13 ★OPTIONAL(**默认不做**;§8.P6/§11) | ✗ — 不干净落位:所有者不明(router 跨类 vs chat 同 session crossfade 在 park-type/guarded-finish/I5 pre-flush 上分歧)。方案降级为可选/保留两份副本。这是*抽象*的设计缺陷,非现状代码缺陷。**不引入此行。** |

> 验证要点:toolbar host(chip/filter)经验证 `MainWindowController.swift:253`/`:280` 为 B′ 无约束。
> Settings/About 为 C default-sizing(`:15`/`:23`)。`selectionObserver` 同步 fire 见 `select(_:)`
> (`:53-57`)/`promote(to:)`(`:72-79`),不可泛化为总线。死注入:`notifications`/`searchBus` 穿
> 进 router 与各 child 但**无 SwiftUI reader**(P1),仅经 AppKit 通道抵达,PR1 删其 `.environment` 边。
> `searchEngine` 误名 → `syntaxEngine`(PR2,编译器守卫)。

### 3.2 Sidebar(`Sidebar/*`)

> **Host 制式(全节适用):** sidebar 100% AppKit,无任何 `NSHostingView`。最接近的 BOUNDARY-SPEC
> 制式是 E(AppKit cell 内 SwiftUI 叶),但 spec 记 E **无生产实例**,且 sidebar cell 是原生
> `NSTableCellView`,非 host。故每行 Host regime **"—"**,符合,非缺陷。

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SidebarViewController` | Window-shell | AK-VC | `MainSplitViewController`(target:`SidebarContext`;as-is 4-袋 init) | `MainSplitViewController` / window | `@Observable pull`(`withObservationTracking` on `model.selection`、`sessionManager.records`) | `model.select`(选择写回,`:647`);`imperative controller call`(sessionManager.archive `:482`、groupOrderStore 写) | — | PR10(拆后瘦 VC) | ✓(as-is ✗:~770 行 god-VC,7 责任;PR9/PR10 拆分修) |
| `SidebarTreeModel` ★NEW | Pure-value | value/MDL | `SidebarViewController`(调纯 `build`) | n/a —— 纯函数,无实例态 | `ctor-injected`(records + groupOrder + previouslySeenGroups 传入) | `none`(返回 `(nodes, newGroups)`) | — | PR9 | ✓ |
| `SidebarContextMenuController` ★NEW | AppKit-coordinator | AK-NSObject (`NSMenuDelegate`) | `SidebarViewController` | `SidebarViewController` / window | `ctor-injected`(sessionManager、openInService、clicked-row resolver) | `imperative controller call`(sessionManager.archive、openInService.open、pasteboard 写) | — | PR10 | ✓ |
| `SidebarContext` ★NEW | DI-context | value/MDL(struct) | `MainSplitViewController.init` | window(按值传) | n/a(携带 model + 被消费服务) | ctor-injected(交予 `SidebarViewController`) | — | PR7 | ✓ |
| `SidebarItemNode` | Pure-value | value/MDL(引用类型) | `SidebarTreeModel.build`(as-is VC `buildRootChildren`) | VC 上的树数组;跨 `reloadData()` 存活 | `ctor-injected`(kind/selection/children) | `none` | — | PR9(移至 tree 输出) | ✓(刻意引用类型,为 `NSOutlineView` `===` 身份,inv 6.1;非缺陷) |
| `SidebarItemNode.Kind` | Pure-value | value/MDL(enum) | inline | with node | n/a | none | — | unchanged | ✓ |
| `FixedKind` | Pure-value | value/MDL(enum) | inline | static | n/a | none | — | unchanged | ✓ |
| `SidebarSessionGroupOrderStore` | App-scope-state | @Observable-SVC(`@MainActor` store,UserDefaults) | `AppState.init` | `AppState` / process | `ctor-injected`(UserDefaults) | `@Observable write`(经 `arrange`/`prependIfAbsent`/`replace` 持久) | — | unchanged | ✓ |
| `SidebarTitleSanitizer`(`String.collapsedSingleLineForDisplay()`) | Pure-value | value/MDL(`String` ext,纯) | n/a(自由函数) | n/a | n/a | none | — | unchanged | ✓ |
| `SidebarLayout` | Pure-value | value/MDL(常量 enum) | n/a(命名空间) | static | n/a | none | — | unchanged | ✓ |
| `SidebarCellViewBase` | Per-attach(per-row) | AK-View (`NSTableCellView`) | `SidebarViewController` `viewFor`(outline 复用) | `NSOutlineView` row 复用池 | `ctor-injected`(VC 每 `viewFor` 配) | none | — | unchanged | ✓ |
| `SidebarFixedCellView` | Per-attach(per-row) | AK-View | VC `viewFor` | outline 复用池 | `ctor-injected`(`configure(kind:)`) | none | — | unchanged | ✓ |
| `SidebarFolderCellView` | Per-attach(per-row) | AK-View | VC `viewFor` | outline 复用池 | `ctor-injected`(`configure(folderName:isExpanded:)`、`setExpanded`) | none(chevron 局部态;展开/折叠由 VC 驱) | — | unchanged | ✓ |
| `SidebarHistoryCellView` | Per-attach(per-row) | AK-View | VC `viewFor` | outline 复用池 | `ctor-injected`(`configure(...)` 由 VC per-row obs 驱) | none | — | unchanged | ✓(持 `observedSessionId`/`fallbackTitle`/`isDraftRow` 局部态作复用守卫,inv 6.7/6.8;合法 cell 态) |
| `SidebarStatusIndicatorView` | Renderer-internal(cell leaf) | AK-View (`NSView`) | `SidebarHistoryCellView` | parent cell | `ctor-injected`(`update(isRunning:hasUnread:)`) | none | — | unchanged | ✓ |
| `SidebarLoadingDotsView` | Renderer-internal(cell leaf) | AK-View (`NSView`,CALayer anim) | `SidebarStatusIndicatorView` | parent indicator | `ctor-injected`(可见性由 parent 切) | none | — | unchanged | ✓ |
| `ShimmerOverlay` | Renderer-internal(cell leaf) | AK-NSObject(CAGradientLayer mask helper) | `SidebarHistoryCellView`(lazy,`:293`) | parent cell(weak host ref) | `ctor-injected`(host `NSTextField`) | none | — | unchanged | ✓ |
| `NoDisclosureOutlineView` | Window-shell(sub-view) | AK-View (`NSOutlineView` 子类) | `SidebarViewController`(stored `outlineView`) | `SidebarViewController` | n/a(仅抑制 disclosure cell) | none | — | unchanged(拆后留 VC —— 拥 DnD/expand) | ✓ |

> 通道验证(无缺陷):四个服务输入皆 ctor-injected;VC 从不构造服务。选择写回经 `model.select(_:)`
> (`:647`),从不裸 `selection`(inv 6.4)。echo-suppression 守卫(`isApplyingSelectionFromModel`)
> 防 model→outline→model 反馈(inv 6.3)。`existingSession(_:)` 非分配查找(inv 6.8);复用守卫
> 查 `observedSessionId == sessionId`(inv 6.7)。

### 3.3 Detail VC · transcript swap · host/scrim(`Content/Chat/` 容器侧)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `ChatSessionViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(`:365`) | router;同类复用,跨类重建 | ctor-injected `DetailContext`(TARGET;as-is 7-arg,`:127`) | imperative controller call(router→`present(sessionId:)`,`:252`);`model.select` 经注入 `onSubmit`/`onBuiltinCommand` 闭包 | —(容器 VC;host B + A 叠层) | PR5(卡片 host)、PR7(DetailContext)、PR13(swap 拆分) | ✓(TARGET;PR13 脱去 swap 状态机后。as-is = god-VC 混"显示什么"+ attach/swap,P5) |
| `TranscriptSwapCoordinator` ★NEW | AppKit-coordinator | AK-NSObject | `ChatSessionViewController`(PR13) | chat VC;VC 生命期 | ctor-injected(controller-per-session + `topScrim`/insert-closure 传入) | imperative controller call(`Transcript2Controller.apply/scrollToTail/setLoading/setTurnUsage`) | —(拥 per-attach host,自身非 host) | PR13 | ✓(TARGET,最高危;**仅当** §8.P5 四点 seam 契约成立时干净 —— 单 `currentSession` 所有者、z-anchor `.below topScrim`、cutout 坐标变换跨拆分存活、拆分线*穿过* `attachSession`。否则跨两所有者 → 见 §3.9 缺陷 #2) |
| `transcriptScroll: Transcript2ScrollView` | Per-attach | AK-View | `TranscriptScrollViewFactory.make`(`:344`) | swap coordinator(TARGET;as-is chat VC);每 session attach 重建 | n/a(命令式驱) | imperative controller call(经 `bindData` 绑到 `session.controller`) | —(四边 pin 裸 scroll,非 SwiftUI host) | PR13(移入 coordinator) | ✓ |
| `transcriptSheetPresenter: Transcript2SheetPresenter` | Per-attach | AK-NSObject | `ChatSessionViewController.attachSession`(`:405`;TARGET → coordinator) | swap coordinator(TARGET;as-is chat VC);per-attach,swap 时 `stop()` | `@Observable` pull(`withObservationTracking` on `controller.pendingUserBubbleSheet`/`pendingImagePreview`) | imperative controller call(`view.window?.beginSheet`) | D(模态 sheet host) | PR13(移入 coordinator) | ✓ |
| `topScrim: TranscriptTopScrimView` | Per-attach | AK-View | `ChatSessionViewController.loadView`(`:156`) | chat VC;VC 生命期(挂一次) | n/a | imperative controller call(`window.performDrag`/`performZoom`) | —(纯 `NSView`,刻意非 host 以不注册 cursor rect) | unchanged(z-anchor 留 VC,喂给 coordinator) | ✓ |
| `bottomScrim: TranscriptBottomScrimView` | Per-attach | AK-View | `ChatSessionViewController.loadView`(`:160`) | chat VC;VC 生命期 | ctor/`didSet`(rect 经 `applyScrimCutouts` 推) | none(装饰;`hitTest→nil`) | —(纯 `NSView`,hitTest 穿透 + 奇偶 cutout) | unchanged | ✓ |
| `TranscriptScrimView`(base) | Pure-value | AK-View | n/a(基类,被 top/bottom 子类化) | n/a | n/a | none(装饰,`hitTest→nil`) | — | unchanged(doc drift:`Content/Chat/CLAUDE.md` 以 base 名称 top scrim,PR8 修) | ✓ |
| `restingBarHost: NSHostingView<ChatComposeStack>` ★RENAMED ★UNERASED | Per-attach | AK-View | `ChatSessionViewController.loadView`(`:164`,as-is `composeOrBarHost`) | chat VC;VC 生命期 | n/a(host);内容读 `@Observable` | none(host 壳;内容经注入闭包发) | B(居中、宽 cap、底锚组件;`[.intrinsicContentSize]` + 五约束;`:172,205-210`;§3"最优") | PR5(卡片移出)、PR6(un-erase)、PR8(rename) | ✓(TARGET;as-is 名 `composeOrBarHost` 扭曲且 `AnyView` 擦除,P12) |
| `ChatComposeStack` | SwiftUI-view | SU-View | `restingBarHost` root(`:164,548`) | host;per-attach | `@Observable` pull(`@Bindable model`,`:609`) | injected closure(`onSubmit`/`onAttachRect`/`onPillRect`/`onBuiltinCommand`,`:610-615`) | —(在 regime-B host 内) | PR6(un-erase;卡片子项移除 §7) | ✓ |
| `ChatRestingBar` | SwiftUI-view | SU-View | `ChatComposeStack.body` `.id(sid)`(`:662`) | view identity(`sid`) | `@Observable` pull(`session.*`) | `Session` 方法(`session.respond` 旧在此,移至 overlay §7)+ 注入闭包 | —(在 regime-B host 内) | PR5(★CHANGED:卡片 ZStack + body `.animation` 移除 → "just the bar") | ✓(TARGET;as-is 持卡片 `ZStack(alignment:.bottom)` 报 UNION 高 → bar-host 耦合,P-headline) |
| `permissionCardHost: PassthroughHostingView<PermissionCardOverlay>` ★NEW | Per-attach | AK-View | `ChatSessionViewController.loadView`(PR5,在 `restingBarHost` 之后保 z-序) | chat VC;VC 生命期 | n/a(host);内容读 `@Observable` | none(host 壳) | **A** ⟨注 H-4⟩ | PR5 | ✓(TARGET;§7.8 将其和解为 regime A —— A 尺寸 + 穿透 hit-test 附加项,非 B″;若误填 B″ 则 ✗) |
| `PassthroughHostingView` ★NEW(重引入) | Per-attach | AK-View | n/a(子类型;实例 = `permissionCardHost`) | n/a | n/a | none(覆写 `hitTest`→`nil` 卡外 + 空 `resetCursorRects`) | —(regime-A-hybrid 的 host 后备类) | PR5(今仅墓碑注释 `DetailRouterViewController.swift:27`;重加,勿复用旧) | ✓ |
| `PermissionCardOverlay` ★NEW | SwiftUI-view | SU-View | `permissionCardHost` root(PR5) | host;VC 生命期 | `@Observable` pull(`session.pendingPermissions.first`,由 `model.selection` + `.id(sid)` 路由) | `Session` 方法(4 个决策闭包 → `session.respond(...)`,从 `ChatRestingBar` 逐字移来) | —(regime-A-hybrid host 内常尺寸内容;底 inset 36 = `chatBottomInset`) | PR5 | ✓(TARGET;`PermissionCardWiringTests` 守卫 closure→`respond` 路由) |
| `ComposeSessionViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(`:375`) | router;仅 `.newSession` 挂 | ctor-injected `DetailContext`(TARGET;as-is 7-arg,`:44`) | `model.select`(经 `onResumeSession`,`:96`)+ 注入 `onSubmit` | A(填满-pane;`[]` + 四边 pin,`:115-124`) | PR6(mountFillPaneHost + un-erase)、PR7(DetailContext) | ✓ |
| `ComposeSessionView` | SwiftUI-view | SU-View | `ComposeSessionViewController.viewDidLoad` host root(`:82`) | host;VC 生命期 | `@Observable` pull(`@Environment SessionManager`、draft config bindings) | injected closure(`onSubmit`/`onResumeSession`)+ `session.draft?` setter 经 binding | —(regime-A host 内) | PR6(从 `AnyView` 解除) | ✓ |
| `DraftSessionLandingViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(`:385`) | router;`.session(_)` 为 `.draft` 时挂 | ctor-injected `DetailContext`(TARGET;as-is 7-arg,`:40`) | imperative controller call(router→`present(sessionId:)`,`:76`)+ 注入 `onSubmit`/`onBuiltinCommand` | A(填满-pane;`[]` + 四边 pin,`:136-145`) | PR6(mountFillPaneHost + un-erase)、PR7(DetailContext) | ✓ |
| `DraftSessionLandingView` | SwiftUI-view | SU-View | `DraftSessionLandingViewController.mountHost` root(`:102`) | host;`boundSessionId` 变时重建 | `@Observable` pull(`@Environment SessionManager`) | injected closure(`onSubmit`/`onBuiltinCommand`) | —(regime-A host 内) | PR6(un-erase) | ✓ |
| `ArchiveViewController` | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(`:395`) | router;仅 `.archive` 挂 | ctor-injected `DetailContext`(TARGET;as-is 7-arg,`:31`) | `model.select`(经 `onUnarchive`,`:71-73`)+ 双向 `@Bindable` on `model.archiveSelectedFolderPath`(`:63-66`) | A(填满-pane;`[]` + 四边 pin,`:102-111`;绑定高度中性) | PR6(mountFillPaneHost + un-erase)、PR7(DetailContext) | ✓ |
| `ArchiveView` | SwiftUI-view | SU-View | `ArchiveViewController.viewDidLoad` host root(`:68`) | host;VC 生命期 | `@Observable` pull + 双向 `Binding<String?>`(folder filter,`:63`) | `model.select`(经 `onUnarchive`)+ binding 写 `model.archiveSelectedFolderPath` | —(regime-A host 内) | PR6(un-erase) | ✓ |
| `mountFillPaneHost(_:in:)` helper ★NEW | DI-context ⟨注 R2:host-mount helper,自由函数⟩ | translator | n/a(被 3 个填满-pane VC 调) | call-site | n/a | none(返回/pin 一个四边 `[]` host) | A(编码 regime-A:`[]` + 四边 pin;统一 Archive/Compose/DraftLanding 三联) | PR6 | ✓(TARGET;chat 的 regime-B `restingBarHost` 刻意**不**折入,§10 rule 6) |
| `injectDetailEnvironment(_:)` View 修饰符 ★NEW | DI-context ⟨注 R2:SwiftUI `View` 扩展⟩ | translator | n/a(SwiftUI `View` ext) | call-site | n/a | `@Observable` write(`.environment(...)` 4 个被消费服务) | — | PR7 | ✓(TARGET;替 5 份副本;落地需先 un-erase 使漏注入成编译错) |
| `Transcript2SheetPresenter`(canonical 行见 §3.3 per-attach 行) | Per-attach | AK-NSObject | — | — | — | — | D | PR13 | ✓ |

> 三个填满-pane child(Archive/Compose/DraftLanding)为 regime-A,其 `[]`+四边 模式由
> `mountFillPaneHost`(PR6)统一;chat `restingBarHost` 为 regime-B,刻意**排除**于该 helper
> (§10 rule 6)—— 保留唯一非对称 host 显式化是有意的,非缺陷。所有 scrim 为纯 `NSView`(从不
> `NSHostingView`),故不注册 cursor rect —— 与 `PassthroughHostingView` 须抑制 cursor rect 同根。

### 3.4 Input bar · Permission cards · Completion(`Content/Chat/InputBar*` · `Completion/*` · `Services/Completion/*`)

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `InputBarView2` | SwiftUI-view | SU-View | `InputBarChrome.body` | view identity | ctor-injected(值 + 闭包) | injected closure(`onSubmit`/`onStop`/`onAttachRect`/`onPillRect`/`onBuiltinCommand`) | —(bar host 内叶) | unchanged | ✓ |
| `InputBarView2.Attachment` | Pure-value | value/MDL | `InputBarView2` | value | n/a | none | — | unchanged | ✓ |
| `InputBarView2.Submission` | Pure-value | value/MDL | `InputBarView2.handleSend` | value | n/a | none | — | unchanged | ✓ |
| `ReportFrame`(private modifier) | SwiftUI-view | SU-View | `InputBarView2.body` | view identity | ctor-injected | injected closure(rect action) | — | unchanged | ✓ |
| `AttachmentCard`(private) | SwiftUI-view | SU-View | `InputBarView2` | view identity | ctor-injected | injected closure(`onRemove`) | — | unchanged | ✓ |
| `ImagePreviewView`(private) | SwiftUI-view | SU-View | `InputBarView2.sheet` | view identity | ctor-injected | `\.dismiss` | D(sheet) | unchanged | ✓ |
| `InputBarChrome` | SwiftUI-view | SU-View | `ChatRestingBar`/`ComposeSessionView`/draft-landing bar | view identity | `@Observable pull`(`session.*` 经 `@Environment SessionManager`) | injected closure(转发 bar 闭包) | —(bar host 内叶) | unchanged | ✓ |
| `ChatRestingBar` | SwiftUI-view | SU-View | `restingBarHost`(经 `ChatComposeStack`) | view identity(`.id(sid)`) | `@Observable pull`(target 中 `session.pendingPermissions` 移除) | injected closure(bar 闭包) | B(组件;经 host) | PR5(★CHANGED §7:卡片 ZStack/`if let pending`/body `.animation` 移除 → "just the bar") | ✓(target)。**as-is ✗**:双关 —— host 输入 bar **且** 权限卡 ZStack,其 union 高泵 host intrinsic 高(§7.1) |
| `ChatComposeStack` | SwiftUI-view | SU-View | `restingBarHost` | host lifetime | `@Observable pull`(`model.selection`) | none(路由 bar \| `EmptyView`) | B(组件) | unchanged(仅 host 改名) | ✓ |
| `AttachButton` | SwiftUI-view | SU-View | `InputBarView2.body` | view identity | ctor-injected | injected closure(`onPick`) | — | unchanged | ✓ |
| `NewSessionConfigurator<InputBar>` | SwiftUI-view | SU-View | `ComposeSessionView` | view identity | ctor-injected `@Binding` + `@Environment` + `@State GitProbe` | `@Binding` write(`folderPath`/`useWorktree`/`sourceBranch`)+ 注入闭包(`onResumeSession`) | —(fill-pane compose host 内) | unchanged | ✓ |
| `GitProbe` | View-scope-state | @Observable-SVC | `NewSessionConfigurator.init`(`@State`) | view identity | n/a(probe 结果) | `@Observable write` | — | PR12(P15:加 `@MainActor`) | ✓(view 私有交互状态机,Rule 5;as-is ✗ = 缺 `@MainActor` 分层 nit,PR12 修) |
| `PlusHoverButtonStyle`/`ResumeRowButtonStyle`/`HideEnclosingScrollerWidth`(private) | SwiftUI-view | SU-View | `NewSessionConfigurator` | view identity | n/a | none | — | unchanged | ✓ |
| `InputBarSessionChrome` | SwiftUI-view | SU-View | `InputBarChrome.body` | view identity | ctor-injected `Session` + `.shared`(`ModelStore`) | none(布局子控件) | — | unchanged | ✓ |
| `PermissionModePicker` | SwiftUI-view | SU-View | `InputBarSessionChrome` | view identity | ctor-injected `Session` + `.shared`(`NewSessionDefaultsStore`) | Session 方法(`setPermissionMode`)+ `@State`(popover) | — | unchanged | ✓ |
| `PermissionModePopoverContent`(private) | SwiftUI-view | SU-View | `PermissionModePicker.popover` | view identity | ctor-injected | injected closure(`onSelect`) | B″(系统 popover) | unchanged | ✓ |
| `ModelEffortPicker` | SwiftUI-view | SU-View | `InputBarSessionChrome` | view identity | ctor-injected `Session` + `@State ModelStore.shared` + `.shared`(`EffortDefaultStore`/`NewSessionDefaultsStore`) | Session 方法(`setModel`/`setEffort`/`setFastMode`) | — | unchanged | ✓(`.shared` 读为文档化 Rule-11 例外) |
| `ModelEffortPopoverContent`/`ModelPopoverRow`/`FastModeToggleRow`(private) | SwiftUI-view | SU-View | `ModelEffortPicker.popover` | view identity | ctor-injected | injected closure | B″(popover) | unchanged | ✓ |
| `ContextRingButton` | SwiftUI-view | SU-View | `InputBarSessionChrome` | view identity | `@Observable pull`(`session.contextUsage`/`contextUsedTokens`/`contextWindowTokens`) | Session 方法(`requestContextUsage`) | — | unchanged(target 由 `ContextUsageCache` 投影支撑,P8) | ✓ |
| `ContextPopoverContent`/`ContextBreakdownView`/`CategoryRow`/`ExpandableGroup`(private) | SwiftUI-view | SU-View | `ContextRingButton` | view identity | ctor-injected(`ContextUsage` 值 / `Session`) | Session 方法(`requestContextUsage`) | B″(popover) | unchanged | ✓ |
| `BackgroundTaskButton` | SwiftUI-view | SU-View | `InputBarSessionChrome` | view identity | `@Observable pull`(`session.tasks`) | **TARGET:Session 方法(`session.stopBackgroundTask(taskId:)`)** | — | PR4(★CHANGED P4) | ✓(target)。**as-is ✗**:唯一生产流违规 —— `stopAction` 调 `session.runtime.markTaskStoppedLocally` 穿 `Session` façade(§6.1 / P4) |
| `BackgroundTaskList` | SwiftUI-view | SU-View | `BackgroundTaskButton.popover` | view identity | ctor-injected `Session`(`session.tasks`) | injected closure(`onSelectTask`) | B″(popover) | unchanged | ✓ |
| `BackgroundTaskList.TaskGroup` + `group(tasks:)` | Pure-value | value/MDL | `BackgroundTaskList` | value | n/a | none | — | unchanged | ✓ |
| `BackgroundTaskRow` | SwiftUI-view | SU-View | `BackgroundTaskList.section` | view identity | ctor-injected(`BackgroundTask` 值) | injected closure(`onSelect`) | — | unchanged | ✓ |
| `BackgroundTaskFormat` | Pure-value | value/MDL | static enum | n/a | n/a | none | — | unchanged | ✓ |
| `BackgroundTaskDetailSheet` | SwiftUI-view | SU-View | `BackgroundTaskButton.sheet` | view identity | ctor-injected(`BackgroundTask`)+ `@State stream` | injected closure(`onStop`/`onDismiss`) | D(sheet) | unchanged | ✓ |
| `BackgroundTaskOutputView` | SwiftUI-view | SU-View | `BackgroundTaskDetailSheet.outputBody` | view identity | `@Bindable`(`stream.text`) | none | — | unchanged | ✓ |
| `BackgroundTaskOutputStream` | View-scope-state | @Observable-SVC | `BackgroundTaskDetailSheet.rebindStream`(`@State`) | view identity(per spool path) | n/a(tail 文件) | `@Observable write` | — | unchanged | ✓(view 私有交互状态机,Rule 5;`@MainActor` + `nonisolated deinit`) |
| `TodoButton` | SwiftUI-view | SU-View | `InputBarSessionChrome` | view identity | `@Observable pull`(`session.todos`) | none(只读 popover 触发) | — | unchanged(target 由 `TodoTracker` 投影支撑,P8) | ✓ |
| `TodoList`/`TodoRow` | SwiftUI-view | SU-View | `TodoButton.popover` | view identity | ctor-injected `Session`(`session.todos`)/ 值 | none | B″(popover) | unchanged | ✓ |
| `TodoStatusGlyph`(+`CompletedRingAndDotShape`/`RotatingDottedRing`) | SwiftUI-view | SU-View | `TodoButton`/`TodoRow` | view identity | ctor-injected(`TodoEntry.Status`) | none | — | unchanged | ✓ |
| `PopoverList`(+`PopoverSectionHeader`/`PopoverRow`/`PopoverRowHoverStyle`) | SwiftUI-view | SU-View | popover bodies | value/view identity | ctor-injected | injected closure(`onSelect`) | — | unchanged | ✓ |
| `BarChromeButton<Content>` | SwiftUI-view | SU-View | picker/button views | view identity | ctor-injected(`label`) | injected closure(`action`) | — | unchanged | ✓ |
| `SedEditInfo` | Pure-value | value/MDL | `SedEditParser.parse` | value | n/a | none | — | unchanged | ✓ |
| `SedEditParser` | Pure-value | translator | static enum | n/a | n/a | none | — | unchanged | ✓ |
| `ShellTokenizer` | Pure-value | translator | static enum | n/a | n/a | none | — | unchanged | ✓ |
| `PermissionCardView` | SwiftUI-view | SU-View | TARGET:`PermissionCardOverlay`(as-is:`ChatRestingBar`) | view identity | ctor-injected(`PermissionRequest` + 4 决策闭包) | injected closure(decisions) | —(card-overlay host 内叶) | PR5(★MOVED §7;body 字节不变) | ✓ |
| `PermissionCardCopy` | Pure-value | value/MDL | static enum | n/a | n/a | none | — | unchanged | ✓ |
| `PermissionFallbackCardBody`(private) | SwiftUI-view | SU-View | `PermissionCardView.body(for:)` | view identity | ctor-injected(`PermissionRequest`) | none | — | unchanged | ✓ |
| `PermissionCardSurface`(private modifier) | SwiftUI-view | SU-View | `PermissionCardView.body` | view identity | `@Environment(\.colorScheme)` | none | — | unchanged | ✓ |
| `PermissionDecisionButton` | SwiftUI-view | SU-View | `PermissionCardView`/`…AskUserQuestionCardBody` | view identity | ctor-injected(title/role) | injected closure(`action`) | — | unchanged | ✓ |
| `PermissionCardKind` | Pure-value | value/MDL | `PermissionCardKind.kind(for:)` | value | n/a | none | — | unchanged | ✓ |
| `Permission{Shell,SedEdit,FileWrite,NotebookEdit,WebFetch,FilesystemRead,TaskAgent,Skill,Mcp,EnterPlanMode,ExitPlanMode}CardBody` | SwiftUI-view | SU-View | `PermissionCardView.body(for:)` | view identity | ctor-injected(`PermissionRequest`[,`kind`]) | none | — | unchanged | ✓(12 个 card-body 家族:value-in / closures-out 叶) |
| `PermissionAskUserQuestionCardBody` | SwiftUI-view | SU-View | `PermissionCardView.body(for:)` | view identity | ctor-injected(`PermissionRequest`) | injected closure(`onSubmit`/`onCancel`) | — | unchanged | ✓ |
| `PermissionCardOverlay` | SwiftUI-view | SU-View | `permissionCardHost` ★NEW | host lifetime(VC-resident,如 scrim) | `@Observable pull`(`session.pendingPermissions.first`,由 `model.selection` + `.id(sid)` 解析) | Session 方法(`session.respond(...)`,4 闭包从 `ChatRestingBar` 逐字移来) | **A** ⟨注 H-4⟩ | PR5 ★NEW-§7 | ✓ |
| `CompletionState`(as-is `CompletionViewModel`) | View-scope-state | @Observable-SVC | `InputBarView2`(`@State`) | view identity | n/a(输入法状态机) | `@Observable write`(`items`/`isActive`)→ View → NSTextView | — | PR8(★RENAMED P12) | ✓(Rule-5 view 私有状态机;改名去"无-VM 区的 VM"困惑) |
| `CompletionState.CompletionSession`(as-is nested) | Pure-value | value/MDL | trigger rules | value | n/a | injected closures(provider/makeReplacement/…) | — | PR8(随改名嵌套) | ✓ |
| `CompletionItem`(protocol) | Pure-value | value/MDL | conformers | n/a | n/a | none | — | unchanged | ✓ |
| `CompletionTriggerRule`(protocol) | Pure-value | translator | conformers | n/a | ctor-injected(`CompletionTriggerContext`) | 返回 `CompletionSession?` | — | unchanged | ✓ |
| `CompletionTriggerContext` | Pure-value | value/MDL | `InputBarView2.triggerContext` | value | n/a | 携 `onBuiltinCommand` 闭包 | — | unchanged | ✓ |
| `SlashCommandTriggerRule` | Pure-value | translator | `CompletionState.rules` | process(规则列表) | ctor-injected(context) | `.shared`(`SlashCommandStore`)+ 注入闭包(`onBuiltinCommand`) | — | unchanged | ✓ |
| `FileMentionTriggerRule` | Pure-value | translator | `CompletionState.rules` | process(规则列表) | ctor-injected(context) | `.shared`(`FileCompletionStore`) | — | unchanged | ✓ |
| `CompletionListView` | SwiftUI-view | SU-View | `InputBarView2.pill` | view identity | `@Bindable`(`viewModel`) | injected closure(`onConfirm`/`onDeleteRecent`) | — | PR3(P13/C14:`onDeleteRecent`/`isRecent` recent-dir 接线移除) | ✓(target) |
| `DirectoryCompletionItem` | Pure-value | value/MDL | (无构造器 —— 死) | — | n/a | none | — | PR3(★DELETED P13/C14) | ✓(待保行为删除;0 构造点) |
| `DirectoryCompletionProvider` | App-scope-service | AK-NSObject | static enum(`.shared`-style on `UserDefaults`) | process | n/a | UserDefaults write | — | PR3(★DELETED P13/C14) | ✓(随 `DirectoryCompletionItem` 死) |
| `DirectoryTreeMonitor` | App-scope-service | AK-NSObject | (死 dir-completion 路径调用者) | per-directory | n/a | injected closure(`onChange`) | — | PR3(★DELETED P13/C14) | ✓ |
| `BuiltinSlashCommand`(+`BuiltinCompletionItem`) | Pure-value | value/MDL | `SlashCommandTriggerRule` | value | n/a | none | — | unchanged | ✓ |
| `runBuiltinSlashCommand(_:…)` | AppKit-coordinator | AK-NSObject(自由 `@MainActor` func) | call site(`onBuiltinCommand` 闭包) | call-scoped | ctor-injected(`SessionManager`、`MainSelectionModel`) | imperative controller call(`manager.createSidebarDraft`/`archive`)+ `model.select` | — | unchanged | ✓ |
| `CompletionPrewarmer` | App-scope-service | value/MDL(static façade) | static enum | n/a | n/a | `.shared`(`FileCompletionStore`/`SlashCommandStore`) | — | unchanged | ✓ |
| `FileCompletionStore` | App-scope-service | @Observable-SVC(singleton) | `.shared` static | process | n/a | callback | — | PR3(删 `invalidate*` 死方法) | ✓ ⟨D1:per-cwd 缓存,文档化 `.shared` Rule-11 例外;PR3 仅删死方法,store 保留⟩ |
| `SlashCommandStore` | App-scope-service | @Observable-SVC(singleton) | `.shared` static | process | n/a | callback | — | unchanged | ✓ ⟨D1:per-cwd 缓存,文档化 `.shared` 例外⟩ |

> 验证:chat 静息 bar host 是**唯一**生产 regime-B host(`ChatSessionViewController.swift:169,182-208`)。
> 每个 card body / popover 子 view 都是 value-in / closures-out 叶,无自身 host 边界 → Host regime `—`。

### 3.5 Session core + infra + app services + models(`Services/*` · `Models/*` · `Components/Markdown/*`)

**Session core(`Services/Session/Session/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Session` | Session-core | @Observable-SVC | `SessionManager.makeSession`(lazy,按 id 缓存) | `SessionManager.sessions[id]` / session 生命期 | ctor-injected(repository、cliClientFactory);读 `phase` | Session 方法(façade fwd);@Observable write(phase) | — | unchanged(+ PR4 加 `stopBackgroundTask`) | ✓ |
| `Session.Phase` | Pure-value | value/MDL | `Session` | inline | n/a | none | — | unchanged | ✓ |
| `SessionDraft` | Session-core | @Observable-SVC | `Session.init`/`SessionManager.prepareDraftSession` | `Session.phase=.draft` / 至 promotion | ctor-injected(repository) | @Observable write(config/title/presence) | — | unchanged | ✓ |
| `SessionRuntime` | Session-core | @Observable-SVC | `SessionRuntime.fromDraft`(promotion)/`Session.init`(from record) | `Session.phase=.active` / session 生命期 | ctor-injected(repository、cliClientFactory、frameTicker);@Observable pull | injected closure(7 sinks);@Observable write | — | PR12(脱 3 投影) | ✓ |
| `SessionRuntime.Status`/`.HistoryLoadState` | Pure-value | value/MDL | `SessionRuntime` | inline | n/a | none | — | unchanged | ✓ |
| `SessionRuntime+Start`(activate/stop/send/bootstrap/`fromDraft`) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @Observable pull | @Observable write;CLIClient 调 | — | unchanged | ✓ |
| `SessionRuntime+Messaging`(interrupt/cancel) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @Observable pull | CLIClient 调 | — | unchanged | ✓ |
| `SessionRuntime+Configuration`(setModel/Effort/…/respond/setFocused) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @Observable pull | @Observable write;CLIClient RPC | — | unchanged | ✓ |
| `SessionRuntime+Receive`(CLI inbound;grouping/pairing) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @Observable pull | @Observable write;同步 fire `onMessagesChange`(runtime-I1) | — | PR11(把残余 grouping 析出共享引擎 —— 缩水/可选) | ✓ |
| `SessionRuntime+Streaming`(typewriter;`publishTurnUsage`;`resetStreamingTurn`) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @ObservationIgnored(turnUsage/turnStartedAt) | injected closure(`onTurnUsageChange`) | — | unchanged(TurnUsageMeter **排除** —— §11) | ✓ |
| `SessionRuntime+Tasks`(`handleTaskStarted/…`;`markTaskStoppedLocally`) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分(`tasks` 被观察) | @Observable pull | @Observable write(`tasks`) | — | PR4(façade 转发关闭违规)+ PR12(→ 移入 `TaskTracker`) | ✓(target)。as-is ✗:`markTaskStoppedLocally` 被 `BackgroundTaskButton` 穿 façade 触达(P4) |
| `SessionRuntime+Todos`(`captureTodoToolUses`/`applyTodoToolResult`) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分(`todos` 被观察) | @Observable pull | @Observable write(`todos`) | — | PR12(→ 移入 `TodoTracker`) | ✓(干净投影;抽取目标) |
| `SessionRuntime+ContextUsage`(`requestContextUsage`,coalescing) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分(`contextUsage` 被观察) | @Observable pull | @Observable write(`contextUsage`/`fetchedAt`) | — | PR12(→ 移入 `ContextUsageCache`) | ✓ |
| `SessionRuntime+History`(`historyJSONLURL` fwd) | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | computed | none | — | unchanged | ✓ |
| `SessionRuntime+SideQuestion` | Session-core | @Observable-SVC(ext) | n/a | `SessionRuntime` 一部分 | @Observable pull | CLIClient 调 | — | unchanged | ✓ |
| `TodoTracker` ★NEW | Session-core | @Observable-SVC(子对象) | `SessionRuntime`(组合) | `SessionRuntime` 经 tracked prop 持 | inline;observed-nested | @Observable write | — | PR12 | ✓(target;须 `@Observable` 由 tracked prop 持以传播嵌套变更) |
| `TaskTracker` ★NEW | Session-core | @Observable-SVC(子对象) | `SessionRuntime`(组合) | `SessionRuntime` 经 tracked prop 持 | inline;observed-nested | @Observable write | — | PR12 | ✓(target;闭合 P4:popover 读 `session.tasks`→tracker,写经 `Session.stopBackgroundTask`) |
| `ContextUsageCache` ★NEW | Session-core | @Observable-SVC(子对象) | `SessionRuntime`(组合) | `SessionRuntime` 经 tracked prop 持 | inline;observed-nested | @Observable write | — | PR12 | ✓(target;**@Observable** 非纯值 —— `ContextRingButton` 经 `session.contextUsage` 读) |
| `SessionConfig` | Pure-value | value/MDL | `SessionDraft`/`SessionRuntime`/decode | draft & runtime 持(promotion 时逐字复制) | n/a | none | — | unchanged | ✓ |
| `MessageEntry`(`.single`/`.group`) | Pure-value | value/MDL | `+Receive`/`ReverseEntryBuilder` | `SessionRuntime.messages` | n/a | none | — | unchanged | ✓ |
| `SingleEntry`/`GroupEntry`/`LocalUserInput`/`ToolResultPayload`/`DeliveryState`/`GroupableToolName` | Pure-value | value/MDL | builders | `MessageEntry` 内 | n/a | none | — | unchanged | ✓ |
| `MessagesChange`(`.appended`/`.updated`/`.removed`) | Pure-value | value/MDL | `SessionRuntime` 突变点 | transient(闭包参) | n/a | none(由 `onMessagesChange` 携) | — | unchanged | ✓ |
| `ReverseEntryBuilder` | Per-load | translator | `TranscriptBackfillPipeline`(冷载) | per 冷载 | ctor-injected | none(返回已建 entry) | — | PR11(已共享 `isGroupableAssistant`;残余折叠可能统一 —— 缩水) | ✓(谓词已共享;仅遍历方向按设计不同) |
| `StreamingTurnAssembler` | Renderer-internal | value/MDL | `SessionRuntime`(`streamingAssembler`) | runtime 的 `@ObservationIgnored` 字段 | n/a | none(就地变) | — | unchanged | ✓ |
| `TypewriterReveal` | Renderer-internal | value/MDL | `SessionRuntime+Streaming` | `@ObservationIgnored activeReveal` | n/a | none | — | unchanged | ✓ |
| `FrameTicker`(protocol) | App-scope-service | @Observable-SVC(proto) | ctor-injected 进 `SessionRuntime` | per runtime | n/a | imperative controller call(tick) | — | unchanged | ✓ |
| `TimerFrameTicker` | App-scope-service | @Observable-SVC | `SessionRuntime.init` 默认 | per runtime;`nonisolated deinit` | n/a | injected closure(tick 回调) | — | unchanged | ✓ |
| `PendingPermission`/`SlashCommand`/`TurnEndedNotice`/`PermissionPromptNotice`/`BackgroundTask`/`TodoEntry` | Pure-value | value/MDL | runtime 突变点 | runtime 持数组 | n/a | none | — | unchanged | ✓ |

**Session infra(`Services/Session/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SessionManager` | App-scope-service | @Observable-SVC | `AppState.init` | `AppState.sessionManager` / process | ctor-injected(repository、cliClientFactory);@Observable(`records`) | injected closure(record 变更 push);@Observable write | — | unchanged | ✓ |
| `SessionRepository`(protocol) | App-scope-service | @Observable-SVC(proto) | n/a | 注入 `SessionManager`/`Session` | n/a | n/a | — | unchanged | ✓ |
| `CoreDataSessionRepository` | App-scope-service | @Observable-SVC | `SessionManager.init` 默认(`CoreDataStack.shared`) | process;`nonisolated deinit` | ctor-injected(CoreDataStack) | none(持久) | — | unchanged | ✓ |
| `InMemorySessionRepository`(DEBUG) | App-scope-service | @Observable-SVC | test fixtures | test 生命期;`nonisolated deinit` | inline | none | — | unchanged | ✓ |
| `SessionExtraUpdate` | Pure-value | value/MDL | repository callers | transient | n/a | none | — | unchanged | ✓ |
| `SessionRecord`/`SessionStatus`/`SessionExtra` | Pure-value | value/MDL | repository / decode | repository 行 | n/a | none | — | unchanged | ✓ |
| `HistoryLoader`(`nonisolated static` 命名空间) | Per-load | translator | n/a(static) | stateless | n/a | none(返回 `[Message2]`/URL) | — | unchanged | ✓ |
| `TitleGenerator`(`enum`,static one-shot) | App-scope-service | translator | n/a(static) | stateless;可注入 `runner` seam | n/a | none(返回 title/branch) | — | unchanged | ✓ |
| `CLIClient`(protocol) | App-scope-service | @Observable-SVC(proto) | factory-injected | per runtime | n/a | injected closure(event 回调) | — | unchanged | ✓ |
| `CLIClientFactory`(typealias) | Pure-value | value/MDL | `AppState`/`SessionManager` | process | n/a | none | — | unchanged | ✓ |
| `AgentSDKCLIClient` | App-scope-service | @Observable-SVC | `AgentSDKCLIClient.defaultFactory` | per runtime;`nonisolated deinit` | 包 `AgentSDK.Session` | injected closure(event 回调) | — | unchanged | ✓ |
| `FakeCLIClient`(DEBUG/test) | App-scope-service | @Observable-SVC | test factory | test 生命期;`nonisolated deinit` | inline | injected closure | — | unchanged | ✓ |
| `WorktreeProvisioner`(`enum`,离主 `git worktree add`) | App-scope-service | translator | n/a(static) | stateless;可注入 `creator` seam | n/a | none(返回 `Result`) | — | unchanged | ✓ |
| `Worktree`(+`+Lifecycle`/`+Internals`/`GitQuery`) | Pure-value | value/MDL | `WorktreeProvisioner`/git probes | transient | n/a | none | — | unchanged | ✓ |

**App services(`Services/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SyntaxHighlightEngine` | App-scope-service | actor-SVC | `AppState` stored-prop init | `AppState.syntaxEngine` / process | n/a | none(返回 token;LRU) | — | PR2(注入点改名 `searchEngine→syntaxEngine`;类型不变) | ✓(target)。as-is ✗:跨 5 VC 以误名 `searchEngine` 穿线(P10b);纯改名修 |
| `RecentProjectsStore` | App-scope-service | @Observable-SVC | `AppState`(lazy) | `AppState.recentProjects` / process;`nonisolated deinit` | @Observable pull | @Observable write | — | unchanged | ✓ |
| `InputDraftStore` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.inputDraftStore` / process;`nonisolated deinit` | @Observable pull | @Observable write;imperative `clear`(发送时,防拆除 I12) | — | unchanged | ✓ |
| `InputDraft` | Pure-value | value/MDL | `InputDraftStore` | store 持(Codable) | n/a | none | — | unchanged | ✓ |
| `SidebarSessionGroupOrderStore` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.sidebarGroupOrder` / process | ctor-injected(UserDefaults) | none(持久) | — | unchanged | ✓ |
| `AppActivationTracker` | App-scope-service | @Observable-SVC | `AppState.init`(notifications 前) | `AppState.activationTracker` / process;`nonisolated deinit` | @Observable pull | @Observable write | — | unchanged | ✓(NotificationService 私有依赖;无他读者,刻意) |
| `NotificationService` | App-scope-service | @Observable-SVC(NSObject) | `AppState.init`(`NotificationService(activation:)`) | `AppState.notificationService` / process;`nonisolated deinit` | ctor-injected(activationTracker) | injected closure(`onActivateSession` push) | — | PR1(删死注入,no-op) | ✓(target)。as-is ✗:每 detail-VC host 死 `.environment(notifications)`(0 SwiftUI reader,P1);仅经 AppKit push 触达 |
| `OpenInAppService` | App-scope-service | @Observable-SVC | `AppState` init | `AppState.openInService` / process | @Observable pull | imperative(启外部 app) | — | unchanged | ✓ |
| `ModelStore` | App-scope-service | @Observable-SVC | `ModelStore.shared`(static) | process singleton | @Observable pull(views 经 `.shared`) | @Observable write;spawn CLI 子进程 | — | unchanged(留 `.shared`,§11) | ✓ ⟨D1:刻意保留的 `.shared`(spawn CLI 子进程,per-process 缓存),文档化例外 —— 单所有者 = `.shared` static,通道清晰⟩ |
| `EffortDefaultStore` | App-scope-service | @Observable-SVC | `EffortDefaultStore.shared`(static) | process singleton | `.shared` from views | @Observable write(UserDefaults) | — | PR8(可选折叠进 AppState;否则 unchanged) | ✓ ⟨D1:薄 UserDefaults 包装,`.shared` 文档化例外;低风险可选折叠⟩ |
| `NewSessionDefaultsStore` | App-scope-service | @Observable-SVC | `NewSessionDefaultsStore.shared`(static) | process singleton | `.shared` from views | @Observable write(UserDefaults) | — | PR8(可选折叠进 AppState;否则 unchanged) | ✓ ⟨D1:同 EffortDefaultStore⟩ |
| `FileCompletionStore`(重列见 §3.4) | App-scope-service | @Observable-SVC(singleton) | `.shared` static | process | n/a | callback | — | PR3(删 `invalidate*` 死方法) | ✓ ⟨D1:per-process 缓存,文档化 `.shared` 例外;PR3 删死方法,store 保留⟩ |
| `SlashCommandStore`(重列见 §3.4) | App-scope-service | @Observable-SVC(singleton) | `.shared` static | process | n/a | callback | — | unchanged | ✓ ⟨D1:per-process 缓存,文档化 `.shared` 例外⟩ |
| `GitProbe`(重列见 §3.4) | View-scope-state | @Observable-SVC | SwiftUI `@State`(compose / draft-landing) | view identity | @Observable pull | @Observable write | — | PR12(加 `@MainActor`,P15) | ✓(target;view 私有状态机)。as-is ✗:缺 `@MainActor` 分层 nit |
| `ClaudeCodeStats`(`enum`) | —(死) | value/MDL | n/a | none —— **无生产消费者** | n/a | none | — | PR3(DELETE)~460 行 + 测试 | ✗ DEAD:全测但零生产消费者(P13);仅可"删"落位。设计缺陷 = 它存在 → PR3 删后行消失 |
| `CoreDataStack` | App-scope-service | @Observable-SVC(NSObject-ish) | `CoreDataStack.shared`(static) | process singleton;`nonisolated deinit` | n/a | none(持久容器) | — | unchanged | ✓(合法单一 Core Data 容器) |

**Models(`Models/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `SyntaxToken` | Pure-value | value/MDL | `SyntaxHighlightEngine` | transient | n/a | none | — | unchanged | ✓ |
| `TurnTokenUsage` | Pure-value | value/MDL | `StreamingTurnAssembler`/runtime | transient | n/a | none | — | unchanged | ✓ |
| `PermissionMode`(enum) | Pure-value | value/MDL | config / pickers | inline | n/a | none | — | unchanged | ✓ |
| `SendKeyBehavior`(enum) | Pure-value | value/MDL | settings | inline | n/a | none | — | unchanged | ✓ |
| `StreamPacer` | Renderer-internal | value/MDL | streaming 路径 | transient | n/a | none | — | unchanged | ✓ |
| `LanguageDetection`(enum) | Pure-value | translator | n/a(static) | stateless | n/a | none | — | unchanged | ✓ |
| `ANSIAttributedBuilder`(enum) | View-scope-state | translator | n/a(static) | stateless | n/a | none | — | PR12(移出 `Models/`,P15) | ✓(target)。as-is ✗:view 层关注却归 `Models/`(定义为"plain data") |
| `SyntaxTheme`(enum) | View-scope-state | value/MDL | n/a(static) | stateless | n/a | none | — | PR12(移出 `Models/`) | ✓(target)。as-is ✗:view(颜色)关注归 `Models/` |
| `PermissionMode+Color`(ext) | View-scope-state | value/MDL | n/a(ext) | stateless | n/a | none | — | PR12(移出 `Models/`) | ✓(target)。as-is ✗:view(颜色)关注归 `Models/` |
| `Effort+Display`(ext) | View-scope-state | value/MDL | n/a(ext on `AgentSDK.Effort`) | stateless | n/a | none | — | PR12(移出 `Models/`) | ✓(target)。as-is ✗:view(显示)关注归 `Models/` |

**Markdown IR(`Components/Markdown/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `MarkdownDocument`(public,Sendable) | Pure-value | value/MDL | `MarkdownConvert` | `MessageEntryBlockBuilder` 消费 | n/a | none | — | unchanged | ✓(纯,离主安全 IR —— 载重干净 seam,§5 PRESERVE) |
| `MarkdownConvert`(`nonisolated enum`) | Pure-value | translator | n/a(static,nonisolated) | stateless | n/a | none | — | unchanged | ✓ |
| `MarkdownTypes`(`MarkdownSegment`/`Block`/`List`/`ListItem`/`Inline`/`CodeBlock`/`Table`,public Sendable) | Pure-value | value/MDL | parser | `MarkdownDocument` 内 | n/a | none | — | unchanged | ✓ |
| `MarkdownAutolink`(enum) | Pure-value | translator | n/a(static) | stateless | n/a | none | — | unchanged | ✓ |
| `MarkdownMath`(enum) | Pure-value | translator | n/a(static) | stateless | n/a | none | — | unchanged | ✓ |

### 3.6 Transcript renderer + bridge(`NativeTranscript2/` + `NativeTranscript2Bridge/`)

> **整节在不可触碰墙之后**(DNT-1/2/3/4)。方案明言"无任何一步进入渲染器内部"。故每行
> `unchanged`,仅两类保行为例外:两个 sheet body(regime D)与 `StableBlockID` 跨文件常量抽取
> (PR3,逻辑不变,snapshot 守卫)。

**Host-VC facing — controller / coordinator / 兄弟 / sheet presenter**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Transcript2Controller` | Session-core | @Observable-SVC | `Session.init`(`Session.swift:166`) | `Session`(session 生命期;跨挂载存活) | ctor-injected / @Observable pull by hosts | imperative controller call(`coordinator.apply`);@Observable write(`blockCount`/`searchState`/`pendingUserBubbleSheet`/`pendingImagePreview`/`loadingPillVisible`) | — | unchanged | ✓ |
| `Transcript2Coordinator` | Renderer-internal | AK-NSObject | `Transcript2Controller`(init) | Controller(session 生命期) | ctor-injected(controller、syntaxEngine 经 `attachSyntaxEngine`) | imperative controller call(`NSTableView` insert/remove/reloadData);injected closure(`onBlockCountChanged`/`onUserBubbleSheetRequested`/`onLayoutWidthDidSettle`) | — | unchanged | ✓ |
| `Transcript2SelectionCoordinator` | Renderer-internal | AK-NSObject | `Transcript2Coordinator`(init) | Coordinator(session 生命期) | ctor-injected(读 `layout.selectionAdapter` per query) | imperative controller call(`markCellSearchDirty`/cell repaint) | — | unchanged | ✓ |
| `Transcript2SearchCoordinator` | Renderer-internal | AK-NSObject | `Transcript2Coordinator`(init) | Coordinator(session 生命期) | ctor-injected(读 `blockIds` + `selectionAdapter.searchableRegions`) | imperative controller call(`markCellSearchDirty`/`expandForSearchHit`/`scrollBlockIntoView`);injected closure(`onStateChanged`) | — | unchanged | ✓ |
| `Transcript2HighlightStorage` | Renderer-internal | @Observable-SVC | `Transcript2Coordinator`(init) | Coordinator(session 生命期) | ctor-injected(syntaxEngine `highlightBatch`) | injected closure(`onDidFill(blockId)` → `reloadData(forRowIndexes:)`) | — | unchanged | ✓ |
| `Transcript2SheetPresenter` | Per-attach | AK-NSObject | `ChatSessionViewController.attachSession`(`:405`) | Chat VC(per-attach;每 session attach 重建;demo VC 持终生) | @Observable pull(`withObservationTracking` on `controller.pendingUserBubbleSheet`/`pendingImagePreview`) | imperative controller call(`view.window?.beginSheet`) | D(sheet host 包 SwiftUI body) | unchanged(构造点被 PR13 触动,presenter 类本身不变) | ✓ |

**AppKit table shell + cell(self-drawn)+ factory**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `TranscriptScrollViewFactory` | Per-attach | translator | n/a(caseless `enum`;static `make`/`bindData`/`dismantle`) | none(无状态工厂) | n/a | imperative controller call(建/绑 scroll·clip·table 壳) | — | unchanged | ✓ |
| `Transcript2ScrollView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | Chat VC / swap(per-attach) | n/a | none(`.never` layer + responsive,§2.3) | — | unchanged | ✓ |
| `Transcript2ClipView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | 外层 scroll(per-attach) | n/a | imperative controller call(`scroll(to:)` + `reflectScrolledClipView`) | — | unchanged | ✓ |
| `Transcript2TableView` | Renderer-internal | AK-View | `TranscriptScrollViewFactory.make` | 外层 scroll(per-attach) | ctor-injected(dataSource/delegate = Coordinator) | imperative controller call(负宽 clamp,§2.9) | — | unchanged | ✓ |
| `BlockCellView` | Renderer-internal | AK-View | `NSTableView` `makeView`(复用) | table(row 复用) | ctor-injected(`RowLayout` + `SubviewPlan` per `viewFor`) | injected closure(`SubviewPlan` entry 闭包);imperative controller call(`requestUserBubbleSheet`、fold/link hit) | — | unchanged | ✓ |
| `BlockCellView+SubviewPlan`(ext + `ToolGroupEntryView`、`ShimmerLayerSet`) | Renderer-internal | AK-View | `BlockCellView` 调和器 | `BlockCellView`(cell 生命期子层) | ctor-injected(当前 `SubviewPlan`) | imperative controller call(CALayer/subview 调和) | — | unchanged | ✓ |
| `BlockCellView+Gutter`(ext) | Renderer-internal | AK-View | n/a(绘图扩展) | `BlockCellView` | n/a | none(self-draw) | — | unchanged | ✓ |
| `CenteredRowView` | Renderer-internal | AK-View | `NSTableView` `rowViewForRow`(`"BlockRow"` 复用 key) | table(row 复用) | n/a | none(no-op row view;§2.17) | — | unchanged | ✓ |
| `LoadingPillUsageView` | Renderer-internal | AK-View | `BlockCellView` subview-plan 调和器 | `BlockCellView`(cell 生命期) | ctor-injected(`apply(spec:)`;持 1 Hz timer + `StreamPacer`) | none(self-draw elapsed clock + token odometer) | — | unchanged | ✓(纯 `NSView`,**非** SwiftUI —— "唯一 SwiftUI 叶"是 doc drift,源为 `final class … : NSView`) |

**Layout 值类型(`Layout/`)** —— 全部不可变值/caseless enum;`nonisolated static makeLayout` 纯度载重;无 host 边界。**全部 `unchanged` ✓ ·Pure-value · Host —**:
`RowLayout`(+`InteractiveHit`/`HitAction`)、`TextLayout`、`ImageLayout`、`ListLayout`、`TableLayout`、`UserBubbleLayout`、`UserAttachmentsLayout`、`CodeBlockLayout`、`CopyChrome`、`BlockquoteLayout`、`ThematicBreakLayout`、`LoadingPillLayout`、`ToolGroupLayout`、`ToolGroupChildLayout`(+`Kind`)、`ToolGroupChildHighlight`(translator)、`TextCardSection`、`SelectionAdapter`(+`LayoutPosition`/`SelectionRange`/`SearchableRegion`)、`SubviewPlan`(+`Chevron`/`Shimmer`/`LoadingDots`/`UsageCounter`/`Entry`)、`GutterSpec`。
其中 `UserBubbleLayout`/`UserAttachmentsLayout` 经 cell 命中 → `imperative controller call`;`SelectionAdapter`/`SubviewPlan` 经 `injected closure`;其余 `none`。

**Tool-group child payload + layout(`Layout/ToolGroupChildren/<Kind>/`)** —— 10 种,每种 payload `struct` + `XxxChildLayout` 值类型(+ 可选 `XxxChildHighlight` translator)。**全部 `unchanged` ✓ · Pure-value(`…Highlight` 为 translator)· `ctor-injected` · Host —**:
`FileEditChild`/`FileEditChildLayout`/`FileEditChildHighlight`/`DiffBlock`/`DiffLayout`、`ReadChild`/`…Layout`/`…Highlight`、`BashChild`/`…Layout`/`…Highlight`、`GrepChild`/`…Layout`、`GlobChild`/`…Layout`、`WebFetchChild`/`…Layout`、`WebSearchChild`/`…Layout`、`AskUserQuestionChild`/`…Layout`、`AgentChild`/`…Layout`、`GenericChild`/`…Layout`。

**Model 值类型(`Model/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Block`(+`Block.Kind`/`ToolGroupBlock`/`Block.Child`/`ToolStatus`/`ListBlock`) | Pure-value | value/MDL | bridge(`MessageEntryBlockBuilder`/`MarkdownToBlocks`)+ pipeline | `Coordinator.blocks: [Block]`(单一真源,§3.1) | n/a | none(`id: UUID` 驱身份,§2.18) | — | unchanged | ✓ |
| `InlineNode` | Pure-value | value/MDL | 上游 Markdown parser | `Block.Kind` 内 | n/a | none(递归 inline IR) | — | unchanged | ✓ |

**SwiftUI sheet body(`Sheets/`)— 本节唯一 host 边界**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `UserBubbleSheetView` | SwiftUI-view | SU-View | `Transcript2SheetPresenter` 经 `NSHostingController` in `beginSheet` | sheet(模态生命期) | ctor-injected(request 值) | injected closure(Done dismiss) | D(模态 sheet host) | unchanged | ✓ |
| `ImagePreviewSheetView` | SwiftUI-view | SU-View | `Transcript2SheetPresenter` 经 `NSHostingController` in `beginSheet` | sheet(模态生命期) | ctor-injected(request 值) | injected closure(Done dismiss) | D(模态 sheet host) | unchanged | ✓ |

**Bridge — entry→Block 翻译(`NativeTranscript2Bridge/`)**

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `Transcript2EntryBridge` | Session-core | translator | `Session.init`(`Session.swift:167`) | `Session`(session 生命期;init/promotion 接线一次) | closure sink(`onMessagesChange` → `bridge.apply`) | imperative controller call(`controller.apply(change)`) | — | unchanged | ✓ |
| `TranscriptBackfillPipeline` | Per-load | translator | `Session.loadHistory()`(`Session.swift:551`) | `Session`(单冷载;旁路 bridge) | ctor-injected(reverse page source + controller + width) | imperative controller call(`controller.apply` `.append`/`.prepend` with `precomputed:`) | — | unchanged | ✓ |
| `MessageEntryBlockBuilder` | Per-load | translator | bridge + pipeline(caseless `enum`) | none(无状态) | ctor-injected | none(`MessageEntry` → `[Block]`) | — | unchanged | ✓ |
| `ToolUseToChild` | Per-load | translator | builder(caseless `enum`) | none(无状态) | ctor-injected | none(`ToolUse`/`ToolResult` → `Block.Child`) | — | unchanged | ✓ |
| `MarkdownToBlocks` | Per-load | translator | builder(caseless `enum`) | none(无状态) | ctor-injected | none(markdown IR → `[Block]`) | — | unchanged | ✓ |
| `StreamingMarkdownCommit` | Per-load | translator | bridge(caseless `enum`) | none(无状态) | ctor-injected | none(增量 streamed-markdown commit) | — | unchanged | ✓ |
| `StableBlockID` | Pure-value | translator | bridge/builder(caseless `enum`) | none(无状态确定 id 派生) | ctor-injected | none(消息坐标 → 稳定 `UUID`) | — | PR3(const only)—— P14 跨文件常量抽取,保行为,snapshot 守卫 | ✓ |
| `JSONLReversePageSource` | Per-load | actor-SVC | `TranscriptBackfillPipeline` | pipeline(单冷载) | ctor-injected(file URL) | closure sink(yield reverse pages) | — | unchanged | ✓(`@unchecked Sendable`) |
| `ReverseLineReader` | Per-load | translator | `JSONLReversePageSource` | reverse page source | ctor-injected(file handle) | none(reverse line 迭代) | — | unchanged | ✓ |
| `PipelineInbox` | Per-load | translator | `TranscriptBackfillPipeline` | pipeline(单冷载) | ctor-injected | closure sink(main-owned 预建页缓冲) | — | unchanged | ✓(`@unchecked Sendable`) |

### 3.7 DEBUG 演示(`Content/TranscriptDemo/*` · `Content/PermissionDemo/*`)— 补行(审查 C1/C2)

> spec §1 把"demo VCs"列于 Detail-child-VC 层,router 在 DEBUG 挂它们;PR5 的 M3 子任务**迁移**
> `PermissionSessionDemoViewController`。下列行使 PR5 的"每非-unchanged 行被恰一 PR 认领"可证。
> 全部 ✓。

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `TranscriptDemoViewController`(DEBUG) | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(DEBUG `.demo`) | router;DEBUG 演示 | ctor-injected(demo 固定数据) | imperative controller call(`controller.apply`) | A(填满-pane host) | unchanged | ✓ |
| `TranscriptPerfDemoViewController`(DEBUG) | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(DEBUG) | router;DEBUG 演示 | ctor-injected | imperative controller call | A(填满-pane host) | unchanged | ✓ |
| `TranscriptStressViewController`(DEBUG) | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(DEBUG) | router;DEBUG 演示 | `@Observable pull`(`TranscriptStressStatusModel`) | imperative controller call(`controller.apply` 压测) | A(填满-pane host) | unchanged | ✓ |
| `PermissionSessionDemoViewController`(DEBUG) | Detail-child-VC | AK-VC | `DetailRouterViewController.makeChild`(DEBUG) | router;DEBUG 演示 | `@Observable pull`(`ControlPanelState`) | imperative controller call(模拟 permission prompt) | A 尺寸(legacy 手卷 `sizingOptions=[]` + PreferenceKey,BOUNDARY-SPEC §3 反模式) | PR5(★CHANGED M3:迁移以挂权限卡 overlay,否则 demo 静默坏) | ✓(PR5 后挂 overlay;迁移前为 legacy 手卷 host) |
| `TranscriptStressStatusModel`(DEBUG) | View-scope-state | @Observable-SVC | `TranscriptStressViewController`(`@State`/持有) | view identity | n/a(压测状态) | `@Observable write` | — | unchanged | ✓(Rule-5 view 私有状态机,如 `GitProbe`;`@MainActor`) |
| `ControlPanelState`(DEBUG) | View-scope-state | @Observable-SVC | `PermissionSessionDemoViewController`(持有) | view identity | n/a(控制面板状态) | `@Observable write` | — | unchanged | ✓(Rule-5 view 私有状态机;`@MainActor`) |

### 3.8 非符合(✗)汇总 callout —— 每项 + 修复 PR

> 经审查修订后,**生产树无停留 ✗ 的可放置类**。下表是 as-is `✗ → ✓`(由映射 PR 翻转)与唯一的
> *声明性* ✗(不引入)的统一登记。

| ✗ 实体 | 缺陷一句话 | 修复 PR | 修复后 |
|---|---|---|---|
| `BackgroundTaskButton` | `stopAction` 穿 `Session` façade 调 `runtime.markTaskStoppedLocally`(唯一生产单向流违规,P4) | **PR4** | ✓ 经 `session.stopBackgroundTask` |
| `ChatRestingBar` | 卡片 ZStack union 高泵 `[.intrinsicContentSize]` bar host(头号体验缺陷,§7.1) | **PR5** | ✓ 卡片移至 overlay,bar 退回"just the bar" |
| `SyntaxHighlightEngine` | 跨 5 VC 以误名 `searchEngine` 穿线(P10b) | **PR2** | ✓ 改名 `syntaxEngine` |
| `NotificationService` | 每 detail host 死 `.environment(notifications)`(0 SwiftUI reader,P1) | **PR1** | ✓ 删死注入,纯 push 服务 |
| `ClaudeCodeStats` | ~460 行全测但零生产消费者(P13) | **PR3** | ✓ 删除(行消失) |
| `FileCompletionStore.invalidate*` | 死方法,0 caller,FSEvent 流泄漏(P13) | **PR3** | ✓ 删方法,store 保留 |
| `DirectoryCompletionItem`/`Provider`/`DirectoryTreeMonitor` | 0 构造点的死 dir-completion 接线(C14) | **PR3** | ✓ 删除 |
| `GitProbe` | `@Observable` 缺 `@MainActor`(peer 皆有,P15) | **PR12** | ✓ 加 `@MainActor` |
| `ANSIAttributedBuilder`/`SyntaxTheme`/`PermissionMode+Color`/`Effort+Display` | view 层关注误归 `Models/`(定义为 plain data,P15) | **PR12** | ✓ 移出 `Models/`(synced-group,无 pbxproj 编辑) |
| `SidebarViewController` | ~770 行 god-VC,7 责任(凝聚度缺陷) | **PR9 + PR10** | ✓ 抽 `SidebarTreeModel` + `SidebarContextMenuController`,瘦 VC |
| `CrossfadeController`(提议 P6) | 所有者不明(router 跨类 vs chat 同 session crossfade 分歧;不得拥 chat-I5 pre-flush) | **不引入** | ✗ 声明性缺陷 —— 抽象本身是缺陷,拒绝;保留两份副本("重复比风险便宜") |
| `ModelStore` / `SlashCommandStore` / `FileCompletionStore` / `EffortDefaultStore` / `NewSessionDefaultsStore` | (审查 D1)曾计 ✗ + unchanged —— 与消费者计 ✓ 矛盾 | **已统一为 ✓ + `.shared` 理由**(spec §11 批准的刻意保留;两 UserDefaults 包装可选折叠 PR8) | ✓ |

---

## 4. 多-PR 执行计划

> 把整个重构重构为**有序、各自独立可发布的 PR**。每个 PR 是稳定 id、编译、过 `make test-unit`、
> 应用保持绿色,合并后其触及的每行在 spec §2.6 下 **Conformant ✓**。无 PR 弱化不可触碰契约。
> 这是 REFACTOR-PLAN **§9 迁移(4 阶段 / 13 步)** 的规范实现:13 步 1:1 映射 **PR1–PR13**。
> 风险梯度:机械/死代码/改名先(PR1–PR4)→ 头号卡片 overlay 早且自包含(PR5)→ 边界卫生 + DI
> 合并(PR6–PR8)→ god-object 拆分(PR9–PR12)→ transcript-swap 抽取 + runtime 投影**垫底**,
> 在两个 reentry-layout 合并门后(PR12–PR13)。

### 4.1 Per-PR 汇总表

| PR | 标题 | Phase | 风险 | 依赖 | 头号 行(创建/改变) |
|---|---|---|---|---|---|
| PR1 | 删死 `.environment` 注入 | A | trivial | — | `NotificationService`、`TranscriptSearchBus`、`DetailRouterViewController`、5 detail-VC host |
| PR2 | 改名 `searchEngine`→`syntaxEngine` | A | trivial | — | `SyntaxHighlightEngine`、`DetailRouterViewController`、`MainSplitViewController` |
| PR3 | 删死代码 + 抽 `StableBlockID` 常量 | A | low | — | `DirectoryCompletionItem/Provider`、`DirectoryTreeMonitor`、`ClaudeCodeStats`、`FileCompletionStore`(方法)、`CompletionListView`、`StableBlockID` |
| PR4 | `Session.stopBackgroundTask(taskId:)` façade 转发 | A | low | — | `Session`(+方法)、`BackgroundTaskButton` |
| PR5 | 权限卡片浮层(头号修复) | B | medium | PR4(soft) | `PermissionCardOverlay`、`permissionCardHost`、`PassthroughHostingView`、`ChatRestingBar`、`PermissionCardView`、`ChatSessionViewController`(loadView)、`PermissionSessionDemoViewController`(M3) |
| PR6 | `mountFillPaneHost` helper + un-erase `AnyView` | B | low-med | PR5 | `mountFillPaneHost`、`Compose/DraftLanding/ArchiveViewController`(+视图)、`restingBarHost`(un-erase 腿) |
| PR7 | `DetailContext` + `injectDetailEnvironment` | B | low-med | PR1, PR2, PR6 | `DetailContext`、`injectDetailEnvironment`、`MainSplitViewController`、`DetailRouterViewController`、4 detail VC、`SidebarContext` |
| PR8 | 命名 + 文档收尾 | B | trivial | PR5, PR6, PR7 | `restingBarHost`(rename 腿)、`CompletionState`(+`.CompletionSession`)、doc drift;可选 AppState 折叠 `searchBus`/UserDefaults 包装 |
| PR9 | 抽 `SidebarTreeModel`(纯) | C | medium | — | `SidebarTreeModel`、`SidebarItemNode`、`SidebarViewController`(tree-build 抽出) |
| PR10 | 抽 `SidebarContextMenuController` + 瘦 VC | C | medium | PR9 | `SidebarContextMenuController`、`SidebarViewController`(瘦) |
| PR11 | Grouping 去重(缩水/可选) | C | medium | — | `SessionRuntime+Receive`、`ReverseEntryBuilder`(谓词已共享 —— 可能 no-op) |
| PR12 | `SessionRuntime` 投影 + 分层 nit | C/D | med-high | PR4(soft) | `TodoTracker`、`TaskTracker`、`ContextUsageCache`、`SessionRuntime+{Todos,Tasks,ContextUsage}`、`GitProbe`、`ANSIAttributedBuilder`/`SyntaxTheme`/`PermissionMode+Color`/`Effort+Display` |
| PR13 | 抽 `TranscriptSwapCoordinator` | D | high | PR5(loadView), PR12(投影) | `TranscriptSwapCoordinator`、`transcriptScroll`、`transcriptSheetPresenter`、`ChatSessionViewController`(脱 swap 状态机) |

### 4.2 依赖图

```
PR1 ─┐
PR2 ─┼─────────────► PR7 ──► PR8
PR6 ─┘   ▲                    ▲
PR5 ─────┘ (PR5→PR6)          │ (PR5,PR6,PR7 → PR8)
PR4 ┄(soft)► PR5
PR4 ┄(soft)► PR12
PR9 ──► PR10
PR11 (independent)
PR5 ─┐
PR12 ┴──► PR13
```

实线 = 硬依赖(编译/seam 顺序);┄ = 软排序(同阶段/不变量先行)。
PR3、PR9/PR10、PR11 与 Phase B 正交。

### 4.3 Per-PR 详情(scope · 行 · 依赖 · 风险 · 门 · 回滚)

**PR1 — 删死 `.environment` 注入。** 删 5 个 host 点的 `.environment(notifications)`/`.environment(searchBus)`(grep 确认 0 SwiftUI reader)。router 仍*持* `notifications` 供 AppKit `onActivateSession` push;只删 SwiftUI 注入边。**行:** `NotificationService`(→ 纯 push 服务 ✓)、`TranscriptSearchBus`、`DetailRouterViewController`、5 detail-VC host。**门:** 全 `make test-unit`;`DetailRouterContainmentTests`、`DetailRouterDraftRoutingTests`;手动 smoke(通知激活仍路由;⌘F 仍聚焦)。**回滚:** `git revert`(恢复死注入,行为同)。

**PR2 — 改名 `searchEngine`→`syntaxEngine`。** 编译器守卫的端到端改名,跨 `MainSplitViewController`、`DetailRouterViewController`(×4)与 detail VC。类型不变,通道名纠正。**行:** `SyntaxHighlightEngine`(✗→✓)、`DetailRouterViewController`、`MainSplitViewController`。**门:** 编译 + 全 `make test-unit`。**回滚:** `git revert`。

**PR3 — 删死代码 + 抽 `StableBlockID` 常量。** 保行为删除:(a) 永不触发的 dir-completion 接线(`DirectoryCompletionItem`/`Provider`/`DirectoryTreeMonitor` + live-but-never-firing 的 recent-dir 分支);(b) `ClaudeCodeStats`(~460 行,0 生产消费者)及其测试;(c) `FileCompletionStore.invalidate*`(0 caller,FSEvent 泄漏)。加 `StableBlockID` 跨文件常量抽取(P14,逻辑无变,snapshot 守卫)。**行:** 见汇总表。**门:** `CustomCommandTests`、`CompletionListSnapshotTests`(live-file 守卫);transcript snapshot 守卫 `StableBlockID`;全 `make test-unit`。**不进入渲染器内部(DNT-1)。** **回滚:** `git revert`。

**PR4 — `Session.stopBackgroundTask(taskId:)` façade 转发。** 加 phase-aware `Session.stopBackgroundTask(taskId:) -> Void` 转发(`guard let runtime` idiom;`.draft` no-op;返回 `Void` 不重泄 `Bool`)。`BackgroundTaskButton.stopAction` 改调它而非 `session.runtime.markTaskStoppedLocally`(闭合唯一生产单向流违规,P4)。**行:** `Session`(+方法)、`BackgroundTaskButton`(✗→✓)。**门:** `SessionRuntimeTasksTests` + 新 `SessionFacadeTests`(断言转发经 runtime 且 `.draft` no-op)。**无 test-only seam**(加固生产不变量)。**回滚:** `git revert`。

**PR5 — 权限卡片浮层(头号体验修复)。** 加 VC-resident 兄弟 host `permissionCardHost: PassthroughHostingView<PermissionCardOverlay>` 至 `loadView`,在 `restingBarHost` **之后**保 z-序(M5)。用 **regime-A 尺寸 + 穿透 hit-test**:`sizingOptions = []` + 四边 pin(发布零 `fittingSize` → 不压窗)叠 `PassthroughHostingView`(`hitTest→nil` 卡外 + 抑制 cursor/tracking rect,M2/M4)。`PermissionCardOverlay` 读 `session.pendingPermissions.first`(由 `model.selection` + `.id(sid)` 路由,R4),底 inset 36(M1),4 决策闭包 → `session.respond(...)`(从 `ChatRestingBar` **逐字**移)。`ChatRestingBar` 退回"just the bar"。重引入 `PassthroughHostingView`(今仅墓碑注释 —— 重加,勿复用旧)。**迁移 `PermissionSessionDemoViewController` 挂 overlay(M3 —— 显式 DEBUG 子任务,否则 demo 静默坏)。** **行:** `PermissionCardOverlay`(★NEW)、`permissionCardHost`(★NEW)、`PassthroughHostingView`(★NEW)、`ChatRestingBar`(★CHANGED)、`PermissionCardView`(★MOVED)、`ChatSessionViewController`(loadView)、`PermissionSessionDemoViewController`(§3.7 行)。**门:** `PermissionCardWiringTests`(★UPDATED —— 文件已存在,从 3-button 改 4-closure overlay 路由;断言每决策正确达 `session.respond`,捕错位 allowOnce/allowAlways、丢失 `onAllowWithInput.updatedInput`);`PermissionCardSnapshotTests`(更新渲 `PermissionCardOverlay`;M1=36 后像素相等);`ChatComposeStackRoutingTests`;`DetailPaneTranscriptHitTestTests`(★UPDATED —— 文件已存在;真 `hitTest` + `.leftMouseDown` 守 M4/M5 穿透,host 必须不遮 transcript I-beam)。BOUNDARY 合并门保绿。**Conformant ✓ 要求 A-hybrid 按 regime A 归档(非 B″),由 `DetailPaneTranscriptHitTestTests` 强制。** **回滚:** `git revert`(恢复 ZStack bar,重引头号缺陷但绿)。

**PR6 — `mountFillPaneHost` helper + un-erase `AnyView`。** 加 `mountFillPaneHost(_:in:)`(编码 regime A:`[]` + 四边 pin)并路由 3 个填满-pane VC(Archive/Compose/DraftLanding)。把 5 个 pane-host body 从 `AnyView` un-erase 为具体泛型 body(漏注入 → 编译错)。含 `restingBarHost` 的 un-erase 腿(regime-B chat bar **刻意不**折入 `mountFillPaneHost`,§10 rule 6)。**必须先于 PR7**(使 PR7 的 `injectDetailEnvironment` 落在编译错守卫后,§9 R1 step 6→7)。**行:** `mountFillPaneHost`(★NEW)、`Compose/DraftLanding/ArchiveViewController`(+视图,un-erased)、`restingBarHost`(un-erase 腿)。**门:** `AppKitSwiftUIBoundaryTests.*`(填满-pane 不压窗、绑定高度中性、制式治理 fittingSize、large-split 默认-sizing 压窗探针)、`DetailRouterLayoutDiagnosticsTests`(`fittingSize.height <= 1`)、`HostedComponentCenteringTests.*`、`ArchiveViewSnapshotTests`、`MainWindowAppKitSnapshotTests`。**Honors DNT-6**(chat bar 非对称保留)。**回滚:** `git revert`。

**PR7 — `DetailContext` + `injectDetailEnvironment`。** 用一个 `DetailContext` 值(model + 4 个*被消费*服务 `{SessionManager, RecentProjectsStore, InputDraftStore, syntaxEngine}`)整体经 `makeChild` 穿线,替 7-arg 扇出 + 5 份 `.environment` 块;一个 `View.injectDetailEnvironment(_:)` 修饰符。sidebar 同形:一个 `SidebarContext` 替 4-袋 init。**非**整体 AppState 注入(`model` 不在 AppState)。增删一 app-scope 依赖成一处编辑。**行:** `DetailContext`(★NEW)、`injectDetailEnvironment`(★NEW)、`MainSplitViewController`、`DetailRouterViewController`、4 detail VC、`SidebarViewController`/`SidebarContext`(★NEW)。**依赖:** PR1(死边没了)、PR2(`syntaxEngine` 名)、PR6(un-erase 落地 → 漏注入是编译错)。**门:** `DetailRouterContainmentTests`、`DetailRouterDraftRoutingTests`、`MainSelectionModelPromoteTests`;全 `make test-unit`。**回滚:** `git revert`。

**PR8 — 命名 + 文档收尾。** 纯改名 + doc-drift:`composeOrBarHost`→`restingBarHost`(rename 腿,约束/制式不变,H-2)、`CompletionViewModel`→`CompletionState`(+嵌套 `.CompletionSession`)、修根 `CLAUDE.md` "AppState via `.environment`" 陈旧、修 `RootView2` 跨 8 文件引用、修 `Content/Chat/CLAUDE.md` top-scrim base-name drift(`TranscriptScrimView`→`TranscriptTopScrimView`)。**可选**把薄 `searchBus`/UserDefaults 包装(`EffortDefaultStore`、`NewSessionDefaultsStore`)折叠进 `AppState`(低风险;`ModelStore` 留 `.shared`)。**行:** `restingBarHost`(rename 腿)、`CompletionState`(★RENAMED)、`TranscriptSearchBus`/`AppState`(可选折叠)、doc-only。**门:** 编译 + `make fmt-check`;全 `make test-unit`。**回滚:** `git revert`。

**PR9 — 抽 `SidebarTreeModel`(纯)。** 抽纯 `SidebarTreeModel.build(records, groupOrder, previouslySeenGroups) -> (nodes, newGroups)`。隐藏的 `lastSeenGroups` 缓存成**显式输入**,保 inv 6.10。首次树构建/grouping/new-folder 检测可单测。**行:** `SidebarTreeModel`(★NEW)、`SidebarItemNode`(移至 tree 输出;留引用类型作 `===` 身份)、`SidebarViewController`(tree-build 抽出)。**门:** 新 `SidebarTreeModelTests`(grouping/sort/recency + 显式缓存 inv 6.10)、`SidebarTitleSanitizerTests`、sidebar snapshot;全 `make test-unit`。**纯函数抽取;VC 仍喂同 nodes 给同 `reloadData()`(无细粒度 diff,DNT-8)。** **回滚:** `git revert`。

**PR10 — 抽 `SidebarContextMenuController` + 瘦 VC。** 抽 `SidebarContextMenuController`(`NSMenuDelegate` + 菜单动作:archive、"Open in"、copy-path、pasteboard 写)。VC 保 outline + 3 `withObservationTracking` loop + DnD + 选择。echo-suppression 守卫与 per-row obs re-arm 全保。**行:** `SidebarContextMenuController`(★NEW)、`SidebarViewController`(瘦,终态 ✓)。**依赖:** PR9。**门:** sidebar snapshot + 手动 DnD/menu smoke;全 `make test-unit`。`reloadData()` 身份键存活保留(DNT-8)。**回滚:** `git revert`。

**PR11 — Grouping 去重(缩水/可选)。** 核心谓词 `isGroupableAssistant` **已共享** 于 `SessionRuntime+Receive` 与 `ReverseEntryBuilder`;仅遍历方向按设计不同且有意保留。本 PR 析出任何*残余非谓词* grouping 规则;若无可有意义统一则**作 doc-only 纠正**(修陈旧的"bridge uses EntryGrouping"注解 —— 逻辑在 `SessionRuntime+Receive`,非 bridge)。**可能合法 no-op。** **行:** `SessionRuntime+Receive`(残余,可选)、`ReverseEntryBuilder`(可能 `unchanged`)。**门:** `TranscriptReverseBuilderTests`、`MessageEntryBlockBuilderTests`、bridge 测试;全 `make test-unit`。**不改 fire/order(DNT-3/4)。** **回滚:** `git revert`。

**PR12 — `SessionRuntime` 投影 + 分层 nit。** 抽 3 个自包含投影:`TodoTracker`、`TaskTracker`、`ContextUsageCache`。**`TurnUsageMeter` 明确排除**(骑 `publishTurnUsage` sink + `turnStartedAt` 排序,§11)。**observed-nesting 陷阱:** `tasks`/`todos`/`contextUsage` 是*被观察* `@Observable` 字段且有 live reader,故每 tracker MUST 为 `@Observable` 由 `@Observable`-tracked prop 持(嵌套变更必须传播 —— **非**值类型抽取)。runtime 留 `@Observable` 所有者 + 同步 `onMessagesChange` fire(I1)+ 不变 `receive` 序(I3)。`TaskTracker` 闭合 P4 环。加分层 nit(P15):`GitProbe` 加 `@MainActor`;`ANSIAttributedBuilder`/`SyntaxTheme`/`PermissionMode+Color`/`Effort+Display` 移出 `Models/`(synced-group,无 pbxproj)。所有新类型带 `nonisolated deinit {}`(C-6/DNT-5)。**行:** 见汇总。**依赖:** PR4(soft,façade 先闭合再迁存储,PR4→PR12 闭合 P4 对)。**门:** `SessionRuntimeTodosTests`、`SessionRuntimeTasksTests`、`ContextUsageTests` —— **必须断言 live re-render**(非仅终值)。**回滚:** `git revert`。

**PR13 — 抽 `TranscriptSwapCoordinator`(最高危,垫底)。** 把 transcript-swap 状态机从 `ChatSessionViewController` 抽至 `TranscriptSwapCoordinator`,**逐字方法体移**(无"顺手"简化):attach 编排、同 session crossfade、`fadingOutTranscript` parking、§2.19 单宽契约、chat-I3/I4/I5/I14、per-attach `transcriptScroll` + `transcriptSheetPresenter`。VC 保"显示什么"(scrim、bar host、focus、turn-usage、running-obs、首屏日志)。**Seam 契约(§8 P5 R6,四点必须全成立否则跨两所有者):** (i) z-anchor 留 `addSubview(scroll, .below topScrim)` —— scrim 由 VC 拥并传入;(ii) **`currentSession` 单一所有者** —— 一对象持,另一对象经它读,绝不重复(重复会 mid-crossfade desync,让 stale sink 在错 controller 上 `setTurnUsage`/`setLoading`);(iii) `applyScrimCutouts` 坐标变换在 scroll 迁移但 scrim/bar host 不迁时仍工作;(iv) 拆分线**穿过** `attachSession` 而非绕过。可选 `CrossfadeController`(P6)**默认不做** —— 声明性缺陷,绝不拥 chat-I5 `removeObserver` pre-flush;保两份副本。**PR13 须保 PR5 `permissionCardHost` 为第 4 兄弟,不把 transcript 重插于其上(M5)。** **行:** `TranscriptSwapCoordinator`(★NEW)、`transcriptScroll`(移入)、`transcriptSheetPresenter`(移入)、`ChatSessionViewController`(脱 swap → 终态 ✓)。**依赖:** PR5(card host 已是 loadView 兄弟)、PR12(投影安顿)。**门:** 两个合并门 `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`(前后各跑;若 host 测试转红,先读 xcresult 的 per-stage offender 报告 —— 被容忍的多宽写**就是** bug,绝不 `XCTSkip`/放宽);`DetailPaneTranscriptHitTestTests` 守真实 swap 中的 cursor-cutout/hit-test。**覆盖缺口(§9.1):** 同-session-crossfade finish-before-attach 序(`fadingOutTranscript`)是两门**未**覆盖的另一路径 —— 要么加测,要么接受 manual-only smoke(A→B→A→A 切换 + 原地 draft→active promotion + mid-transcript resize + 跨类切换;确认无白闪/首帧抖动/陈旧 scrollbar)。**回滚:** 整-PR `git revert`(逐字移,revert 精确恢复旧编排)。

### 4.4 一致性 & 契约说明

- **每个非-`unchanged` 行被恰一 PR 认领**(含 §3.7 DEBUG 行的 PR5 M3)。唯一未认领的 `★`/`✗` 实体是 `CrossfadeController` —— 声明性缺陷,刻意不引入,无行。
- **每个 PR 合并后,其触及行在 spec §2.6 下 ✓。**
- **无 PR 弱化不可触碰契约。** PR3/PR13 不进入渲染器内部(DNT-1);PR13 在两合并门后守 §2.19 + runloop 序(DNT-2/3);PR5/PR6 守 host 尺寸纪律 + BOUNDARY 合并门(绝不 `XCTSkip`,DNT-6);PR9/PR10 守 sidebar 6.1–6.12 + `reloadData()` 身份存活(DNT-7);PR12 在所有新类型带 `nonisolated deinit {}`(DNT-5)且排除 `TurnUsageMeter`/`Session` façade 合并(DNT-8)。

---

## 5. 对抗审查结论

**裁决:sound-with-fixes(健全,带修订)。** spec 真正显式、可机械检查;六片段几乎把每个有意义的
类以干净的单所有者/单通道归档;PR 计划是可信、序正确、独立可发布的序列,其 ✗ 行是真实 as-is
缺陷且映射到修复 PR。审查列出若干具体问题,**全部已在本最终文档落实修订:**

| 编号 | 问题 | 处置(本文档) |
|---|---|---|
| **D1**(must) | 5 个 `.shared` store 曾 `✗ + unchanged`,与 inputbar 片段对其消费者计 ✓ 矛盾;用户判据"末尾留 ✗ = 设计仍错" | **已解决** —— §3.5/§3.4 统一计 **✓ + 在格内带 `.shared` 理由**(spec §11 批准的刻意保留;两 UserDefaults 包装可选折叠 PR8)。§3.8 登记。 |
| **C1/C2**(should) | 4 个 DEBUG VC + 2 个 DEBUG `@Observable` helper 无行;PR5 的 `PermissionSessionDemoViewController` 迁移否则未认领 | **已解决** —— §3.7 新增 6 行(全 ✓),PR5 M3 认领其变更。 |
| **R1**(should) | 3 行写 `A-hybrid`,不在封闭 Host-regime 词表 `{A,B,B′,B″,C,D,E,—}` | **已解决** —— `permissionCardHost`/`PermissionCardOverlay` 行的 Host regime 格写 **`A`** + `⟨注 H-4⟩` 脚注;§2.4 H-4 解释 A 尺寸 + 穿透 hit-test。 |
| **S1**(minor) | spec:37 悬挂引用"§7 below"(spec 无 §7) | **已解决** —— §2.0 Target Δ 定义改指 §4 / `pr-plan.md`。 |
| **P1**(minor) | PR5 把 `PermissionCardWiringTests`/`DetailPaneTranscriptHitTestTests` 标 ★NEW,实则文件已存在 | **已解决** —— §4.3 PR5 改标 **★UPDATED**。 |
| **R2**(cosmetic) | `mountFillPaneHost`/`injectDetailEnvironment` 归 DI-context/translator 偏松(非值袋) | **已标注** —— 两行 Layer 格加 `⟨注 R2:host-mount helper / SwiftUI View 扩展,自由 helper⟩`;落位干净,仅归类松,保留并注明。 |
| **D2** | `CrossfadeController` ✗ 处置正确 | **维持** —— 声明性"不建造",无行;§3.1 与 §3.8 登记为抽象的设计缺陷。 |

审查同时确认:**无生产类不可放置**;两条被点名的依赖边正确(PR6 un-erase 先于 PR7 `DetailContext`
使漏注入成编译错;PR5 card-overlay 先于 PR13 swap-coordinator 且保 `.below topScrim` 兄弟序);
计划主动抵抗过度设计(PR11 诚实降级为可能 no-op;`TurnUsageMeter`/`Session` façade 合并/
`CrossfadeController`/Controller+Coordinator 合并全显式拒绝);无错配制式;渲染器域 100% `unchanged`
留在不可触碰墙后。

---

## 6. 交叉引用

| 主题 | 文档 |
|---|---|
| 重构动机 / 现状数据流 / 目标树 / 7 条宪法 / 逐项 / 迁移 4 阶段 / 不做 | [`REFACTOR-PLAN.md`](REFACTOR-PLAN.md)(§5 目标树、§6 宪法、§7 卡片、§8 逐项、§9 迁移、§11 不做) |
| **不可触碰契约墙** | [`REFACTOR-PLAN.md` §10](REFACTOR-PLAN.md)(本文档 §2.5 DNT-1…DNT-8 是其浓缩) |
| AppKit↔SwiftUI 边界 host 制式(A/B/B′/B″/C/D/E)+ 回归门 | [`boundary/BOUNDARY-SPEC.md`](boundary/BOUNDARY-SPEC.md) |
| 现状组件树 + P1–P15 问题排名 | [`nodes/analysis-component-tree.md`](nodes/analysis-component-tree.md) |
| 各区源码约定(触前先读) | `Content/Chat/CLAUDE.md`、`Services/Session/CLAUDE.md`、`Content/Chat/NativeTranscript2/CLAUDE.md`、`cctermTests/CLAUDE.md` |

> 本 FINAL-PLAN 的源节点(已合并入本文,留作追溯):`final/nodes/spec.md`、`final/nodes/table-*.md`(6 片段)、`final/nodes/pr-plan.md`、`final/nodes/review.md`。
