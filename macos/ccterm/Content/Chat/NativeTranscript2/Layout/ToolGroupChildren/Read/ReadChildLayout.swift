import AppKit

/// Body layout for `Block.ToolGroupBlock.Child.read` — header-only,
/// no body. The header band (title only, no chevron — gated by
/// `ReadChild`'s `hasExpandableBody == false` on the parent enum) is
/// painted by `ToolGroupLayout`; this layout exists purely so the
/// dispatcher enum has a canonical place to land for `.read` children.
///
/// `totalHeight == 0` is what tells `ToolGroupLayout.make` to keep the
/// entry's `body == nil` after `make(...)` returns — the same path
/// folded children take. Nothing else is rendered.
struct ReadChildLayout: Sendable {
    var totalHeight: CGFloat { 0 }

    func drawBackplate(in ctx: CGContext, origin: CGPoint) {}

    func draw(in ctx: CGContext, origin: CGPoint) {}

    nonisolated static func make(
        child: ReadChild,
        originX: CGFloat,
        originY: CGFloat,
        maxWidth: CGFloat
    ) -> ReadChildLayout {
        ReadChildLayout()
    }
}
