import CoreGraphics
import ExactListCore
import Foundation

/// The Core tests' oracle: geometry, index replay and M2's formulas written the
/// naive way, from values the test generated. It shares no code with the
/// types under test.
enum ReferenceGeometry {

    /// `y(i)` by a left-to-right running sum (G1).
    static func tops(heights: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        tops.reserveCapacity(heights.count)
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + spacing
        }
        return tops
    }

    /// `H` (G2).
    static func contentHeight(heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.isEmpty ? 0 : heights.reduce(0, +) + CGFloat(heights.count - 1) * spacing
    }

    /// U2 replayed on a plain array of old indexes, one edit at a time, with
    /// `Array.insert` and `Array.remove`. `nil` marks an inserted row. Only the
    /// input type is shared with the code under test.
    static func replay(oldCount: Int, edits: [RowEdit]) -> [Int?] {
        fatalError("unimplemented: test support")
    }

    /// M2 at progress `p`: `end + (start − end)·(1 − p)`.
    static func presented(start: CGFloat, end: CGFloat, progress p: CGFloat) -> CGFloat {
        end + (start - end) * (1 - p)
    }
}
