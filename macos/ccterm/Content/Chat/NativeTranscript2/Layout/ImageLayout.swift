import AppKit

/// Immutable image layout — pure function of `(image, maxWidth, maxHeight)`.
///
/// `displayRect` is the aspect-fit rectangle inside the row's content area
/// (origin local to the row's content origin). `totalHeight` is what the
/// table's `heightOfRow` consumes.
struct ImageLayout {
    let image: NSImage
    let displayRect: CGRect
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    static func make(image: NSImage,
                     maxWidth: CGFloat,
                     maxHeight: CGFloat) -> ImageLayout {
        let intrinsic = image.size
        guard maxWidth > 0,
              intrinsic.width > 0,
              intrinsic.height > 0
        else {
            return ImageLayout(image: image,
                               displayRect: .zero,
                               totalHeight: 0,
                               measuredWidth: max(0, maxWidth))
        }

        // Aspect-fit within (maxWidth × maxHeight). Never upscale.
        let scale = min(1, min(maxWidth / intrinsic.width,
                               maxHeight / intrinsic.height))
        let w = intrinsic.width * scale
        let h = intrinsic.height * scale
        let originX = (maxWidth - w) / 2     // center horizontally

        return ImageLayout(
            image: image,
            displayRect: CGRect(x: originX, y: 0, width: w, height: h),
            totalHeight: h,
            measuredWidth: maxWidth)
    }

    /// Draw into a flipped NSView. `origin` is the layout's top-left in view coords.
    func draw(in ctx: CGContext, origin: CGPoint) {
        guard displayRect.width > 0, displayRect.height > 0 else { return }
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
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0,
                                    width: target.width,
                                    height: target.height))
        }
        ctx.restoreGState()
    }
}
