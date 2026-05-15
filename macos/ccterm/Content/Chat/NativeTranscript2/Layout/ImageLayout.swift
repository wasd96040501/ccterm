import AppKit

/// Immutable image layout — pure function of `(image, maxWidth, maxHeight)`.
///
/// Stores a `CGImage` (not the source `NSImage`):
/// - CGImage is `Sendable` since macOS 13 → ImageLayout is truly Sendable
///   without `@unchecked`, safe to construct off-main and hand to MainActor
/// - One-time bitmap extraction in `make`, not on every `draw` (which the
///   NSImage variant repeated)
///
/// `displayRect.origin` is the aspect-fit rectangle's top-left inside the
/// row's content area. `totalHeight` is what `heightOfRow` consumes.
struct ImageLayout: Sendable {
    let cgImage: CGImage?
    let displayRect: CGRect
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    nonisolated static func make(
        image: NSImage,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> ImageLayout {
        let intrinsic = image.size
        guard maxWidth > 0,
            intrinsic.width > 0,
            intrinsic.height > 0
        else {
            return ImageLayout(
                cgImage: nil,
                displayRect: .zero,
                totalHeight: 0,
                measuredWidth: max(0, maxWidth))
        }

        // Aspect-fit within (maxWidth × maxHeight). Never upscale.
        let scale = min(
            1,
            min(
                maxWidth / intrinsic.width,
                maxHeight / intrinsic.height))
        let w = intrinsic.width * scale
        let h = intrinsic.height * scale
        let originX = (maxWidth - w) / 2  // center horizontally

        // Extract CGImage once (off-main safe). Subsequent draws reuse it.
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return ImageLayout(
            cgImage: cg,
            displayRect: CGRect(x: originX, y: 0, width: w, height: h),
            totalHeight: h,
            measuredWidth: maxWidth)
    }

    /// Draw into a flipped NSView. `origin` is the layout's top-left in view coords.
    func draw(in ctx: CGContext, origin: CGPoint) {
        guard let cgImage,
            displayRect.width > 0, displayRect.height > 0
        else { return }
        let target = CGRect(
            x: origin.x + displayRect.minX,
            y: origin.y + displayRect.minY,
            width: displayRect.width,
            height: displayRect.height)
        // CGContext.draw expects y-up image coords; we are in a flipped view,
        // so locally flip around the target rect to keep the bitmap upright.
        ctx.saveGState()
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(
            cgImage,
            in: CGRect(
                x: 0, y: 0,
                width: target.width,
                height: target.height))
        ctx.restoreGState()
    }
}
