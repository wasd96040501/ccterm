<!-- DELETE BEFORE MERGE — investigation notes only; not for shipping.
     The logging hooks added to ChatHistoryView / Transcript2Controller /
     Transcript2Coordinator / Transcript2EntryBridge / NativeTranscript2View
     for this investigation are also temporary and should be removed in the
     same PR that lands the fix. -->

# Load-history 滚动到底 bug 排查结论

## 症状（用户报告）

1. **首次打开**会话：落点位置随机，**不一定到底**。
2. **第二次打开**同一会话（切走再切回）：**必定**接近顶部。

## 原因（这是两个 bug，不是一个）

### Bug A — 首开的 race

发起 scroll 的代码路径是：
`SessionRuntime` Phase A → `Bridge.applyReset(.bottom)` → `Controller.loadInitial(..., deferred=true)` 把 `pendingInitial=.bottom` 记下来 → 等 `Coordinator` 的 `onLayoutReady` 触发 → `consumePendingInitial` → `scrollRowToBottom`。

`onLayoutReady` 由 `tableFrameDidChange` 在 `prevWidth<=0 && width>0` 转变时发出。问题在于：**这一发生在 `NSScrollView.setDocumentView(_:)` 把 table 加入 clipView 之前**（AppKit 先改 frame、再插 subview）。所以 `scrollRowToBottom` 跑的时候 `tableView.enclosingScrollView == nil`，guard 直接 abort，**意图就此丢失**，再也没人补救。

「随机」就是 AppKit 内部时序在不同跑动里偶尔会让 enclosingScrollView 先连上，那次就正确滚到底。

#### 日志证据

```
.240 [Bridge] applyReset FIRST-RESET → loadInitial(.bottom)
.240 [Controller] loadInitial blocks=42 width=0 viewportH=0 deferred=true
.256 [ChatHistoryView] .task scrollToBottom → apply DROPPED (tableView is nil)
.266 [Coordinator] frameDidChange firing onLayoutReady (0→positive)
.266 [Controller] consumePendingInitial FIRES anchor=bottom blocks=42
.266 [Coordinator] scrollRowToBottom ABORTED idLookupFound=true scrollView=false   ← ★
.273 [Coordinator] frameDidChange RUN prevWidth=460 newWidth=780   ← 此时 scrollView 已 wired，但没人再发起 scroll
```

### Bug B — 二开的死路（确定性的）

`SessionRuntime.loadHistory()` 对 `.loaded` 状态幂等 → Phase A 不会再触发 → `Bridge.applyReset` 不会再跑 → `pendingInitial` 是 nil。剩下唯一可能触发 scroll 的两条路径：

1. `ChatHistoryView.task` 里的 `scrollToBottom()`：在 SwiftUI 把新 `NativeTranscript2View` 提交之前就同步执行了，此时 `coordinator.tableView == nil`，`Coordinator.apply` 的 else 分支静默丢掉 scroll 状态。
2. `Coordinator.tableFrameDidChange` 的 `onLayoutReady`：要求 `prevWidth<=0 && width>0`。但 `lastLayoutWidth` 是 Coordinator 的私有字段，coordinator **跨 mount/dismount 持久**，上一次 mount 已把它写成 780。这次重新挂载，width 经历 780→460→780 的过渡 —— 没有任何一次满足 0→positive，**`onLayoutReady` 一次都不发**。

**结果**：从头到尾零次有效 scroll 调用。表停在 `reloadData()` 留下的默认位置（顶部）。

#### 日志证据

```
.406 [ChatHistoryView] .task scrollToBottom → apply DROPPED (tableView is nil)
.445 [Coordinator] frameDidChange RUN prevWidth=780 newWidth=460
.445 [Coordinator] tableView didSet old=NIL new=nonNil blocks=361 reload=true
.445 [Coordinator] frameDidChange EARLY-RETURN width=460 lastLayoutWidth=460 (no invalidate, no onLayoutReady)
.448 [Coordinator] frameDidChange RUN prevWidth=460 newWidth=780
.469 [Coordinator] frameDidChange EARLY-RETURN width=780 lastLayoutWidth=780 (no invalidate, no onLayoutReady)
```

没有任何 `scrollRowToBottom` 一行出现 —— scroll 从未发起。

## 共同根因

「触发 scroll 的时机」与「scrollView 真正可用的时刻」错位。
- 首开：触发太早（`onLayoutReady` 在 enclosingScrollView 尚未挂上时就发了）。
- 二开：根本没人触发（`.task` 抢跑被 drop，`onLayoutReady` 不再发）。

且 `ChatHistoryView.task` 里的 `scrollToBottom()` 调用——数据证明它**从未生效**（每一次都被 `apply DROPPED`）。

## 拟定修复（先沟通，未落地）

把「scroll-to-tail 的触发点」从「frameDidChange 的 0→positive」改成「table 真正挂入 scrollView 之后」：

1. `Coordinator.tableView.didSet`：当 `old==nil && new!=nil && !blocks.isEmpty` 时，`DispatchQueue.main.async { scrollToTailIfNeeded() }`。同一 runloop iteration 内的 setDocumentView 已完成，下一 tick 时 enclosingScrollView 一定就位。这一条同时覆盖：
   - 首开 deferred 路径（pendingInitial 失败后的兜底）
   - 二开 re-entry（pendingInitial 一开始就没设置）
2. `consumePendingInitial → scrollRowToBottom` 抓到 `enclosingScrollView == nil` 时也走 `DispatchQueue.main.async` 重试，保证「意图不丢」。
3. `ChatHistoryView.task` 里的 `s.controller.scrollToBottom()` 删掉（数据证明它从未生效，留着只会让逻辑更难读）。

## 本次提交里临时引入的代码（合并前必须移除）

| 文件 | 改动 |
|---|---|
| `Content/Chat/ChatHistoryView.swift` | `.task` 内 pre/post scrollToBottom 两条 `[scroll-bug]` log |
| `Content/Chat/NativeTranscript2/Transcript2Controller.swift` | `scrollToInitialAnchor` / `loadInitial` / `consumePendingInitial` 入口的 `[scroll-bug]` log |
| `Content/Chat/NativeTranscript2/Transcript2Coordinator.swift` | `tableView.didSet`、`apply` 入口、`apply DROPPED`、`scrollRowToBottom` / `scrollRowToTop` / `tableFrameDidChange` 全套 `[scroll-bug]` log，外加两个 `debugHasTable` / `debugScrollOriginY` 调试访问器 |
| `Content/Chat/NativeTranscript2/NativeTranscript2View.swift` | `makeNSView DONE` / `dismantleNSView` 的 `[scroll-bug]` log |
| `Content/Chat/NativeTranscript2Bridge/Transcript2EntryBridge.swift` | `applyReset` 走哪条分支的 `[scroll-bug]` log |

全部 grep `[scroll-bug]` 一把删干净即可。`debugHasTable` / `debugScrollOriginY` 两个访问器只被 log 用，一并删除。
