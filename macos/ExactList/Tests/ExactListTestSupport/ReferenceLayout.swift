import CoreGraphics

/// The window tests' oracle for geometry: G1 written the naive way, from heights
/// the test itself produced. It shares no code with `RowHeights`.
public enum ReferenceLayout {

    /// Every row's frame in document coordinates: a left-to-right running sum,
    /// each row its own spacing (`customs`, G7) below the one before.
    public static func frames(
        heights: [CGFloat], spacing: CGFloat, width: CGFloat, customs: [CGFloat?]? = nil
    ) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(heights.count)
        var bottom: CGFloat = 0
        for (row, height) in heights.enumerated() {
            let top = row == 0 ? 0 : bottom + (customs?[row] ?? spacing)
            frames.append(CGRect(x: 0, y: top, width: width, height: height))
            bottom = top + height
        }
        return frames
    }

    /// `H` (G2).
    public static func contentHeight(heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.isEmpty ? 0 : heights.reduce(0, +) + CGFloat(heights.count - 1) * spacing
    }
}
