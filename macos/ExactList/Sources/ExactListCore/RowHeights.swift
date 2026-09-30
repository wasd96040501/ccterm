import CoreGraphics

/// Every row's height, the spacing above each row, and the index that answers
/// geometry queries (SPEC §5).
///
/// Row `i`'s top is `Σ_{k<i} h(k) + Σ_{1≤k≤i} g(k)` (G1), found through a
/// Fenwick index over each row's height plus the spacing above it (none for
/// row 0, which has no row above), so a query, a height change and a spacing
/// change are O(log n) (G5). A structural change copies the rows run by run at
/// commit, once per batch, and rebuilds the index only from the first row it
/// touches.
///
/// A row's spacing is its custom one, or `spacing` when it has none (G7).
public struct RowHeights: Equatable, Sendable {

    /// `s`, the default gap: the spacing above every row without a custom one.
    /// Changing it re-resolves those rows, in one O(n) pass (V3, G5).
    public var spacing: CGFloat {
        didSet {
            if spacing != oldValue { index = FenwickIndex(weights) }
        }
    }

    private var heights: [CGFloat]

    /// Each row's custom spacing above it; `nil` is `spacing`. It belongs to
    /// the row wherever the row goes, so row 0 keeps one too.
    private var customSpacings: [CGFloat?]

    private var index: FenwickIndex

    /// Builds the index in O(n). Every height must be finite and > 0, and every
    /// custom spacing finite and ≥ 0 (L12). No custom spacings means every row
    /// is `spacing` apart.
    public init(_ heights: [CGFloat] = [], customSpacings: [CGFloat?]? = nil, spacing: CGFloat = 0) {
        for height in heights {
            precondition(height.isFinite && height > 0, "ExactList: a row height must be finite and > 0 (L12)")
        }
        let customSpacings = customSpacings ?? Array(repeating: nil, count: heights.count)
        precondition(customSpacings.count == heights.count, "ExactList: a spacing for every row")
        for custom in customSpacings { Self.check(custom) }
        self.spacing = spacing
        self.heights = heights
        self.customSpacings = customSpacings
        self.index = FenwickIndex([])
        self.index = FenwickIndex(weights)
    }

    /// Rows already checked, with the index of `base` kept for the first
    /// `unchanged` rows, which these rows share with it.
    private init(
        _ heights: [CGFloat], customSpacings: [CGFloat?], spacing: CGFloat, reusing base: FenwickIndex,
        unchanged: Int
    ) {
        self.spacing = spacing
        self.heights = heights
        self.customSpacings = customSpacings
        self.index = base
        self.index = FenwickIndex(weights, reusing: base, unchanged: unchanged)
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

    /// `g(row)`: the row's custom spacing, or `spacing` (G7). It is the row's
    /// own, so row 0 answers one too, which takes no space while it is first.
    public func spacing(aboveRow row: Int) -> CGFloat {
        precondition(heights.indices.contains(row), "ExactList: row \(row) out of range 0..<\(count) (L12)")
        return customSpacings[row] ?? spacing
    }

    /// `H`: `Σ h + Σ_{1≤k<n} g(k)`, or 0 for no rows (G2).
    public var contentHeight: CGFloat {
        index.prefix(count)
    }

    /// `y(row)` (G1). O(log n). `y(n)` is where a row after the last would
    /// start, `spacing` below it.
    public func top(ofRow row: Int) -> CGFloat {
        precondition(row >= 0 && row <= count, "ExactList: row \(row) out of range 0...\(count) (L12)")
        if row == 0 { return 0 }
        if row == count { return index.prefix(count) + spacing }
        return index.prefix(row) + gap(aboveRow: row)
    }

    /// The row whose `[y, y + h)` contains `y`, or `nil` when `y` falls in a
    /// spacing gap or outside the content (G4). O(log n).
    public func row(containingY y: CGFloat) -> Int? {
        let (row, above) = rowsEnding(atOrAbove: y)
        guard row < count, above + gap(aboveRow: row) <= y else { return nil }
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

    /// Changes one row's custom spacing; `nil` is `spacing`. O(log n) (G5, G7).
    public mutating func setSpacing(_ custom: CGFloat?, aboveRow row: Int) {
        precondition(heights.indices.contains(row), "ExactList: row \(row) out of range 0..<\(count) (L12)")
        Self.check(custom)
        let before = gap(aboveRow: row)
        customSpacings[row] = custom
        index.add(gap(aboveRow: row) - before, atRow: row)
    }

    /// The rows after `map` (G5, G7): a surviving or moved row keeps its height
    /// and spacing unless the batch noted it; inserted and noted rows are
    /// asked through `height`, then `spacing`, row by row in ascending new
    /// order. O(k · log n) for a batch that inserts, removes and moves nothing,
    /// after the block copy that writing to a value `self` still shares makes;
    /// otherwise one O(n) copy, run by run, and an index rebuilt only after the
    /// leading rows the batch leaves alone.
    public func applying(
        _ map: RowIndexMap, height: (Int) -> CGFloat, spacing: (Int) -> CGFloat?
    ) -> RowHeights {
        precondition(map.oldCount == count, "ExactList: a map over \(map.oldCount) rows applied to \(count)")
        var asked = map.notedRows
        guard map.isStructural else {
            var result = self
            for row in asked {
                result.setHeight(height(row), ofRow: row)
                result.setSpacing(spacing(row), aboveRow: row)
            }
            return result
        }
        var values: [CGFloat] = []
        var customs: [CGFloat?] = []
        values.reserveCapacity(map.newCount)
        customs.reserveCapacity(map.newCount)
        for run in map.runs {
            switch run {
            case .kept(let old, _, let count):
                values += heights[old..<(old + count)]
                customs += customSpacings[old..<(old + count)]
            case .moved(let old, _):
                values.append(heights[old])
                customs.append(customSpacings[old])
            case .inserted(let new, let count, _):
                values += repeatElement(0, count: count)
                customs += repeatElement(nil, count: count)
                asked.insert(integersIn: new..<(new + count))
            }
        }
        for row in asked {
            let value = height(row)
            precondition(value.isFinite && value > 0, "ExactList: a row height must be finite and > 0 (L12)")
            values[row] = value
            let custom = spacing(row)
            Self.check(custom)
            customs[row] = custom
        }
        var unchanged = 0
        if case .kept(0, 0, let count) = map.runs.first { unchanged = count }
        if let first = asked.first { unchanged = min(unchanged, first) }
        return RowHeights(values, customSpacings: customs, spacing: self.spacing, reusing: index, unchanged: unchanged)
    }

    /// The space row `row` takes above itself in the sums: its spacing, or
    /// nothing for row 0, which has no row above.
    private func gap(aboveRow row: Int) -> CGFloat {
        row == 0 ? 0 : customSpacings[row] ?? spacing
    }

    /// What the index sums: each row's height plus the space above it, so the
    /// sum of the first `k` is the bottom of row `k − 1`.
    private var weights: [CGFloat] {
        heights.indices.map { heights[$0] + gap(aboveRow: $0) }
    }

    private static func check(_ custom: CGFloat?) {
        guard let custom else { return }
        precondition(custom.isFinite && custom >= 0, "ExactList: a row spacing must be finite and ≥ 0 (L12)")
    }

    /// How many leading rows end at or above `y`, with the bottom of the last
    /// of them (0 for none).
    private func rowsEnding(atOrAbove y: CGFloat) -> (count: Int, sum: CGFloat) {
        index.lift { _, sum in sum <= y }
    }

    /// How many leading rows start above `y`.
    private func rowsStarting(below y: CGFloat) -> Int {
        // Every row that ends at or above `y` starts above it (heights are > 0);
        // of the rest, only the first can, since the next starts below its end.
        let (ended, above) = rowsEnding(atOrAbove: y)
        guard ended < count else { return ended }
        return above + gap(aboveRow: ended) < y ? ended + 1 : ended
    }

    /// A 1-based Fenwick tree of partial sums over the rows' weights. It is
    /// derived from the rows, so it takes no part in equality: two values with
    /// the same rows are equal however their sums were accumulated.
    private struct FenwickIndex: Equatable, Sendable {

        private var tree: [CGFloat]

        init(_ weights: [CGFloat]) {
            self.init(weights, reusing: nil, unchanged: 0)
        }

        /// The index over `weights`, whose first `unchanged` rows are those of
        /// `base`: node `i` sums rows `(i − lowbit(i), i]`, so the nodes up to
        /// `unchanged` are `base`'s. Each later node is its row plus its
        /// children, added in the order a full build adds them. O(n − unchanged).
        init(_ weights: [CGFloat], reusing base: FenwickIndex?, unchanged: Int) {
            var tree = [CGFloat]()
            tree.reserveCapacity(weights.count + 1)
            if let base, unchanged > 0 {
                tree += base.tree[0...unchanged]
            } else {
                tree.append(0)
            }
            for i in tree.count..<(weights.count + 1) {
                var sum = weights[i - 1]
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

        /// The sum of the first `k` weights.
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

        /// The largest `k` for which `accepts(k, sum of the first k weights)`,
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
