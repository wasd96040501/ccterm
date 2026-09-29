import CoreGraphics

/// Every row's height, the spacing between rows, and the index that answers
/// geometry queries (SPEC §5).
///
/// Row `i`'s top is `Σ_{k<i} h(k) + i·s` (G1), found through a Fenwick index
/// over the heights, so a query and a height change are O(log n) (G5). A
/// structural change copies the heights run by run at commit, once per batch,
/// and rebuilds the index only from the first row it touches.
///
/// The spacing is kept apart from the sums, so changing it (V3) touches no
/// entry.
public struct RowHeights: Equatable, Sendable {

    /// `s`, the gap between two adjacent rows.
    public var spacing: CGFloat

    private var heights: [CGFloat]

    private var index: FenwickIndex

    /// Builds the index in O(n). Every height must be finite and > 0 (L12).
    public init(_ heights: [CGFloat] = [], spacing: CGFloat = 0) {
        for height in heights {
            precondition(height.isFinite && height > 0, "ExactList: a row height must be finite and > 0 (L12)")
        }
        self.spacing = spacing
        self.heights = heights
        self.index = FenwickIndex(heights)
    }

    /// Heights already checked, with the index of `base` kept for the first
    /// `unchanged` rows, which `heights` shares with it.
    private init(_ heights: [CGFloat], spacing: CGFloat, reusing base: FenwickIndex, unchanged: Int) {
        self.spacing = spacing
        self.heights = heights
        self.index = FenwickIndex(heights, reusing: base, unchanged: unchanged)
    }

    /// `n`.
    public var count: Int {
        heights.count
    }

    /// `h(row)`.
    public subscript(row: Int) -> CGFloat {
        precondition(heights.indices.contains(row), "ExactList: row \(row) out of range 0..<\(count) (L12)")
        return heights[row]
    }

    /// The heights in row order: what the next commit rebuilds from.
    public var values: [CGFloat] {
        heights
    }

    /// `H`: `Σ h + (n − 1)·s`, or 0 for no rows (G2).
    public var contentHeight: CGFloat {
        heights.isEmpty ? 0 : index.prefix(count) + CGFloat(count - 1) * spacing
    }

    /// `y(row)` (G1). O(log n).
    public func top(ofRow row: Int) -> CGFloat {
        precondition(row >= 0 && row <= count, "ExactList: row \(row) out of range 0...\(count) (L12)")
        return index.prefix(row) + CGFloat(row) * spacing
    }

    /// The row whose `[y, y + h)` contains `y`, or `nil` when `y` falls in a
    /// spacing gap or outside the content (G4). O(log n).
    public func row(containingY y: CGFloat) -> Int? {
        let (row, above) = rowsEnding(atOrAbove: y)
        guard row < count, above + CGFloat(row) * spacing <= y else { return nil }
        return row
    }

    /// The smallest `a` with `y(a) + h(a) > y`: the first row not entirely
    /// above `y` (A1). `nil` when every row is above it. O(log n).
    public func firstRow(endingBelow y: CGFloat) -> Int? {
        let row = rowsEnding(atOrAbove: y).count
        return row < count ? row : nil
    }

    /// The rows whose frames intersect the document interval `[lower, upper]`
    /// (G4, P1). O(log n).
    public func rows(intersecting lower: CGFloat, _ upper: CGFloat) -> Range<Int> {
        // A row that only touches an end of the interval is outside it, as with
        // `CGRect.intersects`; an interval of one point gives the row containing it.
        if upper < lower { return 0..<0 }
        if upper == lower {
            guard let row = row(containingY: lower) else { return 0..<0 }
            return row..<(row + 1)
        }
        let first = rowsEnding(atOrAbove: lower).count
        let end = rowsStarting(below: upper)
        return first < end ? first..<end : 0..<0
    }

    /// Changes one row's height. O(log n) (G5).
    public mutating func setHeight(_ height: CGFloat, ofRow row: Int) {
        precondition(heights.indices.contains(row), "ExactList: row \(row) out of range 0..<\(count) (L12)")
        precondition(height.isFinite && height > 0, "ExactList: a row height must be finite and > 0 (L12)")
        index.add(height - heights[row], atRow: row)
        heights[row] = height
    }

    /// The heights after `map` (G5): a surviving or moved row keeps its height
    /// unless the batch noted it; inserted and noted rows are asked through
    /// `height`, in ascending new order. O(k · log n) for a batch that
    /// inserts, removes and moves nothing; otherwise one O(n) copy, run by run,
    /// and an index rebuilt only after the leading rows the batch leaves alone.
    public func applying(_ map: RowIndexMap, height: (Int) -> CGFloat) -> RowHeights {
        precondition(map.oldCount == count, "ExactList: a map over \(map.oldCount) rows applied to \(count)")
        var asked = map.notedRows
        guard map.isStructural else {
            var result = self
            for row in asked { result.setHeight(height(row), ofRow: row) }
            return result
        }
        var values: [CGFloat] = []
        values.reserveCapacity(map.newCount)
        for run in map.runs {
            switch run {
            case .kept(let old, _, let count):
                values += heights[old..<(old + count)]
            case .moved(let old, _):
                values.append(heights[old])
            case .inserted(let new, let count, _):
                values += repeatElement(0, count: count)
                asked.insert(integersIn: new..<(new + count))
            }
        }
        for row in asked {
            let value = height(row)
            precondition(value.isFinite && value > 0, "ExactList: a row height must be finite and > 0 (L12)")
            values[row] = value
        }
        var unchanged = 0
        if case .kept(0, 0, let count) = map.runs.first { unchanged = count }
        if let first = asked.first { unchanged = min(unchanged, first) }
        return RowHeights(values, spacing: spacing, reusing: index, unchanged: unchanged)
    }

    /// How many leading rows end at or above `y`, with the sum of their heights.
    private func rowsEnding(atOrAbove y: CGFloat) -> (count: Int, sum: CGFloat) {
        index.lift { k, sum in sum + CGFloat(k - 1) * spacing <= y }
    }

    /// How many leading rows start above `y`.
    private func rowsStarting(below y: CGFloat) -> Int {
        guard count > 0, y > 0 else { return 0 }
        // Rows 0...k start above `y` exactly when `y(k) < y`, and `y(k)` is the
        // sum of the first k heights plus k gaps.
        let k = index.lift { k, sum in sum + CGFloat(k) * spacing < y }.count
        return min(k + 1, count)
    }

    /// A 1-based Fenwick tree of partial sums over the heights. It is derived
    /// from the heights, so it takes no part in equality: two values with the
    /// same heights are equal however their sums were accumulated.
    private struct FenwickIndex: Equatable, Sendable {

        private var tree: [CGFloat]

        init(_ heights: [CGFloat]) {
            self.init(heights, reusing: nil, unchanged: 0)
        }

        /// The index over `heights`, whose first `unchanged` rows are those of
        /// `base`: node `i` sums rows `(i − lowbit(i), i]`, so the nodes up to
        /// `unchanged` are `base`'s. Each later node is its row plus its
        /// children, added in the order a full build adds them. O(n − unchanged).
        init(_ heights: [CGFloat], reusing base: FenwickIndex?, unchanged: Int) {
            var tree = [CGFloat]()
            tree.reserveCapacity(heights.count + 1)
            if let base, unchanged > 0 {
                tree += base.tree[0...unchanged]
            } else {
                tree.append(0)
            }
            for i in tree.count..<(heights.count + 1) {
                var sum = heights[i - 1]
                var step = (i & -i) / 2
                while step > 0 {
                    sum += tree[i - step]
                    step /= 2
                }
                tree.append(sum)
            }
            self.tree = tree
        }

        static func == (lhs: FenwickIndex, rhs: FenwickIndex) -> Bool {
            true
        }

        /// The sum of the first `k` heights.
        func prefix(_ k: Int) -> CGFloat {
            var sum: CGFloat = 0
            var i = k
            while i > 0 {
                sum += tree[i]
                i &= i - 1
            }
            return sum
        }

        mutating func add(_ delta: CGFloat, atRow row: Int) {
            var i = row + 1
            while i < tree.count {
                tree[i] += delta
                i += i & -i
            }
        }

        /// The largest `k` for which `accepts(k, sum of the first k heights)`,
        /// found by binary lifting. `accepts` must hold for a prefix of `1...n`.
        func lift(_ accepts: (Int, CGFloat) -> Bool) -> (count: Int, sum: CGFloat) {
            let n = tree.count - 1
            var position = 0
            var sum: CGFloat = 0
            var step = 1
            while step * 2 <= n { step *= 2 }
            while step > 0 {
                let next = position + step
                if next <= n, accepts(next, sum + tree[next]) {
                    position = next
                    sum += tree[next]
                }
                step /= 2
            }
            return (position, sum)
        }
    }
}
