import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.generic` — header-only,
/// no body. Mirrors `ReadChildLayout`: the header is owned by
/// `ToolGroupLayout` (and renders without a chevron via
/// `hasExpandableBody == false`), and `totalHeight == 0` keeps the
/// dispatcher's `body` slot at `nil` after `make(...)` returns.
struct GenericChildLayout: Sendable {
    var totalHeight: CGFloat { 0 }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {}

    func draw(in ctx: CGContext, origin: CGPoint) {}

    nonisolated static func make(
        child: GenericChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> GenericChildLayout {
        GenericChildLayout()
    }
}
