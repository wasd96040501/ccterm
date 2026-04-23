import AppKit

/// `FragmentRow.fragments(width:)` 的返回包：fragment 列表 + row 的总高度。
///
/// 单独返回 `height` 而非让基类从 `max(frame.maxY)` 推断，是因为 row 的
/// 高度可能**大于**任何 fragment 的 maxY（例如底部 rowVerticalPadding 不对
/// 应任何可见 fragment），也可能**小于**（固定高度占位符 + 内嵌较矮的 rect）。
/// 把 height 当成显式协议输出让调用方不必靠"最后一个 fragment 的底"约定。
struct FragmentLayout {
    let fragments: [Fragment]
    /// 整 row 的高度。基类 `makeSize` 赋给 `cachedHeight`，
    /// NSTableView 通过 `heightOfRow` 读到它。
    let height: CGFloat

    static let empty = FragmentLayout(fragments: [], height: 0)
}

/// Opt-in protocol: a ``TranscriptRow`` subclass vends its visuals as a
/// `FragmentLayout` (fragment list + explicit total height) instead of
/// overriding `draw(in:bounds:)`.
///
/// The base ``TranscriptRow`` picks up conformance dynamically in its
/// default `makeSize(width:)` — if `self as? FragmentRow` succeeds, it
/// caches the fragments + height and derives draw / selection / hit-test
/// from them. Non-adopting rows continue to override `makeSize` / `draw`
/// as before; the two paths coexist during migration.
///
/// Per performance rule #3 in the plan: the protocol is only read **once**
/// per width change (in `makeSize`). All hot paint / hit / selection work
/// operates on the cached `[Fragment]`, which is a concrete enum array and
/// does not go through protocol existentials.
@MainActor
protocol FragmentRow: AnyObject {
    /// Produce the fragment layout for the given row width. Called from
    /// `makeSize(width:)` after the width changes; the result is cached and
    /// reused by `draw` / hit-test / selection until the next width change
    /// or explicit invalidation.
    ///
    /// Implementations should wrap **already-computed** layout primitives
    /// (`TranscriptTextLayout`, `TranscriptTableLayout`,
    /// `TranscriptListLayout`) — no CoreText rework per repaint.
    func fragments(width: CGFloat) -> FragmentLayout

    /// Syntax-highlight writeback hook. Default: no-op. Rows that vend
    /// `.text` fragments with `highlightTag` override this to fold tokens
    /// back into their prebuilt state and invalidate cached layout
    /// (typically by zeroing `cachedWidth` + `cachedFragments` so the next
    /// `makeSize` re-runs `fragments(width:)`).
    func applyTokens(_ tokens: [AnyHashable: [SyntaxToken]])
}

extension FragmentRow {
    func applyTokens(_ tokens: [AnyHashable: [SyntaxToken]]) {}
}
