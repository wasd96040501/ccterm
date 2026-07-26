import AppKit

/// Right-aligned strip of user-attached image thumbnails, mirroring the
/// chip style used in `InputBarView2`'s attachment row (48×48 rounded
/// square, 6pt corner, hairline separator stroke, 8pt gap).
///
/// Sibling block to `userBubble` — emitted as its own row above the
/// caption so the two surfaces stay independently diffable and the
/// bubble layout's text geometry stays pure. Multiple images flow
/// right-to-left in the strip; when the strip exceeds the content
/// width the chips wrap onto a new row, still right-anchored.
///
/// Layout is a pure function of `(images, maxWidth)`. Each `NSImage` is
/// converted to a `CGImage` once at `make` time so subsequent draws are
/// cheap composites and the layout stays `nonisolated` (off-main precompute
/// remains safe).
struct UserAttachmentsLayout: @unchecked Sendable {
    /// One drawable chip — pre-cropped to the target square via an
    /// aspect-fill source rect computed in `make`.
    struct Chip: @unchecked Sendable {
        /// Original `NSImage` reference. Carried so the cell can match
        /// the hovered `HitAction.openImagePreview(NSImage)` against
        /// this chip (NSObject reference equality), and so click
        /// routing can hand the same instance to the preview sheet.
        let image: NSImage
        let cgImage: CGImage?
        /// Square frame in layout-local coords.
        let frame: CGRect
        /// Source rect inside `cgImage` — center-cropped to match the
        /// target frame's aspect ratio.
        let sourceRect: CGRect
    }

    let chips: [Chip]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    nonisolated static let chipSize: CGFloat = 48
    nonisolated static let chipSpacing: CGFloat = 8
    nonisolated static let chipCornerRadius: CGFloat = 6
    nonisolated static let chipStrokeWidth: CGFloat = 0.5
    /// Stroke width swap on hover — slightly heavier than the resting
    /// hairline so the cursor-targeted chip reads as "this is what
    /// you'll click", without the row jumping height.
    nonisolated static let chipHoverStrokeWidth: CGFloat = 1.5

    nonisolated static func make(images: [NSImage], maxWidth: CGFloat) -> UserAttachmentsLayout {
        guard maxWidth > 0, !images.isEmpty else {
            return UserAttachmentsLayout(
                chips: [], totalHeight: 0, measuredWidth: max(0, maxWidth))
        }

        // Pack chips into rows that fit `maxWidth`. Each row is then
        // right-anchored independently — the final row's chip count
        // controls where its strip starts; the user's eye reads the
        // entire block as flush with the right edge.
        let chipStride = chipSize + chipSpacing
        let perRow = max(1, Int((maxWidth + chipSpacing) / chipStride))
        let rowCount = (images.count + perRow - 1) / perRow

        var chips: [Chip] = []
        chips.reserveCapacity(images.count)
        for idx in 0..<images.count {
            let row = idx / perRow
            let col = idx % perRow
            // Right-anchor each row: index 0 in a row sits at the strip's
            // left, index (countInRow-1) hugs maxWidth. Compute the row's
            // chip count first so the rightmost chip lands exactly at maxWidth.
            let rowStart = row * perRow
            let rowEnd = min(rowStart + perRow, images.count)
            let countInRow = rowEnd - rowStart
            let stripWidth = CGFloat(countInRow) * chipSize + CGFloat(countInRow - 1) * chipSpacing
            let stripLeft = maxWidth - stripWidth
            let x = stripLeft + CGFloat(col) * chipStride
            let y = CGFloat(row) * (chipSize + chipSpacing)
            let frame = CGRect(x: x, y: y, width: chipSize, height: chipSize)

            let nsImage = images[idx]
            let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let sourceRect: CGRect = {
                guard let cg, cg.width > 0, cg.height > 0 else { return .zero }
                let srcW = CGFloat(cg.width)
                let srcH = CGFloat(cg.height)
                // Aspect-fill into a square: pick the larger axis ratio,
                // crop the other axis symmetrically. Result is the largest
                // centered square that fits the source.
                let side = min(srcW, srcH)
                return CGRect(
                    x: (srcW - side) / 2,
                    y: (srcH - side) / 2,
                    width: side,
                    height: side)
            }()
            chips.append(
                Chip(image: nsImage, cgImage: cg, frame: frame, sourceRect: sourceRect))
        }

        let totalHeight = CGFloat(rowCount) * chipSize + CGFloat(rowCount - 1) * chipSpacing
        return UserAttachmentsLayout(
            chips: chips,
            totalHeight: totalHeight,
            measuredWidth: maxWidth)
    }

    /// Click targets in layout-local coords — one `InteractiveHit` per
    /// chip, carrying the chip's `NSImage` so the cell can route the
    /// click and so `hoveredAction` matching pinpoints the exact chip
    /// under the cursor.
    var interactiveHits: [InteractiveHit] {
        chips.map { chip in
            InteractiveHit(rect: chip.frame, action: .openImagePreview(chip.image))
        }
    }

    /// Draw into a flipped NSView. `origin` is layout-local top-left in
    /// view coords. Each chip:
    ///   1. clips to a rounded rect
    ///   2. draws the source crop into the square (flipped locally so the
    ///      bitmap stays upright in a y-down view)
    ///   3. strokes the rounded rect with a hairline separator
    ///
    /// `hoveredAction` carries whatever hit is under the cursor right
    /// now. When it names one of this layout's chips, that chip swaps
    /// its hairline for the heavier hover stroke and gets a faint
    /// white overlay so the eye locks on without the row's geometry
    /// shifting.
    func draw(in ctx: CGContext, origin: CGPoint, hoveredAction: HitAction?) {
        let strokeColor = NSColor.separatorColor.cgColor
        let hoverStrokeColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        let hoverOverlay = NSColor.white.withAlphaComponent(0.12).cgColor
        let fallbackFill = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor

        let hoveredImage: NSImage? = {
            if case .openImagePreview(let img) = hoveredAction { return img }
            return nil
        }()

        for chip in chips {
            let target = CGRect(
                x: origin.x + chip.frame.minX,
                y: origin.y + chip.frame.minY,
                width: chip.frame.width,
                height: chip.frame.height)
            let path = CGPath(
                roundedRect: target,
                cornerWidth: Self.chipCornerRadius,
                cornerHeight: Self.chipCornerRadius,
                transform: nil)
            let isHovered = hoveredImage === chip.image

            if let cgImage = chip.cgImage,
                chip.sourceRect.width > 0, chip.sourceRect.height > 0
            {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.translateBy(x: target.minX, y: target.maxY)
                ctx.scaleBy(x: 1, y: -1)
                if let cropped = cgImage.cropping(to: chip.sourceRect) {
                    ctx.draw(
                        cropped,
                        in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
                }
                ctx.restoreGState()
            } else {
                ctx.saveGState()
                ctx.setFillColor(fallbackFill)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.restoreGState()
            }

            if isHovered {
                ctx.saveGState()
                ctx.setFillColor(hoverOverlay)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.restoreGState()
            }

            ctx.saveGState()
            ctx.setStrokeColor(isHovered ? hoverStrokeColor : strokeColor)
            ctx.setLineWidth(isHovered ? Self.chipHoverStrokeWidth : Self.chipStrokeWidth)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
