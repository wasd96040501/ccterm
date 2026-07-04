import AppKit

/// Delegate protocol for `BlockCellView`. Replaces the cell's former
/// typed reference to `Transcript2Coordinator` so the cell doesn't hard-
/// depend on the old renderer stack; both the old coordinator (still
/// alive on the live-CLI path inside `Session.swift`) and the new
/// `TranscriptViewController` (history path) adopt it. Class-only + main-
/// actor because every reach-through touches AppKit state.
///
/// The full method list is derived from every `coordinator?.…` call site
/// in `BlockCellView.swift` / `BlockCellView+Gutter.swift` /
/// `BlockCellView+SubviewPlan.swift`.
@MainActor
protocol BlockCellViewDelegate: AnyObject {
    /// Which block the cursor is over. Set on `mouseEntered`, cleared on
    /// `mouseExited`. Read by hover-brightening code so a repaint routed
    /// through `reloadData(forRowIndexes:)` picks up the right cell.
    var hoveredBlockId: UUID? { get set }

    /// True while the enclosing scroll view is in `willStartLiveScroll` /
    /// `didEndLiveScroll`. Cell suppresses hover writes during scroll for
    /// § 2 perf reasons; owner tracks the state.
    var isLiveScrolling: Bool { get }

    /// User clicked a toggle-fold chevron on a tool-group header or child
    /// header. `id` can be a group host `Block.id` OR a `Child.id` — owner
    /// resolves.
    func toggleFold(id: UUID)

    /// User clicked the `>` chevron on a user-bubble to open the full-text
    /// sheet. History-only path currently no-ops (see plan § 14).
    func requestUserBubbleSheet(id: UUID)

    /// User clicked an image chip inside a user-attachments row. History-
    /// only path currently no-ops.
    func requestImagePreview(image: NSImage)

    /// User clicked a copy chrome (code block / bash sub-card / diff
    /// gutter). `spec` carries the payload + button id.
    func handleGutter(_ spec: GutterSpec, blockId: UUID)
}
