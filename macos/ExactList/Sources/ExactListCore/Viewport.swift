import CoreGraphics

/// The clip view's position and size, and everything derived from them
/// (SPEC §3, G3).
///
/// All values are in document coordinates: flipped, with row 0's top at 0.
public struct Viewport: Equatable, Sendable {

    /// `o`: the clip view's `bounds.origin.y`.
    public var offset: CGFloat

    /// `V`: the clip view's height.
    public var height: CGFloat

    /// `t`: the top content inset.
    public var insetTop: CGFloat

    /// `b`: the bottom content inset.
    public var insetBottom: CGFloat

    /// `ε` in the tail test: 1 pt.
    public static let tailTolerance: CGFloat = 1

    public init(offset: CGFloat, height: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) {
        self.offset = offset
        self.height = height
        self.insetTop = insetTop
        self.insetBottom = insetBottom
    }

    /// `o + t`: the top of `U`.
    public var unobscuredTop: CGFloat {
        fatalError("unimplemented: SPEC §3")
    }

    /// `o + V − b`: the bottom of `U`.
    public var unobscuredBottom: CGFloat {
        fatalError("unimplemented: SPEC §3")
    }

    /// `q = (V − t − b) / 2`.
    public var overscan: CGFloat {
        fatalError("unimplemented: SPEC §3")
    }

    /// The top of `P`: `o + t − q`.
    public var preparedTop: CGFloat {
        fatalError("unimplemented: SPEC §3")
    }

    /// The bottom of `P`: `o + V − b + q`.
    public var preparedBottom: CGFloat {
        fatalError("unimplemented: SPEC §3")
    }

    /// `oMin = −t` (G3).
    public var minOffset: CGFloat {
        fatalError("unimplemented: SPEC G3")
    }

    /// `oMax = max(oMin, H − V + b)` (G3).
    public func maxOffset(contentHeight: CGFloat) -> CGFloat {
        fatalError("unimplemented: SPEC G3")
    }

    /// `o ≥ oMax − ε` (§3, A8).
    public func isAtTail(contentHeight: CGFloat) -> Bool {
        fatalError("unimplemented: SPEC A8")
    }

    /// `offset` clamped to `[oMin, oMax]` (A7).
    public func clamped(_ offset: CGFloat, contentHeight: CGFloat) -> CGFloat {
        fatalError("unimplemented: SPEC A7")
    }
}
