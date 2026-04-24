import AgentSDK
import Foundation
import AppKit

/// 把一串 `MessageEntry` 映射到 `[AnyPreparedItem]` —— 纯函数,通过
/// `TranscriptComponentRegistry` 让每个 component 自己挑出关心的 input。
///
/// 加新 row 类型 = 加一个 `Components/MyComponent.swift` + 在 registry 加一行
/// dispatch。Builder / pipeline / cache 主干代码无需改动。
nonisolated enum TranscriptRowBuilder {

    /// 构造全部 entries 的 prepared items(主入口)。
    nonisolated static func prepareAll(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable] = [:]
    ) -> [AnyPreparedItem] {
        var out: [AnyPreparedItem] = []
        out.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            out.append(contentsOf: TranscriptComponentRegistry.itemsForEntry(
                entry, entryIndex: i,
                theme: theme, width: width,
                stickyStates: stickyStates))
        }
        return out
    }

    // MARK: - Bounded walks (viewport-first)

    struct BoundedPrepareResult {
        let items: [AnyPreparedItem]
        let consumedEntryCount: Int
    }

    nonisolated static func prepareBounded(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        minAccumulatedHeight: CGFloat
    ) -> BoundedPrepareResult {
        var items: [AnyPreparedItem] = []
        var accumulated: CGFloat = 0
        for (idx, entry) in entries.enumerated() {
            let beforeCount = items.count
            items.append(contentsOf: TranscriptComponentRegistry.itemsForEntry(
                entry, entryIndex: idx, theme: theme, width: width,
                stickyStates: stickyStates))
            for i in beforeCount..<items.count { accumulated += items[i].cachedHeight }
            if accumulated >= minAccumulatedHeight {
                return BoundedPrepareResult(items: items, consumedEntryCount: idx + 1)
            }
        }
        return BoundedPrepareResult(items: items, consumedEntryCount: entries.count)
    }

    struct TailBoundedPrepareResult {
        let items: [AnyPreparedItem]
        let phase1StartIndex: Int
    }

    nonisolated static func prepareBoundedTail(
        entries: [MessageEntry],
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        minAccumulatedHeight: CGFloat
    ) -> TailBoundedPrepareResult {
        var reversedGroups: [[AnyPreparedItem]] = []
        var accumulated: CGFloat = 0
        var phase1StartIndex = entries.count

        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let group = TranscriptComponentRegistry.itemsForEntry(
                entries[i], entryIndex: i, theme: theme, width: width,
                stickyStates: stickyStates)
            for item in group { accumulated += item.cachedHeight }
            reversedGroups.append(group)
            phase1StartIndex = i
            if accumulated >= minAccumulatedHeight { break }
        }

        var forward: [AnyPreparedItem] = []
        forward.reserveCapacity(reversedGroups.reduce(0) { $0 + $1.count })
        for group in reversedGroups.reversed() { forward.append(contentsOf: group) }
        return TailBoundedPrepareResult(items: forward, phase1StartIndex: phase1StartIndex)
    }

    struct AroundBoundedPrepareResult {
        let items: [AnyPreparedItem]
        let anchorItemIndex: Int
        let startEntryIndex: Int
        let endEntryIndex: Int
    }

    nonisolated static func prepareBoundedAround(
        entries: [MessageEntry],
        anchorEntryIndex: Int,
        theme: TranscriptTheme,
        width: CGFloat,
        stickyStates: [StableId: any Sendable],
        aboveMinHeight: CGFloat,
        belowMinHeight: CGFloat
    ) -> AroundBoundedPrepareResult {
        guard !entries.isEmpty else {
            return AroundBoundedPrepareResult(
                items: [], anchorItemIndex: 0,
                startEntryIndex: 0, endEntryIndex: -1)
        }
        let anchor = max(0, min(anchorEntryIndex, entries.count - 1))

        let anchorGroup = TranscriptComponentRegistry.itemsForEntry(
            entries[anchor], entryIndex: anchor, theme: theme, width: width,
            stickyStates: stickyStates)
        var belowAccumulated: CGFloat = anchorGroup.reduce(0) { $0 + $1.cachedHeight }
        var aboveAccumulated: CGFloat = 0

        var leftGroups: [[AnyPreparedItem]] = []
        var rightGroups: [[AnyPreparedItem]] = []
        var leftIdx = anchor - 1
        var rightIdx = anchor + 1
        var startIdx = anchor
        var endIdx = anchor

        while (aboveAccumulated < aboveMinHeight && leftIdx >= 0)
            || (belowAccumulated < belowMinHeight && rightIdx < entries.count) {
            if aboveAccumulated < aboveMinHeight, leftIdx >= 0 {
                let group = TranscriptComponentRegistry.itemsForEntry(
                    entries[leftIdx], entryIndex: leftIdx,
                    theme: theme, width: width, stickyStates: stickyStates)
                for item in group { aboveAccumulated += item.cachedHeight }
                leftGroups.append(group)
                startIdx = leftIdx
                leftIdx -= 1
            }
            if belowAccumulated < belowMinHeight, rightIdx < entries.count {
                let group = TranscriptComponentRegistry.itemsForEntry(
                    entries[rightIdx], entryIndex: rightIdx,
                    theme: theme, width: width, stickyStates: stickyStates)
                for item in group { belowAccumulated += item.cachedHeight }
                rightGroups.append(group)
                endIdx = rightIdx
                rightIdx += 1
            }
        }

        var forward: [AnyPreparedItem] = []
        forward.reserveCapacity(
            anchorGroup.count
            + leftGroups.reduce(0) { $0 + $1.count }
            + rightGroups.reduce(0) { $0 + $1.count })
        for group in leftGroups.reversed() { forward.append(contentsOf: group) }
        let anchorItemIdx = forward.count
        forward.append(contentsOf: anchorGroup)
        for group in rightGroups { forward.append(contentsOf: group) }

        return AroundBoundedPrepareResult(
            items: forward,
            anchorItemIndex: anchorItemIdx,
            startEntryIndex: startIdx,
            endEntryIndex: endIdx)
    }
}

// MARK: - Sticky state convenience

extension Dictionary where Key == StableId, Value == any Sendable {
    /// User bubble 折叠态便利入口。每个 entryId 映射到 `UserBubbleComponent.State`
    /// 的 `isExpanded = true`。
    static func expandedUserBubbles(_ entryIds: Set<UUID>) -> [StableId: any Sendable] {
        var out: [StableId: any Sendable] = [:]
        var state = UserBubbleComponent.State()
        state.isExpanded = true
        for id in entryIds {
            out[StableId(entryId: id, locator: .whole)] = state
        }
        return out
    }
}
