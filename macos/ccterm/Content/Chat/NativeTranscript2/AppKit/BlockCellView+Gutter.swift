import AppKit

/// Gutter rendering + hit testing. Gutters are cell-level decorations
/// that float in the outer margin alongside the layout content (left of
/// regular blocks, right of the right-aligned user bubble). They are
/// **not** part of the layout pipeline — see `GutterSpec` for the
/// boundary contract.
///
/// Why self-drawn CGContext, not `SubviewPlan`-style layers: the only
/// visual the gutter needs is a static glyph + a static rounded hover
/// background + a static checkmark feedback swap. None of these need
/// CoreAnimation — they all snap on `needsDisplay`. Going through a
/// `CALayer` would add `contentsScale` propagation, reconcile-by-id
/// bookkeeping, and appearance-flip re-rasterization for no visible
/// gain. The existing in-header copy glyph (`CodeBlockLayout.drawCopyGlyph`)
/// already pioneers this pattern; gutters are the cell-margin
/// generalisation.
extension BlockCellView {
    // MARK: - Geometry

    /// Cell-local rect for `spec`. Vertical: baseline-aligned to the
    /// layout's first line via `RowLayout.firstLineCenterY`, offset by
    /// the cell's `padTop`. Horizontal: leading specs sit one
    /// `gutterMargin` to the left of `layoutOrigin.x`; trailing specs
    /// sit one `gutterMargin` to the right of the content's right
    /// edge (`layoutOrigin.x + layout.measuredWidth`). For the user
    /// bubble, `measuredWidth` is the content-area width, and
    /// `bubbleRect.maxX == measuredWidth` — so the trailing-side
    /// gutter naturally lands flush against the bubble's right edge.
    func gutterRect(for spec: GutterSpec) -> CGRect? {
        guard let layout else { return nil }
        let size = BlockStyle.gutterHitSize
        let margin = BlockStyle.gutterMargin

        let centerY = padTop + layout.firstLineCenterY
        let y = centerY - size / 2

        let origin = layoutOrigin
        let contentRight = origin.x + layout.measuredWidth

        let x: CGFloat
        switch spec.side {
        case .leading:
            x = origin.x - margin - size
        case .trailing:
            x = contentRight + margin
        }
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// Per spec: `nil` when the layout has no gutters or the
    /// computed rect would spill outside `bounds` (narrow window —
    /// "直接裁切" per design). Visible only when the cell is hovered.
    func visibleGutterRect(for spec: GutterSpec) -> CGRect? {
        guard let rect = gutterRect(for: spec) else { return nil }
        if rect.minX < 0 || rect.maxX > bounds.width { return nil }
        return rect
    }

    // MARK: - Draw

    /// Painted after the cell's selection band and glyph layout draws
    /// — gutters live in the row margin, never overlap content, so
    /// ordering is purely "after everything else".
    func drawGutters(in ctx: CGContext) {
        guard !gutters.isEmpty, cellHovered else { return }
        for spec in gutters {
            guard let rect = visibleGutterRect(for: spec) else { continue }
            let isHovered = hoveredGutterId == spec.id
            let isCopied = gutterCopiedAt[spec.id] != nil
            drawGutterButton(
                in: ctx, rect: rect,
                hovered: isHovered, copied: isCopied)
        }
    }

    private func drawGutterButton(
        in ctx: CGContext, rect: CGRect,
        hovered: Bool, copied: Bool
    ) {
        if hovered {
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: BlockStyle.gutterHoverCornerRadius,
                cornerHeight: BlockStyle.gutterHoverCornerRadius,
                transform: nil)
            ctx.setFillColor(BlockStyle.gutterHoverBackground.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // SF Symbol — same configuration recipe as
        // `CodeBlockLayout.drawCopyGlyph`. `doc.on.doc` idle, swap to
        // `checkmark` while the post-click feedback flash is active.
        let name = copied ? "checkmark" : "doc.on.doc"
        let tint: NSColor =
            hovered
            ? BlockStyle.gutterHoverForeground
            : BlockStyle.gutterIdleForeground
        let weight: NSFont.Weight = copied ? .semibold : .regular
        let baseConfig = NSImage.SymbolConfiguration(
            pointSize: BlockStyle.gutterSymbolPointSize, weight: weight)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        let config = baseConfig.applying(colorConfig)
        guard
            let symbol = NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return }

        let size = symbol.size
        let drawRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height)

        // Cell is flipped; push a flipped graphics context so
        // `NSImage.draw(...respectFlipped:)` composites upright.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: ctx, flipped: true)
        symbol.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Hit testing / hover

    /// Returns the gutter whose rect contains `local`, or `nil`.
    /// Honors the same visibility rule as `drawGutters` — a gutter
    /// clipped by narrow window margins doesn't accept clicks.
    func gutterAt(_ local: NSPoint) -> GutterSpec? {
        for spec in gutters {
            if let r = visibleGutterRect(for: spec), r.contains(local) {
                return spec
            }
        }
        return nil
    }

    /// Re-evaluate which gutter is under the cursor and store the id.
    /// Triggers a redraw via `hoveredGutterId.didSet` when the value
    /// actually changes.
    func updateGutterHover(at local: NSPoint) {
        let newHover = gutterAt(local)?.id
        if newHover != hoveredGutterId {
            hoveredGutterId = newHover
        }
    }

    // MARK: - Click

    /// Click feedback (checkmark flash) is local to the cell; the
    /// actual copy work is handed to the coordinator, which dispatches
    /// the heavy text serialization + pasteboard write off the main
    /// thread. Feedback fires whether or not the copy ultimately
    /// succeeds — opportunistic UX, not transactional.
    func handleGutterClick(_ spec: GutterSpec) {
        guard let blockId else { return }

        let stamp = Date()
        gutterCopiedAt[spec.id] = stamp
        needsDisplay = true

        coordinator?.handleGutter(spec, blockId: blockId)

        let gutterId = spec.id
        let delayNs = UInt64(
            BlockStyle.gutterCopiedFeedbackSeconds * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self,
                self.gutterCopiedAt[gutterId] == stamp
            else { return }
            self.gutterCopiedAt.removeValue(forKey: gutterId)
            self.needsDisplay = true
        }
    }
}
