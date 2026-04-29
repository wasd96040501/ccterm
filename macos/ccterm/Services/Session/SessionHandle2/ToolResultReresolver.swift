import Foundation
import AgentSDK

/// Phase B (full history load) 完成后调用，把 Phase A 阶段因跨 tail 边界而
/// 遗留的 unresolved tool_results 就地解决掉。
///
/// 与 `Message2Resolver.resolveFields` 等价 —— 但用 **外部传入** 的
/// `[toolUseId: ToolUse]` index，而非依赖 resolver 的内部状态。这样就能在「两段
/// 拼接」后给 tail 切片做一次性回填，无需改动 generated resolver。
enum ToolResultReresolver {

    /// 扫描 `messages` 里所有 assistant block 的 tool_use，聚合成
    /// `[toolUseId: ToolUse]`。
    static func buildToolUseIndex(from messages: [Message2]) -> [String: ToolUse] {
        var index: [String: ToolUse] = [:]
        for m in messages {
            guard case .assistant(let a) = m,
                  let content = a.message?.content else { continue }
            for item in content {
                if case .toolUse(let tu) = item, let id = tu.id {
                    index[id] = tu
                }
            }
        }
        return index
    }

    /// 对 `entries[fromIndex...]` 区间的每个 `.single(.remote(.user))`：如果
    /// `toolUseResult` 是 unresolved object 且能在 `index` 里查到对应 origin
    /// tool_use，就地 resolve。
    ///
    /// 返回被修改的 entry 下标集合（调用点可用它决定是否必要触发 UI 刷新）。
    /// 当前实现会把 entries 的 entry.id 保持不变 —— TranscriptDiff 识别
    /// contentHash 变化会走 updated 路径。
    @discardableResult
    static func applyResolution(
        to entries: inout [MessageEntry],
        from tailIndex: Int,
        using index: [String: ToolUse]
    ) -> [Int] {
        guard tailIndex < entries.count, !index.isEmpty else { return [] }
        var updated: [Int] = []
        for i in tailIndex..<entries.count {
            switch entries[i] {
            case .single(var single):
                if reResolvePayload(&single.payload, using: index) {
                    entries[i] = .single(single)
                    updated.append(i)
                }
            case .group(var group):
                var anyChanged = false
                for j in group.items.indices {
                    var s = group.items[j]
                    if reResolvePayload(&s.payload, using: index) {
                        group.items[j] = s
                        anyChanged = true
                    }
                }
                if anyChanged {
                    entries[i] = .group(group)
                    updated.append(i)
                }
            }
        }
        return updated
    }

    /// 对 SingleEntry.payload 做一次 re-resolve（仅 `.remote(.user)` 生效）。
    /// 返回是否真的修改了 payload。
    private static func reResolvePayload(
        _ payload: inout SingleEntry.Payload,
        using index: [String: ToolUse]
    ) -> Bool {
        guard case .remote(var msg) = payload else { return false }
        guard case .user(var parent) = msg else { return false }
        guard case .object(var obj)? = parent.toolUseResult, obj.isUnresolved else { return false }

        // 找到 tool_result block 的 toolUseId，去 index 查 origin。
        guard case .array(let items)? = parent.message?.content else { return false }
        for item in items {
            if case .toolResult(let result) = item,
               let lookupKey = result.toolUseId,
               let origin = index[lookupKey] {
                try? obj.resolve(from: origin)
                parent.toolUseResult = .object(obj)
                msg = .user(parent)
                payload = .remote(msg)
                return true
            }
        }
        return false
    }
}
