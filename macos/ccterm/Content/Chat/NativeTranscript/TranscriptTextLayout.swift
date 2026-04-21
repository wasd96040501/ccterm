import AppKit
import CoreText

/// Immutable Core Text layout result: the laid-out lines + per-line geometry.
///
/// Produced by ``TranscriptTextRenderer/makeLayout(attributed:maxWidth:)`` and
/// drawn by ``TranscriptTextRenderer/draw(_:origin:in:)``. Stored on each row
/// item so resize invalidates and re-builds only what's needed.
///
/// 坐标约定:所有坐标都是 flipped (y 向下递增,原点在 layout 左上)。
/// - `lineOrigins[i]`:第 i 行的 baseline。x 为左侧偏移(考虑 paragraph indent),
///   y 为从 layout 顶部到 baseline 的距离。
struct TranscriptTextLayout {
    let attributed: NSAttributedString
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    static let empty = TranscriptTextLayout(
        attributed: NSAttributedString(),
        lines: [],
        lineOrigins: [],
        totalHeight: 0,
        measuredWidth: 0)
}
