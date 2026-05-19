# Transcript Swap Architecture (Design Note)

> **状态**：设计稿，**不要合入 main**。这是 sidebar session 切换跳变问题的根因分析 +
> 目标架构。落地前需要单独的实现 PR 系列。

## 背景

当前实现里，从 sidebar 切换到不同 session 时，chat 区域会出现**视图跳变** —— bake
（image bake 双缓冲）撤掉那一瞬间，下层视图的滚动位置不是最终位置，紧接着又自己挪
了一下。

跳变的根因不是动画，是几何：`firstScreenAnchored = true` 这个 release 信号发出时，
新 view 的 scroll 还没在最终位置上。

## 根因

存在两条出 bug 的 entry path：

### Path 1：cold-open（session 第一次被打开）

桥在 view 还没 tile 完时调 `controller.loadInitial(blocks)`。当前 `loadInitial` 走
**deferred 分支**：把全部 blocks 一次性塞进 `coordinator.blocks`，设
`pendingInitial = .bottom`，等 `onLayoutReady` 之后做一次 `scrollToAnchor`。

`scrollToAnchor` 走 `scrollRowToBottom` → `rect(ofRow: lastIdx)`。AppKit 的
row-position cache 是**按需 lazy 填的**（CLAUDE.md 在 `scrollToAnchor` 注释里自己
写明了这个坑："`rect(ofRow:)` read mid-notification returns geometry against
AppKit's lazily-filled (visible-only) row-position cache, and the scroll target
undershoots"）。一次性塞了 10k blocks 之后立刻 `rect(ofRow: 9999)`，cache 不齐 →
scroll 落点不准 → flag 翻 true → bake 撤掉 → 用户看到错位 → AppKit 后续 lazy fill
时校正 → **视觉跳变**。

stress test 不会撞到，因为它走 real-width 分支：Phase 1 只 insert 视口大小的小切
片（~5 行），`rect(ofRow: 4)` AppKit 不会落坑；Phase 2 `.saveVisible(.visualBottom)`
在视口稳定后异步填上面，锚定行不动。

### Path 2：re-entry（用户第二次及以后打开同一 session）

`Session.controller` / `Session.bridge` 跨 view mount 持久。用户切走 B 再切回 B：
- SwiftUI `.id(sessionId)` 强制 `ChatHistoryView` 重建 → 新 NSTableView attach 到旧
  coordinator。
- `coordinator.blocks` 已经满了（之前 cold-open 灌进去的 + 期间 bridge 持续喂的
  live events）。
- `loadHistory()` 是 no-op（`.loaded` 状态），不会再调 `loadInitial`。
- 走 `handleTableAttached` → `pendingInitial = .bottom` → `consumePendingInitial` →
  `scrollToAnchor(.bottom(lastId))` → **同一个 AppKit lazy cache 坑**。

**sidebar 切换跳变 90% 是 Path 2 引发**，因为 cold-open 一辈子只发生一次。

## 目标架构

按 session 的 CLI 进程状态分两类，对应两种 view 生命周期：

| 类别 | 判定 | View 生命周期 | 切入开销 |
|---|---|---|---|
| **Live** | CLI subprocess alive（idle 或 busy 都算）| **永驻**，bridge 持续喂 blocks | 切回 0 load |
| **Ephemeral** | CLI 没启动 / 已退出 / 已死 | 每次 mount 重建，controller 不跨 mount 保留 blocks | 每次 entry 走 Phase 1/2 cold-open |

判定信号大概率是 `session.status` —— `.notStarted` / `.terminated` 之类归 Ephemeral，
其余归 Live。具体 enum case 落地时再细化。

### 状态迁移

- 用户 send 第一条消息 → CLI 启动 → 升级为 Live，view 自此 mount 且不释放。
- CLI 退出（用户 stop / process crash / session 结束）→ 降级为 Ephemeral，下次切
  进来重新 mount + Phase 1/2。

### 切换

任何切换（Live↔Live、Live↔Ephemeral、Ephemeral↔Ephemeral）都走 image bake 双缓冲消
抖。release 信号 = **Phase 1 完成**（见下方约束 3）。Live 类首次 mount 也走 Phase
1/2 cold-open；后续 mount 不会再发生。

### 关键差异 vs. 当前

- **删 `loadInitial` 的 deferred 分支**。所有 cold-open 都走 real-width Phase 1/2。
- 桥的喂法改造：Ephemeral session **view unmount 时 controller.blocks 清空**，bridge
  不再往 background 的 Ephemeral session 喂事件（如果有 — Ephemeral 按定义 CLI 没
  跑，不应该有 live events）。Live session 维持现状（bridge 持续喂）。
- "re-entry"（blocks 已在 coordinator + 新 view mount）这个 code path 在新架构里**根
  本不存在**。只剩两种 entry：
  - Live 首次 mount（cold-open Phase 1/2，之后 view 永驻）
  - Ephemeral 每次 mount（cold-open Phase 1/2）

### View 永驻的实现路径

SwiftUI `NavigationSplitView` 的 detail 槽 + `.id(visibleSid)` 不支持"多个 view 同时
持有，只显示一个"。落地需要：
- 用一个 retainer container（ZStack / 自定义 AppKit container）持有所有 live session
  的 view。
- 切换 = 改 isHidden / opacity / z-order，不是 unmount/remount。
- Ephemeral session 不进 retainer，正常走 detail 槽 + `.id` 重建。
- Live → Ephemeral 降级时（CLI 退出），从 retainer 移除（释放 NSTableView）。
- Ephemeral → Live 升级时（用户 send），把当前 view 迁入 retainer。

## 内存/性能成本

每个 live view 多吃：
- NSTableView + scrollView + clipView（~几十 KB）
- BlockCellView 复用池（~20-30 个 cell）
- 每个 cell 的 CALayer cached bitmap（几十到几百 KB / cell）

粗估 **5-15MB / live session**。5 个并发 CLI 多 25-75MB，20 个多 100-300MB。

性能：视图 hidden 后 AppKit 不画、CALayer compositor 不工作。Bridge 事件处理跟现在
量级一致。

极端用户（50+ 并发 CLI）可能撞内存上限，需要时再加 LRU 降级（长时间不可见的 Live
降级为 Ephemeral）。

---

## 绝对约束

以下三条是新架构的硬性约束，**实现时不允许违反**：

### 1. 切换中不允许空白，不允许跳变

bake 双缓冲在整个切换期间盖住下层。任何时刻用户看到的都是连续的图像 —— 要么是切换
前的 bake，要么是已经 ready 的目标视图。**不允许中间出现空白帧、不允许出现"先错位
后校正"的位移**。

### 2. 切换后不允许跳变

bake release 之后，新 view 必须**已经处于其最终视觉位置**。后续任何 layout pass、
任何 AppKit 内部 cache fill、任何 Phase 2 saveVisible 操作，都**不允许让可见内容产
生位移**。

### 3. Ephemeral 的 ready signal 在 Phase 1 就发，不允许延迟到 Phase 2

Phase 1/2 切分的全部意义就是：**Phase 1 sync 完成的瞬间，视口内容已经备齐且位置正
确**，可以立刻 release bake；Phase 2 在视口稳定的前提下异步把剩下的填进去。

如果把 release 信号挪到 Phase 2 完成，Phase 1/2 切分就失去意义了 —— 等于退化成"等
全部 blocks 都进去再 release"，大 session 会让用户对着 bake 干等很久。

这意味着：
- Phase 1 的 `scroll: .bottom(id)` 落点必须精确（不能依赖 AppKit lazy 填的 cache）。
- Phase 2 的 `.saveVisible(.visualBottom)` 必须严格不动视口（否则违反约束 2）。
