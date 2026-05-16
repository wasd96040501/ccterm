import AgentSDK
import AppKit
import Foundation

/// Translates entry-level instructions from `SessionHandle2.onMessagesChange`
/// into block-level commands for `Transcript2Controller`. **Purely imperative**
/// — does not maintain a full `[Block]` mirror to diff against; just two
/// reverse tables:
///
/// - `entryOrder: [UUID]`: timeline order of entries.
/// - `entryBlockIds: [UUID: [UUID]]`: entry.id → ordered list of Block.ids
///   produced by that entry.
///
/// On entry update: run the builder to compute new blocks, then compare to old
/// ids:
/// - identical id sequences (typical: tool_result merge / confirm / group items
///   grew) → per-block `.update(id, kind)`, preserving row-level animation /
///   selection / fold.
/// - mismatched (rare: assistant entry structure changed) → `.remove(old)` +
///   `.insert(new)`, anchored to the previous entry's last block id.
///
/// **Invariant**: after every dispatch, `entryOrder` / `entryBlockIds` match
/// `handle.messages`'s entry order. Reset rebuilds wholesale; append / prepend
/// / remove each maintain consistency locally.
@MainActor
final class Transcript2EntryBridge {
    let controller: Transcript2Controller

    private var entryOrder: [UUID] = []
    private var entryBlockIds: [UUID: [UUID]] = [:]
    /// Tracks whether `loadInitial` has fired. Any append / update arriving
    /// before it is the abnormal path (handle hasn't reset yet) — fall back
    /// by treating the entry as a reset seed so content isn't lost.
    private var didLoadInitial = false

    init(controller: Transcript2Controller) {
        self.controller = controller
    }

    /// Bind to a handle: every change flows through this object's `apply(_:)`.
    /// Weak capture decouples the handle's lifetime from the view-side bridge —
    /// view dismantle deinits self, the handle's closure becomes weak-nil, and
    /// the sink deactivates automatically. No explicit unbind needed.
    func attach(to handle: SessionHandle2) {
        handle.onMessagesChange = { [weak self] change in
            self?.apply(change)
        }
    }

    // MARK: - Dispatch

    func apply(_ change: MessagesChange) {
        switch change {
        case .reset(let entries):
            applyReset(entries)
            for entry in entries { pushStatuses(for: entry) }
        case .appended(let entry):
            applyAppend(entry)
            pushStatuses(for: entry)
        case .prepended(let entries):
            applyPrepend(entries)
            for entry in entries { pushStatuses(for: entry) }
        case .updated(let entry):
            applyUpdate(entry)
            pushStatuses(for: entry)
        case .removed(let entry):
            // Block is gone — nothing to push. `Coordinator.applyStructuralChange`
            // already evicted the entry's `statusStates` slots.
            applyRemove(entry)
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
            let blocks = a.message?.content
        else { return }
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
                let blocks = a.message?.content
            else { continue }
            for (blockIdx, block) in blocks.enumerated() {
                guard case .toolUse(let tu) = block else { continue }
                let toolUseId =
                    tu.id
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

    private func applyReset(_ entries: [MessageEntry]) {
        // Rebuild reverse tables and collect blocks.
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

        // Second reset (user navigated away then back / Phase A re-fires) goes
        // through the controller's incremental API rather than another
        // `loadInitial`: the Coordinator has already viewport-rendered, and a
        // blunt blocks-array swap would lose animation. Use remove-all +
        // insert in one batch — visually a reload, but on the apply channel.
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
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // First reset: take loadInitial's two-phase fast first-screen path.
        entryOrder = newOrder
        entryBlockIds = newMap
        didLoadInitial = true
        guard !allBlocks.isEmpty else { return }
        controller.loadInitial(allBlocks, anchor: .bottom)
    }

    // MARK: - Append (live message)

    private func applyAppend(_ entry: MessageEntry) {
        let blocks = MessageEntryBlockBuilder.entryBlocks(entry)
        if blocks.isEmpty {
            // Entry produced no block (empty user message / all-thinking
            // assistant) — still take an entryOrder slot so a future mutate
            // can resolve the previous-entry anchor correctly.
            entryOrder.append(entry.id)
            entryBlockIds[entry.id] = []
            return
        }
        let anchor = previousEntryLastBlockId(beforeAppending: entry.id)
        entryOrder.append(entry.id)
        entryBlockIds[entry.id] = blocks.map(\.id)

        if !didLoadInitial {
            // Sink fired before reset: use the first message as cold-load seed.
            didLoadInitial = true
            controller.loadInitial(blocks, anchor: .bottom)
            return
        }
        controller.coordinator.apply(
            [.insert(after: anchor, blocks)], scroll: .none)
    }

    /// Last block id of the entry preceding the insertion point. Returns nil
    /// (= insert at index 0) when there is no predecessor (first entry / prior
    /// entry produced no blocks).
    private func previousEntryLastBlockId(beforeAppending entryId: UUID) -> UUID? {
        // Callers guarantee entryId is not yet in entryOrder, so entryOrder.last
        // is the anchor source.
        guard let prev = entryOrder.last else { return nil }
        return entryBlockIds[prev]?.last
    }

    // MARK: - Prepend (loadHistory Phase B)

    private func applyPrepend(_ entries: [MessageEntry]) {
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
        // Prepend → `.saveVisible(.visualTop)` keeps the user's currently
        // visible first line at the same visual position.
        controller.coordinator.apply(
            [.insert(after: nil, prefixBlocks)],
            scroll: .saveVisible(.visualTop))
    }

    // MARK: - Update (tool_result merge / confirm / group grew)

    private func applyUpdate(_ entry: MessageEntry) {
        let oldIds = entryBlockIds[entry.id] ?? []
        let newBlocks = MessageEntryBlockBuilder.entryBlocks(entry)
        let newIds = newBlocks.map(\.id)

        // Identical id sequence: the typical 95% case — per-block update.
        if oldIds == newIds {
            // All-empty (entry produces no block) → nothing to do.
            guard !newIds.isEmpty else { return }
            let changes: [Transcript2Controller.Change] = newBlocks.map {
                .update(id: $0.id, kind: $0.kind)
            }
            controller.coordinator.apply(changes, scroll: .none)
            return
        }

        // Structure changed: remove old + insert new, anchored to the previous
        // entry. Atomic replacement of the whole segment. A finer-grained diff
        // is possible but not worth the cost — this path almost never fires.
        let anchor = previousEntryLastBlockId(beforeRebuilding: entry.id)
        var changes: [Transcript2Controller.Change] = []
        if !oldIds.isEmpty { changes.append(.remove(ids: oldIds)) }
        if !newBlocks.isEmpty { changes.append(.insert(after: anchor, newBlocks)) }
        entryBlockIds[entry.id] = newIds
        if entryOrder.firstIndex(of: entry.id) == nil {
            // Entry was never registered before this update (out-of-order
            // sink). Defensively append so the block doesn't hang loose.
            entryOrder.append(entry.id)
        }
        guard !changes.isEmpty else { return }
        controller.coordinator.apply(changes, scroll: .none)
    }

    /// Update path: entry is still in entryOrder; return the predecessor's
    /// last block id.
    private func previousEntryLastBlockId(beforeRebuilding entryId: UUID) -> UUID? {
        guard let idx = entryOrder.firstIndex(of: entryId), idx > 0 else { return nil }
        return entryBlockIds[entryOrder[idx - 1]]?.last
    }

    // MARK: - Remove (cancelMessage)

    private func applyRemove(_ entry: MessageEntry) {
        let ids = entryBlockIds[entry.id] ?? []
        entryBlockIds.removeValue(forKey: entry.id)
        entryOrder.removeAll { $0 == entry.id }
        guard !ids.isEmpty else { return }
        controller.coordinator.apply([.remove(ids: ids)], scroll: .none)
    }
}
