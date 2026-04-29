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
- **未来的 row state**(折叠等)放 `Coordinator.states: [UUID: any Sendable]`,**不进 `Block.Kind` 关联值,也不进 `RowItem`**。理由:state 要跨 RowItem 重建存活(tool group 内容更新,折叠态要保留)
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

### 多种 Layout 的派发

`enum RowLayout` 持有具体的 `XxxLayout`,统一暴露 `totalHeight` / `measuredWidth` / `draw(in:origin:)` 三件事。Cell 不感知 enum 内部,只调 `layout.draw`。

加新 layout 类型 = `RowLayout` 加 case + 三个 switch 各加一行。

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

## 4. 文件结构

```
NativeTranscript2/
├── Model/
│   └── Block.swift                  数据 + 字体/边距常量
├── Layout/
│   ├── TextLayout.swift             Core Text 排版结果(immutable + draw)
│   ├── ImageLayout.swift            aspect-fit + draw(NSImage 自带数据)
│   └── RowLayout.swift              enum 派发 + RowItem(struct)
├── AppKit/
│   ├── Transcript2ScrollView.swift  ScrollView + ClipView 子类
│   ├── Transcript2TableView.swift   TableView 子类(neg-width clamp)
│   └── BlockCellView.swift          自绘 cell(只调 layout.draw)
├── Transcript2Coordinator.swift     dataSource/delegate + diff + per-kind 派发
└── NativeTranscript2View.swift      SwiftUI 桥 + Preview
```

依赖只往下:`NativeTranscript2View → Coordinator → AppKit/ → Layout/ → Model/`。

## 5. 改动前清单

- 改 `Coordinator` 的 diff / pipeline:跑 SwiftUI Preview(`NativeTranscript2View.swift` 的 `#Preview`)目视验证 insert/remove 动画
- 改 `BlockCellView.draw`:Preview 看排版与字号
- 改 `TextLayout.make`:加测试是 OK 的,但纯函数不太容易出错,Preview 视觉检查通常够
- 改 `Transcript2ScrollView` / `Transcript2TableView`:跑应用(make build + 运行),拖窗口宽度看 reflow
