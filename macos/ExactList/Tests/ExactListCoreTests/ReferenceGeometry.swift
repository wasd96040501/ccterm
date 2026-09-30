import CoreGraphics
import ExactListCore
import Foundation

/// The Core tests' oracle: geometry, index replay and M2's formulas written the
/// naive way, from values the test generated. It shares no code with the
/// types under test.
enum ReferenceGeometry {

    /// `g(i)`: row `i`'s custom spacing, or `spacing` (G7).
    static func gap(_ customs: [CGFloat?]?, _ row: Int, spacing: CGFloat) -> CGFloat {
        customs?[row] ?? spacing
    }

    /// `y(i)` by a left-to-right running sum (G1): each row starts its own gap
    /// below the one before.
    static func tops(heights: [CGFloat], spacing: CGFloat, customs: [CGFloat?]? = nil) -> [CGFloat] {
        var tops: [CGFloat] = []
        tops.reserveCapacity(heights.count)
        var bottom: CGFloat = 0
        for (row, height) in heights.enumerated() {
            let top = row == 0 ? 0 : bottom + gap(customs, row, spacing: spacing)
            tops.append(top)
            bottom = top + height
        }
        return tops
    }

    /// `H` (G2): where the last row ends.
    static func contentHeight(heights: [CGFloat], spacing: CGFloat, customs: [CGFloat?]? = nil) -> CGFloat {
        guard let last = heights.indices.last else { return 0 }
        return tops(heights: heights, spacing: spacing, customs: customs)[last] + heights[last]
    }

    /// U2 replayed on a plain array of old indexes, one edit at a time, with
    /// `Array.insert` and `Array.remove`. `nil` marks an inserted row. Only the
    /// input type is shared with the code under test.
    static func replay(oldCount: Int, edits: [RowEdit]) -> [Int?] {
        var rows: [Int?] = Array(0..<oldCount)
        for edit in edits {
            switch edit {
            case .insert(let indexes, _):
                for index in indexes { rows.insert(nil, at: index) }
            case .remove(let indexes, _):
                for index in indexes.reversed() { rows.remove(at: index) }
            case .move(let from, let to):
                rows.insert(rows.remove(at: from), at: to)
            case .noteHeight, .reload:
                break
            }
        }
        return rows
    }

    /// M2 at progress `p`: `end + (start − end)·(1 − p)`.
    static func presented(start: CGFloat, end: CGFloat, progress p: CGFloat) -> CGFloat {
        end + (start - end) * (1 - p)
    }
}
