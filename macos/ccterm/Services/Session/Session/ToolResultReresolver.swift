import AgentSDK
import Foundation

/// Called after Phase B (full history load) completes; resolves any
/// unresolved tool_results that Phase A left behind because their origin
/// tool_use sat across the tail boundary.
///
/// Equivalent to `Message2Resolver.resolveFields`, but uses an
/// **externally supplied** `[toolUseId: ToolUse]` index instead of the
/// resolver's internal state. That lets us do a single-pass backfill on
/// the tail slice after the two pieces are stitched together, without
/// modifying the generated resolver.
enum ToolResultReresolver {

    /// Walk every assistant block's tool_use in `messages` and aggregate
    /// into `[toolUseId: ToolUse]`.
    static func buildToolUseIndex(from messages: [Message2]) -> [String: ToolUse] {
        var index: [String: ToolUse] = [:]
        for m in messages {
            guard case .assistant(let a) = m,
                let content = a.message?.content
            else { continue }
            for item in content {
                if case .toolUse(let tu) = item, let id = tu.id {
                    index[id] = tu
                }
            }
        }
        return index
    }

    /// For each `.single(.remote(.user))` in `entries[fromIndex...]`: if
    /// `toolUseResult` is an unresolved object and the index has the
    /// origin tool_use, resolve in place.
    ///
    /// Returns the indices of mutated entries (callers can use it to
    /// decide whether to trigger a UI refresh). The current implementation
    /// keeps `entry.id` stable — TranscriptDiff sees the contentHash
    /// change and routes through the updated path.
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

    /// Re-resolve a single payload (effective only for `.remote(.user)`).
    /// Returns whether the payload actually changed.
    private static func reResolvePayload(
        _ payload: inout SingleEntry.Payload,
        using index: [String: ToolUse]
    ) -> Bool {
        guard case .remote(var msg) = payload else { return false }
        guard case .user(var parent) = msg else { return false }
        guard case .object(var obj)? = parent.toolUseResult, obj.isUnresolved else { return false }

        // Find the tool_result block's toolUseId and look up its origin
        // in the index.
        guard case .array(let items)? = parent.message?.content else { return false }
        for item in items {
            if case .toolResult(let result) = item,
                let lookupKey = result.toolUseId,
                let origin = index[lookupKey]
            {
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
