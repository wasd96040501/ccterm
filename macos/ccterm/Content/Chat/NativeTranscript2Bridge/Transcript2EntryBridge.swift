import AgentSDK
import AppKit
import Foundation

/// 把 `SessionHandle2.onTimelineMutation` 的 entry 级指令翻译成
/// `Transcript2Controller` 的 block 级命令。**纯命令式** —— 不维护
/// "完整 [Block] 镜像然后 diff",只记两张反向表:
///
/// - `entryOrder: [UUID]`:entry 在时间线上的排列顺序。
/// - `entryBlockIds: [UUID: [UUID]]`:entry.id → 该 entry 产生的 Block.id
///   有序列表。
///
/// 当一条 entry mutate 时,先用 builder 算出新 blocks → 跟旧 ids 对比:
/// - 老 / 新 ids 完全一致(典型场景:tool_result merge / confirm / group items
///   增长) → 逐条 `.update(id, kind)`,行级动画 / 选区 / fold 全部保住。
/// - 不一致(罕见:assistant entry 结构变化) → `.remove(old)` + `.insert(new)`,
///   anchor 走前一条 entry 的最后一个 block id。
///
/// **不变量**:`entryOrder` / `entryBlockIds` 在每次 dispatch 完成后跟
/// `handle.messages` 的 entry 序保持一致。Reset 时整体重建,append /
/// prepend / remove 各自就近维护一致。
@MainActor
final class Transcript2EntryBridge {
    let controller: Transcript2Controller

    private var entryOrder: [UUID] = []
    private var entryBlockIds: [UUID: [UUID]] = [:]
    /// 反向标记 `loadInitial` 是否已经发过。在它发之前来的 append / mutate
    /// 都是异常路径(handle 还没 reset)—— 走 fallback,把 entry 直接当 reset
    /// 的种子塞进去,保证不丢内容。
    private var didLoadInitial = false

    init(controller: Transcript2Controller) {
        self.controller = controller
    }

    /// 绑到 handle:每次 mutation 走本对象的 `handle(_:)`。weak 捕获让 handle
    /// 生命周期独立于 view 端 bridge — view dismantle 会让 self deinit,handle
    /// 持的闭包变成 weak-nil,sink 自动失活,无需显式 unbind。
    func attach(to handle: SessionHandle2) {
        handle.onTimelineMutation = { [weak self] mutation in
            self?.handle(mutation)
        }
    }

    // MARK: - Dispatch

    func handle(_ mutation: TimelineMutation) {
        switch mutation {
        case .reset(let entries, let scrollHint):
            apply(reset: entries, scrollHint: scrollHint)
            for entry in entries { pushStatuses(for: entry) }
        case .appended(let entry):
            apply(append: entry)
            pushStatuses(for: entry)
        case .prepended(let entries):
            apply(prepend: entries)
            for entry in entries { pushStatuses(for: entry) }
        case .mutated(let entry):
            apply(mutate: entry)
            pushStatuses(for: entry)
        case .removed(let entry):
            // Block is gone — nothing to push. `Coordinator.applyStructuralChange`
            // already evicted the entry's `statusStates` slots.
            apply(remove: entry)
        }
    }

    // MARK: - Status push
    //
    // Pure command-style status routing: walk the entry's tool surfaces,
    // resolve each one's `ToolStatus`, and forward to
    // `Transcript2Controller.setToolStatus`. `setToolStatus` is
    // idempotent and caches statuses for ids the coordinator hasn't seen
    // yet, so call order vs. the structural change above doesn't matter.
    //
    // **No mirror state.** We don't diff against a previous status map;
    // we re-derive the current status from the entry every time the
    // entry changes. Status derivation is pure:
    //
    // - `tool_result` with `isError == true`  →  `.failed(message: nil)`
    // - `tool_result` present                 →  `.completed`
    // - no `tool_result` yet                  →  `.running`
    //
    // Group status follows the "running == any child running" rule the
    // user spec'd:
    //
    // - single-tool host (`entry|<id>|tg|<idx>`) — one child, so group
    //   status == child status.
    // - `.group` host (`group|<id>`) — `.running` if any nested child is
    //   `.running`, otherwise `.completed`. (No special `.failed` /
    //   `.cancelled` aggregation today; the row reads "completed even if
    //   one child errored" — children carry their own per-row palette.)

    private func pushStatuses(for entry: MessageEntry) {
        switch entry {
        case .single(let single):
            pushSingleEntryStatuses(single)
        case .group(let group):
            pushGroupEntryStatuses(group)
        }
    }

    private func pushSingleEntryStatuses(_ single: SingleEntry) {
        guard case .remote(let m) = single.payload,
              case .assistant(let a) = m,
              let blocks = a.message?.content else { return }
        for (idx, block) in blocks.enumerated() {
            guard case .toolUse(let tu) = block else { continue }
            let toolUseId = tu.id ?? "tu|\(single.id.uuidString)|\(idx)"
            let childId = StableBlockID.derive("tool", toolUseId)
            let result = tu.id.flatMap { single.toolResults[$0] }
            let status = Self.status(for: result)
            controller.setToolStatus(id: childId, status: status)
            // Single-tool host group: group has exactly one child, so
            // group status mirrors that child's status.
            let groupBlockId = StableBlockID.derive(
                "entry", single.id.uuidString, "tg", String(idx))
            controller.setToolStatus(id: groupBlockId, status: status)
        }
    }

    private func pushGroupEntryStatuses(_ group: GroupEntry) {
        var anyRunning = false
        for (itemIdx, item) in group.items.enumerated() {
            guard case .remote(let m) = item.payload,
                  case .assistant(let a) = m,
                  let blocks = a.message?.content else { continue }
            for (blockIdx, block) in blocks.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId = tu.id
                    ?? "tu|\(group.id.uuidString)|\(itemIdx)|\(blockIdx)"
                let childId = StableBlockID.derive("tool", toolUseId)
                let result = tu.id.flatMap { item.toolResults[$0] }
                let status = Self.status(for: result)
                if case .running = status { anyRunning = true }
                controller.setToolStatus(id: childId, status: status)
            }
        }
        let groupId = StableBlockID.derive("group", group.id.uuidString)
        controller.setToolStatus(
            id: groupId, status: anyRunning ? .running : .completed)
    }

    private static func status(for result: ToolResultPayload?) -> ToolStatus {
        guard let result else { return .running }
        if result.isError == true { return .failed(message: nil) }
        return .completed
    }

    // MARK: - Reset (loadInitial / re-entry)

    private func apply(reset entries: [MessageEntry],
                       scrollHint: SavedScrollAnchor?) {
        // 重建反向表 + 收集 blocks
        var newOrder: [UUID] = []
        newOrder.reserveCapacity(entries.count)
        var newMap: [UUID: [UUID]] = [:]
        newMap.reserveCapacity(entries.count)
        var allBlocks: [Block] = []
        for entry in entries {
            let blocks = MessageEntryBlockBuilder.entryBlocks(entry)
            newOrder.append(entry.id)
            newMap[entry.id] = blocks.map(\.id)
            allBlocks.append(contentsOf: blocks)
        }

        // 二次 reset(用户切走再切回 / Phase A 再次触发)走 controller 的
        // 增量 API 比再调一次 `loadInitial` 更稳:Coordinator 已经在 viewport
        // 跑过,blocks 数组直接 swap 反倒会丢动画。这里用 remove-all + insert
        // 一次性把内容刷掉 — 用户视角等价 reload,但走的是同一个 apply 通道。
        if didLoadInitial {
            var changes: [Transcript2Controller.Change] = []
            let oldAllIds = entryOrder.flatMap { entryBlockIds[$0] ?? [] }
            if !oldAllIds.isEmpty {
                changes.append(.remove(ids: oldAllIds))
            }
            if !allBlocks.isEmpty {
                changes.append(.insert(after: nil, allBlocks))
            }
            entryOrder = newOrder
            entryBlockIds = newMap
            // scrollHint 暂不消费 — `Transcript2Controller.apply` 没有「按
            // anchor 跳」的 ScrollState,留到 NativeTranscript2 后续暴露
            // bottomTo / topTo API 后再接。重入时默认贴底 = chat 常规预期。
            _ = scrollHint
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // 首次 reset:走 loadInitial 的两段式快速首屏。
        entryOrder = newOrder
        entryBlockIds = newMap
        didLoadInitial = true
        guard !allBlocks.isEmpty else { return }
        controller.loadInitial(allBlocks, anchor: .bottom)
    }

    // MARK: - Append (live message)

    private func apply(append entry: MessageEntry) {
        let blocks = MessageEntryBlockBuilder.entryBlocks(entry)
        if blocks.isEmpty {
            // entry 不产 block(空 user 消息 / 全 thinking 的 assistant)—— 还是
            // 占用 entryOrder 一个槽,future mutate 找前一条 anchor 不出错。
            entryOrder.append(entry.id)
            entryBlockIds[entry.id] = []
            return
        }
        let anchor = previousEntryLastBlockId(beforeAppending: entry.id)
        entryOrder.append(entry.id)
        entryBlockIds[entry.id] = blocks.map(\.id)

        if !didLoadInitial {
            // sink 在 reset 前到了:用首条 message 当 cold load 的种子。
            didLoadInitial = true
            controller.loadInitial(blocks, anchor: .bottom)
            return
        }
        controller.coordinator.apply(
            [.insert(after: anchor, blocks)], scroll: .none)
    }

    /// 查 entry 即将插入位置前一条 entry 的最后一个 block id;不存在(首条
    /// entry / 前一条没 block)返回 nil(= insert at index 0)。
    private func previousEntryLastBlockId(beforeAppending entryId: UUID) -> UUID? {
        // 调用点保证 entryId 不在 entryOrder 中(尚未加入),所以 entryOrder.last
        // 就是 anchor 来源。.last?.flatMap 走两层 Optional。
        guard let prev = entryOrder.last else { return nil }
        return entryBlockIds[prev]?.last
    }

    // MARK: - Prepend (loadHistory Phase B)

    private func apply(prepend entries: [MessageEntry]) {
        var prefixBlocks: [Block] = []
        var newOrder: [UUID] = []
        var newMap: [UUID: [UUID]] = [:]
        for entry in entries {
            let blocks = MessageEntryBlockBuilder.entryBlocks(entry)
            newOrder.append(entry.id)
            newMap[entry.id] = blocks.map(\.id)
            prefixBlocks.append(contentsOf: blocks)
        }

        entryOrder = newOrder + entryOrder
        for (k, v) in newMap { entryBlockIds[k] = v }

        guard !prefixBlocks.isEmpty else { return }
        // 前插 → `.saveVisible(.visualTop)` 让用户当前看见的首行视觉位置不变。
        controller.coordinator.apply(
            [.insert(after: nil, prefixBlocks)],
            scroll: .saveVisible(.visualTop))
    }

    // MARK: - Mutate (tool_result merge / confirm / group grew)

    private func apply(mutate entry: MessageEntry) {
        let oldIds = entryBlockIds[entry.id] ?? []
        let newBlocks = MessageEntryBlockBuilder.entryBlocks(entry)
        let newIds = newBlocks.map(\.id)

        // 同 id 序列:典型 95% 情况 — 直接逐条 update 即可。
        if oldIds == newIds {
            // 全 0(entry 不产 block)→ 无事可做。
            guard !newIds.isEmpty else { return }
            let changes: [Transcript2Controller.Change] = newBlocks.map {
                .update(id: $0.id, kind: $0.kind)
            }
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // 结构变了:remove 旧 + insert 新,anchor 走前一条 entry。整段视为
        // 原子替换。增量也能写但成本不值 — 这条路径极少触发。
        let anchor = previousEntryLastBlockId(beforeRebuilding: entry.id)
        var changes: [Transcript2Controller.Change] = []
        if !oldIds.isEmpty { changes.append(.remove(ids: oldIds)) }
        if !newBlocks.isEmpty { changes.append(.insert(after: anchor, newBlocks)) }
        entryBlockIds[entry.id] = newIds
        if entryOrder.firstIndex(of: entry.id) == nil {
            // mutate 之前 entry 没注册过(sink 顺序乱了)— 防御性 append,
            // 至少不让 block 孤悬。
            entryOrder.append(entry.id)
        }
        guard !changes.isEmpty else { return }
        controller.coordinator.apply(changes, scroll: .none)
    }

    /// mutate 路径用:entry 还在 entryOrder 里,取它前一位的 last block id。
    private func previousEntryLastBlockId(beforeRebuilding entryId: UUID) -> UUID? {
        guard let idx = entryOrder.firstIndex(of: entryId), idx > 0 else { return nil }
        return entryBlockIds[entryOrder[idx - 1]]?.last
    }

    // MARK: - Remove (cancelMessage)

    private func apply(remove entry: MessageEntry) {
        let ids = entryBlockIds[entry.id] ?? []
        entryBlockIds.removeValue(forKey: entry.id)
        entryOrder.removeAll { $0 == entry.id }
        guard !ids.isEmpty else { return }
        controller.coordinator.apply([.remove(ids: ids)], scroll: .none)
    }
}
