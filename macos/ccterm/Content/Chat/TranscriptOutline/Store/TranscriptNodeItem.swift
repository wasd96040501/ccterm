import Foundation

/// Stable reference handle the store vends as `NSOutlineView` items.
///
/// `NSOutlineView` requires each item to keep the same pointer and stay
/// `isEqual`-consistent across queries so it can track expansion state
/// (see the class docs). `TranscriptNode` is a value type (SPEC §8
/// decision 1), so the store builds one box per node **once** at load
/// and hands the same instances back on every `child(_:ofItem:)` call —
/// pointer identity is trivially stable because the tree is immutable
/// after a one-shot load.
///
/// This is a store implementation detail for outline identity, not the
/// node model itself.
final class TranscriptNodeItem {
    let node: TranscriptNode
    let children: [TranscriptNodeItem]

    init(node: TranscriptNode) {
        self.node = node
        self.children = node.children.map(TranscriptNodeItem.init)
    }

    var id: UUID { node.id }
    var isExpandable: Bool { node.isExpandable }
}
