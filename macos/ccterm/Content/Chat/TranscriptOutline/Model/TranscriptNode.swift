import Foundation

/// One node in the outline transcript tree: the hierarchy plus a single
/// render payload per node. Value type (SPEC §8 decision 1) — the tree
/// is built once by the store's tree-ification and is immutable
/// thereafter (one-shot blocking load, no live mutation). The store
/// wraps each node in a stable reference handle (`TranscriptNodeItem`)
/// for `NSOutlineView` item identity; this type stays a pure value.
///
/// Layering: Model. No `import AppKit`, no UI logic — it only carries
/// the data + the already-decided render payload. Turning a payload into
/// a `RowLayout` is the store's job.
struct TranscriptNode: Identifiable {
    /// Stable identity (SHA-derived via `StableBlockID`), used as the
    /// layout-cache key and the outline's item identity.
    let id: UUID
    let content: Content
    let children: [TranscriptNode]

    init(id: UUID, content: Content, children: [TranscriptNode] = []) {
        self.id = id
        self.content = content
        self.children = children
    }

    /// The native outline draws a disclosure triangle and hosts children
    /// exactly when a node has any. Tool-group headers and tool headers
    /// carry children; markdown / user / tool-body nodes are leaves.
    var isExpandable: Bool { !children.isEmpty }

    /// The render payload. Each case maps to a `RowLayout` in the store's
    /// `makeRowLayout`.
    enum Content {
        /// A markdown top node (heading / paragraph / list / table /
        /// codeBlock / blockquote / thematicBreak), a user bubble, or a
        /// user-attachments strip — anything a single existing `Block`
        /// renders. Always a leaf.
        case block(Block)
        /// A tool-group header or a tool header — title only; the native
        /// disclosure triangle owns the arrow. Always expandable (has
        /// children).
        case header(title: String)
        /// A single tool's expanded body, rendered through the reused
        /// `ToolGroupChildLayout`. Always a leaf.
        case toolBody(ToolGroupBlock.Child)
    }
}
