import CoreGraphics

/// The window tests' oracle for geometry: G1 written the naive way, from heights
/// the test itself produced. It shares no code with `RowHeights`.
public enum ReferenceLayout {

    /// Every row's frame in document coordinates: a left-to-right running sum.
    public static func frames(heights: [CGFloat], spacing: CGFloat, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(heights.count)
        var y: CGFloat = 0
        for height in heights {
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + spacing
        }
        return frames
    }

    /// `H` (G2).
    public static func contentHeight(heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        heights.isEmpty ? 0 : heights.reduce(0, +) + CGFloat(heights.count - 1) * spacing
    }
}
