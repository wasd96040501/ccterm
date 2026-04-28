# NativeTranscript2 — pipeline 统一（待办）

> 临时交接文档。重构落地后删除此文件。

## 现象

1. `refillLayoutCache` 完成时 scroll anchor 抖动。已经用 `mutationCounter` 在 `apply` 干涉期间整批 skip onMain 规避 —— 治标。
2. `applyInBackground` task 期间发生 live resize → 可见区域短暂白屏。未解决。

## 根源观察

`apply` / `refillLayoutCache` / `applyInBackground` 本质是同一个 pipeline 的三个 instance：

> source-of-truth 变化（blocks 或 width invalidate）→ fill layout cache → 通知 AppKit（insertRows / noteHeightOfRows）→ scroll 调整 → 后台 warm 剩余

差异只在「mutation 形态」和「layout 算在 main 还是 bg」。但当前实现是三条独立路径，各自 timing 一套，互相 inflight 时只能靠 counter / cancel / id anchor 这些边角防御打补丁，patch 层叠不收敛。

## 现存的边角防御（pipeline 统一后应当一起退场）

- `Transcript2Coordinator.mutationCounter`
- `cacheRefillTask?.cancel()` 的 self-supersede
- `cacheLayouts` 的 skip-if-fresh
- refill onMain 里 `entries.compactMap` 重新解析 idx
- `applyInBackground` 的 fire-and-forget + `Change.insert` id anchor 在 main hop 时 resolve

每一处都是「另一条路插一脚怎么办」的局部 patch。

## 文件

- `Transcript2Coordinator.swift` — 三条路径都在这里
- `Transcript2Controller.swift` — `loadInitial` Phase 2 是 `applyInBackground` 唯一调用方
- `AppKit/Transcript2TableView.swift` — `viewDidEndLiveResize` 调 `refillLayoutCache`
