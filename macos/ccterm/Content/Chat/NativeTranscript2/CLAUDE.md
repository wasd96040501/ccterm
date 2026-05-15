# NativeTranscript2

老 `NativeTranscript` 的重构。Core Text 自绘 + NSTableView,但砍掉老代码的过度抽象(component 协议、prepare cache、refinement、5 种 reason 等)。

## 0. 最重要的一条规则:**MVP = 窄范围,不是低质量**

这是**重构需求**,不是"先随便写,以后补"。

| 概念 | 含义 |
|---|---|
| **范围**(scope) | MVP 现在只做 heading + paragraph;加 user bubble / tool / list / table 是分阶段 |
| **质量**(quality) | 每加一个 block kind,视觉/行为达到老代码同等水准。**不存在"MVP 阶段先简单做、以后补全"的路径** |

具体落地反例(都是踩过的坑):

- ❌ "MVP 不需要 `.never` / responsive scrolling / negative-width clamp" → **错。**这些是任何生产级 NSTableView 的基线 chrome,不是优化
- ❌ "MVP 用 `pendingBlocks` 暂存够了,以后再统一" → **错。**统一的 `currentBlocks + rebuild()` 路径成本一样,直接写对的
- ❌ "MVP 加 list 时用 NSParagraphStyle 凑,sticky bullet 等以后补" → **错。**那叫降质量。要么不加 list(范围),要么加就做对(质量)

## 1. 架构

```
SwiftUI: NativeTranscript2View (NSViewRepresentable)
   │
   ├─ makeCoordinator → Transcript2Coordinator (NSTableViewDataSource/Delegate)
   │
   └─ makeNSView →
      Transcript2ScrollView (NSScrollView, .never, responsive)
         └─ Transcript2ClipView (NSClipView, .never)
            └─ Transcript2TableView (NSTableView, neg-width clamp)
               └─ BlockCellView (NSView, override draw(_:), .onSetNeedsDisplay)
```

数据流向:`SwiftUI [Block] → updateNSView → Coordinator.setBlocks → rebuild → diff → NSTableView insertRows/removeRows/reloadRows`。

## 2. 不变量(踩中就是 bug)

### 2.1 渲染路径

- 自绘 cell 用 `override draw(_:)` 路径,policy 是 **`.onSetNeedsDisplay`**(不是 `.never`)。`.never` 配 CALayerDelegate.draw,本项目没走那条路
- ScrollView / ClipView 用 **`.never`** —— 它们没自有内容,纯 composite 子视图,滚动 0 draw 调用
- `isCompatibleWithResponsiveScrolling = true` —— 漏了会回退到同步 drawRect 慢路径

### 2.2 数据 / 排版 / 状态

- **stable id 是 diff 的根**:`Block.id: UUID`,caller 提供。不要用内容 hash 当 id,会让"同名两条消息"被误认成一条
- **Layout 跟 RowItem 共生死**:`RowItem { id, block, layout: TextLayout }`。layout 算一次跟着 row 活,**不要外部 LRU cache**(老代码的 `TranscriptPrepareCache` 是补丁,新架构 id-based 复用自然就够)
- **Row state**(折叠等)放 `Coordinator.foldStates: [UUID: Bool]`(已落地),**不进 `Block.Kind` 关联值**。理由:state 要跨 `.update` 内容更新存活(content 改了用户的展开偏好不能被推翻);也要跨 `RowLayout` 重建存活(layout 是 `(block, width, state)` 的纯函数,state 是输入而非字段)。Layout 始终 stateless —— `userBubble` 用"硬截断 + sheet"避开 in-cell expand;`diff` 用 `foldStates[id]` 驱动 collapsed↔expanded body shape,`Coordinator.toggleFold(id:)` 翻转 flag 并在动画 group 内 `noteHeightOfRows` + `reloadData(forRowIndexes:)`。新增 stateful 行为类型时:state 字段加到 coordinator(sparse dict,absent = default),`makeLayout` switch 透传到对应 `XxxLayout.make` 参数
- **Tool runtime status** 是同款 sparse-dict 模式的第二个落地:`Coordinator.statusStates: [UUID: ToolStatus]`(absent = `.completed`),keyspace 跟 `foldStates` 共享 —— 顶层 `Block.id` = group 状态,`ToolGroupBlock.Child.id` = child 状态。`Transcript2Controller.setToolStatus(id:status:)` → `Coordinator.setStatus(id:)` → `removeCachedLayout(for: hostBlockId)` + 单行 `reloadData(forRowIndexes:)`。**不走 `Change.update`**:那条路会无谓 drop highlight + drop selection,并强制 caller 重组 `Block.Kind`。status 只改 header 颜色 / shimmer overlay(不改 row height),所以 `setStatus` 跳过 `noteHeightOfRows`;status 由 `ToolGroupLayout` 在 `make` 时折进 `Header.status`,`drawHeader` / `subviewPlan` 通过 `titleColor(for:hovered:)` / `chevronTint(for:hovered:)` / `wantsShimmer(for:)` 三个 helper 解析颜色 + shimmer 出场。加新状态视觉规则只改这三个 helper。**`.running` 不再用更亮的 hover-tier 颜色**(那条路径会让 running ↔ completed 翻转产生 brightness pop):running 的 title / chevron 颜色与 completed 完全一致,差异由 sweeping shimmer overlay (`SubviewPlan.Shimmer`) 表达。**`SubviewPlan.Chevron` 携带的是 resolved `strokeColor` + `alpha`(已经 fold 进 status + hover),`SubviewPlan.Shimmer` 只携带 frame(高光颜色 / 速率 / locations 动画在 cell reconciler 里),cell 端零状态枚举感知**
- **永远 `currentBlocks + rebuild()`**:`setBlocks` 和 `frameDidChange` 走同一个 `rebuild()`。`rebuild` 内部 `width <= 0` 早退。**不要再造 `pendingBlocks` 这种特殊路径**

### 2.3 Diff 路径

- 走 granular `insertRows` / `removeRows` / `reloadRows` + `noteHeightOfRows`,不是 `reloadData()`
- `Swift.CollectionDifference` 算结构变更;同 id 但 content 变化的额外加进 `contentChanged` IndexSet
- `tableView.beginUpdates` / `endUpdates` 包裹,中间不重入 dataSource

## 3. Layout 边界(`XxxLayout` 该管什么)

> **`XxxLayout` 是一个 immutable 值,封装"从某种 block 数据 + 当前 width(+ state)算出的、用于(a)向 NSTableView 报 height 和 (b)画 block 内容主体的、宽度相关的几何信息"。**

判断一段代码"该不该是 Layout 管的事",过这三关:

1. **是不是 width 的纯函数?**(确定输入 → 确定输出,不感知 hover/selection/animation)
2. **是不是 row 内容主体?**(改变会不会动 row height?会动 → Layout;不会 → CellView 装饰)
3. **是不是 draw 前必须算好的几何?**(`heightOfRow` 必须秒返,不能临时排版)

三关全过 → 该是 Layout。**state 是 Layout 的输入,不是字段**(`make(input, width, state) -> Layout`)。

### Layout vs CellView 分工

| Layout 管 | CellView 管 |
|---|---|
| 文本字形位置 / image 像素 rect / table cell 内容 | row padding / 圆角 / 阴影 / loading 占位 |
| 任何**会改 row height 的几何** | 任何**纯装饰**(不影响 height) |
| 描述需要 cell 挂的 sublayer / subview(`SubviewPlan`) | 按 plan reconcile sublayer / subview |

### 多种 Layout 的派发

`enum RowLayout` 持有具体的 `XxxLayout`,统一暴露 `totalHeight` / `measuredWidth` / `draw(in:origin:)` 三件事。Cell 不感知 enum 内部,只调 `layout.draw`。

加新 layout 类型 = `RowLayout` 加 case + 三个 switch 各加一行。

### Cell 不是纯自绘 — AppKit 适配器模式

`BlockCellView` 主要走 `override draw(_:)` 自绘路径,但**不再是 100% 单 bitmap**。某些动画/交互行为 CGContext 表达不了,需要挂 AppKit-side 装饰物:

| 装饰物 | 类型 | 为什么不走自绘 |
|---|---|---|
| chevron 旋转 | `CAShapeLayer` 子图层 | `transform.rotation.z` 用 `CABasicAnimation` 一行,自绘要每帧重画 |
| 可滑动的内嵌 body | `NSView` 子视图(layer-backed) | 单行内多个 body 在 fold 时要互相滑过,只有 `view.animator().frame` 才能实现 slide,单 bitmap 只能 fade |

**Layout 怎么声明这些装饰物:**`RowLayout` 暴露 `subviewPlan(origin:hoveredAction:selection:) -> SubviewPlan`,只有需要的 layout(今天只有 `toolGroup`)在自己的 enum case 里返回 non-empty plan。`SubviewPlan` 是 **struct + 闭包**(跟 `SelectionAdapter` 同款 pattern),不是 protocol —— cell 不知道是哪种 layout 在产 plan,只跑通用 reconcile。

**绝对禁止**给"哪种 layout 要装饰物"抽 protocol。原因跟 `ToolGroupChildLayout` enum 一样:protocol 让"忘了在某个 case 实现"成为可能,enum case 加 switch arm 让编译器替你检查。

**SubviewPlan 怎么扩展:**
- 想加新装饰物类别(目前 chevron / entry / shimmer 三类) → `SubviewPlan` 加字段 + `BlockCellView+SubviewPlan.swift` 加 reconcile arm
- 想让别的 layout 产装饰物 → `RowLayout.subviewPlan` 里给那个 case 加 switch arm,在 layout 自己的文件里实现 `subviewPlan(...)` 方法

## 4. 加新 block kind 的清单

按 `enum Block.Kind` case 加。同时:

1. **判断是否需要新 Layout 类型**(过第 3 节三关)
2. **`Transcript2Coordinator.makeRowItem` 的 switch 加分支**:派发到对应 `XxxLayout.make`,wrap 进 `RowLayout` case
3. **如果是新 layout 类型**:在 `Layout/` 加 `XxxLayout.swift`,在 `RowLayout` enum 里加 case
4. **不要复活 `BlockStyle.attributed(for: Block)`**(已删):这种"all blocks → one attributed string"的 API 假设撑不过非文本 block。每个 kind 在 makeRowItem 里直接派发即可

### 已实现的范例

- `case .heading(level: Int, inlines: [InlineNode])` / `case .paragraph(inlines: [InlineNode])` → `TextLayout`,经 `BlockStyle.headingAttributed(level:inlines:)` / `paragraphAttributed(inlines:)` 把 inline IR 折叠成 `NSAttributedString`。无 `String` 重载——caller 没有 parser 时手动包 `[.text(s)]`
- `InlineNode` 是递归 inline IR(text / strong / emphasis / code / link / lineBreak),由上游 markdown parser 产出;Block 层只持有,不解析
- `case .image(NSImage)` → `ImageLayout`(aspect-fit + maxHeight 兜底)
- `case .toolGroup(ToolGroupBlock)` → `ToolGroupLayout`。一行装下整个 toolGroup,跟老 `NativeTranscript.GroupComponent` 一比一对齐 —— 字号 / 颜色 / chevron 形状 / hover / padding 全部对齐,不要再改。

  **视觉(一比一对齐老 GroupComponent):**
  - **group header** (24pt) 在 row 顶部:title + 右侧 chevron。title 12pt medium `secondaryLabel`,chevron 8pt,title↔chevron gap 6pt,无 icon,无 inset(layout-local x=0,row 的水平 padding 由 cell `layoutOrigin.x` 提供)。
  - **child header** 跟 group header **完全同款常量**(`BlockStyle.toolHeader*`)。child header 之间、group header → first child header 之间都是 `toolHeaderChildSpacing = 4pt`。
  - **chevron 路径**:自绘两段折线 `>`(`lineWidth = 1.4`,`round` cap/join),不要换 SF Symbol —— 老代码用 CGShapeLayer 同款 path。idle alpha = 0.35,hover alpha = 0.85。folded 时 rotation = 0(指右),expanded 时 rotation = π/2(指下)。
  - **chevron 视觉中心补偿**:`visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)`,chevron centre.y 在 midY 基础上加此偏移,让 chevron 跟 title 的 x-height 中线对齐(没补偿的话 chevron 会视觉浮在 title 上方)。
  - **hover 高亮**:`BlockCellView` 通过 `NSTrackingArea(.mouseMoved + .mouseEnteredAndExited + .activeInKeyWindow + .inVisibleRect)` 追踪当前 hover 命中的 `HitAction`,传给 `RowLayout.draw(in:origin:hoveredAction:)`。`ToolGroupLayout.draw` 用 `hoveredAction` 中的 `.toggleFold(id)` 跟每个 header.foldId 匹配,匹配的 header 的 title 改用 `.labelColor`,chevron 改用 hover alpha。其它 layout 忽略 `hoveredAction` 参数。
  - **expanded body**:child header 展开后下方 4pt gap 浮出一个 `codeBlock`-style 圆角矩形(填色 `diffContainerBackground`,圆角 `structuralCornerRadius`),由 `ToolGroupChildLayout` enum 分发到 per-kind layout 文件(目前只有 `FileEditChildLayout`,内部调 `DiffLayout` 画 hunks)。

  **fold state 路由:** `HitAction.toggleFold(UUID)` 携带的 id 可能是 group host 的 `Block.id`(group header)或某个 `Child.id`(child header)。`Coordinator.toggleFold(id:)` **必须**同时搜索 `blocks.firstIndex(where: { $0.id == id })` **和** 每个 toolGroup 内 `children.contains(where: { $0.id == id })` 才能定位 host row;只搜顶层 blocks 会让 child header 点击无反应。

  **三态文案(group + child):** `ToolGroupBlock` 持三个 title(`activeTitle` / `expandedActiveTitle` / `completedTitle`),`group.resolvedTitle(status:isExpanded:)` 是单一选址点 ——`.running` 折叠取 `activeTitle`(末 child 进行时),`.running` 展开取 `expandedActiveTitle`(聚合进行时),其它终态 (`.completed` / `.failed` / `.cancelled`) 取 `completedTitle`(聚合过去时)。Child 同理:每个 payload 持 `label`(过去时)+ `activeLabel`(进行时),`Child.headerLabel(for: ToolStatus)` 派发 —— `.running` 取 `activeLabel`,其它取 `label`。Bridge (`MessageEntryBlockBuilder` + `ToolUseToChild`) 两个文案**都填**,layout 层根据 `statusStates[id]` 即时切换,**不**走 `Change.update` 重组 Block.Kind。三态文案的源头是 `SessionHandle2.GroupEntry.activeTitle` / `expandedActiveTitle` / `completedTitle`(对应 `activeCountPhrase` / `completedCountPhrase`),单 tool group 直接用 `ToolUse.activeFragment` / `completedFragment`,不再走 `activeCountPhrase(1)`(那会把"Reading foo.swift"模糊成"Reading 1 file")。

  **新增 child kind:**
  1. `Layout/ToolGroupChildren/<Kind>/<Kind>Child.swift` 新建文件放 payload struct(必须暴露 `id` / `label` / `activeLabel`;`id` 驱动 fold-state / highlight scope,`label` = 过去时,`activeLabel` = 进行时,`Child.headerLabel(for: ToolStatus)` 根据状态选用);Block.swift 只加 enum case + 在 `id` / `label` / `activeLabel` / `hasExpandableBody` switch 各加一行;
  2. `Layout/ToolGroupChildren/<Kind>/<Kind>ChildLayout.swift` 新建文件实现 `make / totalHeight / draw / drawBackplate`。多 sub-card body 直接复用 `TextCardSection.build / drawBackplates / draw`,不要每个 layout 重写一份 sub-card 几何;
  3. `ToolGroupChildLayout` enum 加 case 加 4 个 switch arm(`totalHeight` / `drawBackplate` / `draw` / `make`);
  4. **header-only kind** (`.read` / `.generic`):`hasExpandableBody = false`,layout `totalHeight == 0`,`draw` / `drawBackplate` 留空 — `ToolGroupLayout` 自动跳过 chevron 绘制 + 不注册 fold hit;
  5. 如果需要异步高亮,`ToolGroupChildHighlight.requests(for:)` 加 case 返回 `Plan`;
  6. 如果 body 要可选(进入 `selectionAdapter`):
     - 走 `TextCardSection` 的 body(bash / grep / glob / webFetch / webSearch / askUserQuestion / agent)零改动 —— `ToolGroupChildLayout.textCardSections` 已经把 sections 列表暴露出去,`ToolGroupLayout.selectionAdapter` 的 `buildRegions` 自动给每个 section 建一个 `LayoutPosition.textCard(childIndex:sectionIndex:char:)` 区域。仅当你新增的 kind **不基于 `TextCardSection`** 才要扩 `LayoutPosition` —— 给它加一个具体 case 并在 `buildRegions` 里加 switch arm 把对应 `Region` 路由进去
     - 选区粒度是 section-local(跨 section 拖拽 clamp 到起点 section),跨 child 同样 clamp。fileEdit 是唯一的特例 —— 走 `LayoutPosition.diff(childIndex:char:)`,因为 `DiffLayout` 有自己的 gutter/sign 列剥离逻辑,不能直接走 `TextLayout`

  **已实现的 child kinds**(每个独占一个 `Layout/ToolGroupChildren/<Kind>/` 子目录):

  | Kind | Body |
  |---|---|
  | `read` / `generic` | header-only(无 chevron) |
  | `fileEdit` | diff 卡 (`DiffLayout` + per-line highlight) |
  | `bash` | command / stdout / stderr 三段 monospaced sub-cards;stderr 红字 |
  | `grep` | filenames + 可选 content preview,两段 sub-cards |
  | `glob` | filenames + 可选 "… truncated" 尾,单卡 |
  | `webFetch` | response body 单卡(plain text) |
  | `webSearch` | results list (title semibold / url monospace / snippet) |
  | `askUserQuestion` | Q&A list (semibold question + answer / "awaiting answer…") |
  | `agent` | progress 卡(`↳ ` 前缀)+ output 卡 |

  **禁用 protocol** —— enum 分发保证 exhaustiveness 检查,protocol 让"忘了在哪个文件里实现"成为可能。

  **child header 文案 = 子项自带 `label`,不是裸 filePath。** `FileEditChild` 同时持 `label`(显示用,例如 "Edit Sources/Greeter.swift",过去时形式)和 `filePath`(供 highlight 语言检测)。这是为了对齐老 `ReadChildRenderer` 的 `tool.completedFragment` 文案规则 —— group 展开时 children 永远展示完成态,active 进行时由 group title 反映。

  **异步高亮:** scope 是 `Transcript2HighlightScope.toolGroupChild(itemId: child.id)`,每个 child 自己决定 `HighlightValue` 形态;file edit 走 per-unique-line `.lineMap`(同老 `NativeDiffView`,key 是 raw line content)。Line metrics 不随 tokens 变化,`onDidFill` 只 `reloadData(forRowIndexes:)`。

  **New-file 模式(`oldString == nil`):** `.add` 行视作 `.context`(无 `+` sign,无 add bg),保留 gutter 行号 + token 高亮 —— 输出为"带行号的 code view"而非"全 add 的 diff"。

  **Selection 已支持所有可见 body**:fileEdit 走 `LayoutPosition.diff(childIndex:char:)`,其余 7 种(bash / grep / glob / webFetch / webSearch / askUserQuestion / agent)走 `LayoutPosition.textCard(childIndex:sectionIndex:char:)`,粒度 = 单个 `TextCardSection` 卡片。`read` / `generic` header-only,无 body 可选
- `case .userBubble(text: String)` → `UserBubbleLayout`(右对齐气泡;长文本硬截断到 `userBubbleCollapseThreshold` 行,最后一行用 `CTLineCreateTruncatedLine` 加 `…` 尾,padding 内画 `>` chevron;selection clamp 到 prefix 行,truncated tail 不可选)。**Layout 完全 stateless**,不带 fold 状态 —— chevron mouseDown → `Coordinator.requestUserBubbleSheet(id:)` → 通过 `onUserBubbleSheetRequested` 闭包路由到 `Transcript2Controller.pendingUserBubbleSheet`(`@Observable`)→ SwiftUI 侧 `.sheet(item:)` 弹出完整内容(支持 `Text.textSelection(.enabled)` 复制)。这是 NSView 闭环里**唯一**合法的 SwiftUI 出口 —— `.sheet(item:)` 作为 presentation primitive 必须由 SwiftUI own,但 in-cell 渲染 / 命中 / selection 仍全程 NSView 内部

## 4. 文件结构

```
NativeTranscript2/
├── Model/
│   └── Block.swift                  数据 + 字体/边距常量 + 气泡 / chevron / code / diff 几何常量
├── Layout/
│   ├── TextLayout.swift             Core Text 排版结果(immutable + draw)
│   ├── ImageLayout.swift            aspect-fit + draw(NSImage 自带数据)
│   ├── ListLayout.swift             递归 list + 自绘 marker / checkbox
│   ├── TableLayout.swift            CSS-like min/max 列分配 + 自绘网格
│   ├── UserBubbleLayout.swift       右对齐气泡 + chevron + fade mask + selection clamp
│   ├── CodeBlockLayout.swift        header(lang/copy)+ 内嵌 TextLayout body + 异步 token 着色
│   ├── BlockquoteLayout.swift       左 bar + 内嵌 TextLayout
│   ├── ThematicBreakLayout.swift    单行 hairline
│   ├── ToolGroupLayout.swift        toolGroup 行(group header + 子项 headers + 展开 child body),enum 分发到 ToolGroupChildLayout
│   ├── ToolGroupChildren/           toolGroup 子项 layout,每种 child kind 一个子目录(payload + layout 一起)
│   │   ├── ToolGroupChildLayout.swift     enum 分发 totalHeight/draw/drawBackplate + make 工厂
│   │   ├── ToolGroupChildHighlight.swift  per-kind highlight 请求 + finalize
│   │   ├── TextCardSection.swift          多卡 sub-body 共享几何 + draw helpers
│   │   ├── FileEdit/                      diff body(头-体两段)
│   │   │   ├── FileEditChild.swift            payload struct
│   │   │   ├── FileEditChildLayout.swift      thin wrapper 调 DiffLayout
│   │   │   ├── FileEditChildHighlight.swift   per-unique-line highlight 请求 + finalize
│   │   │   ├── DiffBlock.swift                diff payload(old/new + hunks 派生)
│   │   │   └── DiffLayout.swift               hunks body(`codeBlock`-style 圆角矩形 + per-line gutter/sign/content)
│   │   ├── Read/                          header-only:Read*Child + ReadChildLayout(totalHeight=0)
│   │   ├── Generic/                       header-only 兜底:GenericChild + GenericChildLayout(totalHeight=0)
│   │   ├── Bash/                          command + stdout + stderr 三段 sub-cards
│   │   ├── Grep/                          filenames + content preview 两段 sub-cards
│   │   ├── Glob/                          filenames 单卡 + 可选 "… truncated" 尾
│   │   ├── WebFetch/                      response body 单卡(plain text)
│   │   ├── WebSearch/                     results list 单卡(title / url / snippet 三层)
│   │   ├── AskUserQuestion/               Q&A list 单卡(question / answer 两层)
│   │   └── Agent/                         progress + output 两段 sub-cards
│   ├── SelectionAdapter.swift       selection-facing API(每个 layout 自带,struct + 闭包)
│   ├── SubviewPlan.swift            chevron + entry-subview 装饰物 plan(layout 自带,同 SelectionAdapter pattern)
│   └── RowLayout.swift              enum 派发(text/image/list/table/userBubble/codeBlock/blockquote/thematicBreak/toolGroup)
├── AppKit/
│   ├── Transcript2ScrollView.swift  ScrollView + ClipView 子类
│   ├── Transcript2TableView.swift   TableView 子类(neg-width clamp)
│   ├── CenteredRowView.swift        Row view 占位子类(空实现),仅为 NSTableView.makeView 提供稳定 row 复用 key
│   ├── BlockCellView.swift          自绘 cell:layoutOrigin.x = cellOriginX + blockHorizontalPadding 实现居中 + layout.draw + 链接/chevron 命中 + selection + hover tracking
│   └── BlockCellView+SubviewPlan.swift  按 layout 的 SubviewPlan reconcile chevron sublayer + entry subview;ToolGroupEntryView 也在这里
├── Transcript2Coordinator.swift          dataSource/delegate + diff + per-kind 派发 + chevron sheet request 路由
├── Transcript2Controller.swift           imperative 命令通道(apply / loadInitial)
├── Transcript2SelectionCoordinator.swift 跨行 selection 算法(读 layout.selectionAdapter)
└── NativeTranscript2View.swift      SwiftUI 桥(updateNSView 是 no-op)+ Preview
```

依赖只往下:`NativeTranscript2View → Coordinator → AppKit/ → Layout/ → Model/`。

## 5. 异步高亮回填

`Transcript2HighlightStorage` 是 per-block 异步 side-data 通道。框架已经支持两种 value 形态:

| Scope | Value | 用法 |
|---|---|---|
| `.codeBlock` | `.tokens([SyntaxToken])` | codeBlock 整段 highlight |
| `.diff` | `.lineMap([content: tokens])` | diff per-unique-line highlight,key 是 raw line content |

**回填流程**(任意 highlight-bearing kind 共用):

1. `Coordinator.apply` 在 `.insert` / `.update` 时调 `storage.schedule(block)`
2. `schedule` 走 `plan(for: block)` 派发,拿到 `Plan { payload, writeback }`
3. 一次 `engine.highlightBatch(payload)` 跨 JSCore;结果走 `writeback` 写到 storage
4. `onDidFill(blockId)` 触发 `removeCachedLayout(for: id)` + `reloadData(forRowIndexes:)`
5. 下一次 `viewFor` 的 `makeLayout` 调用读到 storage snapshot → 着色版 layout

**Generation guard:** `schedule` / `drop` 都 bump `inflightGen[blockId]`,完成回写时对比 generation,drift 则丢弃 — 防止旧 highlight 覆盖新内容(`.update` 把 oldCode 换成 newCode 时,旧 highlight task 完成后不应该写回)。

**Layout 不变量:** highlight 回填**只换颜色,不换 metrics** — 同 font 同 width 下 glyph 位置不会因为有无 token 而漂移。所以 `onDidFill` 只 `reloadData(forRowIndexes:)` 触发 cell `viewFor` + `draw`,不 `noteHeightOfRows`(那会让所有后续行重排,无意义抖动)。

**加一种新的 highlight-bearing kind:**

1. `Transcript2HighlightScope` 加 case(如果不能复用 `.tokens` / `.lineMap`,可以扩 `HighlightValue` 加形态)
2. `Storage.plan(for:)` switch 加分支:返回该 kind 的 `payload` + `writeback`
3. `XxxLayout.make` 接收对应形态的可空参数(如 `tokens: [SyntaxToken]?` / `lineMap: [String: [SyntaxToken]]?`)
4. `Coordinator.makeLayout` switch 从 `highlights` snapshot 取对应 key 的 value,模式匹配出 token 形态,传入

无需改 framework — storage / reload pipeline 是泛化的。

## 6. 改动前清单

- 改 `Coordinator` 的 diff / pipeline:跑 SwiftUI Preview(`NativeTranscript2View.swift` 的 `#Preview`)目视验证 insert/remove 动画
- 改 `BlockCellView.draw`:Preview 看排版与字号
- 改 `TextLayout.make`:Preview 视觉检查就够,纯函数本身不太容易出错
- 改 `Transcript2ScrollView` / `Transcript2TableView`:跑应用(make build + 运行),拖窗口宽度看 reflow
