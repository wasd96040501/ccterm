import AppKit

/// Single source of truth for the in-card "copy this" affordance:
///
///   • `CodeBlockLayout` — one per fenced code block (top-right corner).
///   • `BashChildLayout` — one per command / stdout / stderr sub-card.
///   • `DiffLayout` — one per diff card (FileEdit + Read; sits next to
///     the language badge).
///   • Anywhere else a future layout wants to host the same 18pt SF
///     Symbol affordance.
///
/// Owns three things and only three things:
///
///   1. Geometry — `hitRect` / `center` in **layout-local** coords. The
///      cell offsets by its draw origin at hit-test and paint time, the
///      same way it does for everything else a layout emits.
///   2. Identity — `id` keys cell-side per-button hover + post-click
///      flash state, so a row with multiple copy buttons (e.g. an
///      expanded bash child with command + stdout + stderr cards) flashes
///      only the clicked icon. Owners are responsible for stability
///      across re-layouts so the flash survives `noteHeightOfRows` /
///      `reloadData(forRowIndexes:)` mid-flash.
///   3. Payload — `text` is the pasteboard string written when the
///      cell's `HitAction.copy(id:text:)` switch arm fires.
///
/// Visuals (symbol name / tint / hover background / weight / flash
/// glyph) live in `draw(in:origin:hovered:flashing:)`. Before this
/// primitive the same recipe was reimplemented three times (codeblock /
/// bash / diff) with subtle drift; collapsing it here means a future
/// "change copy icon" / "change hover tone" ask is a single-method
/// edit.
///
/// `Sendable`: the struct holds only value types + a `String`, no
/// `CTLine` / `NSImage` references. The SF Symbol image is reconstructed
/// inside `draw` from the symbol name + a config — same approach
/// `BlockCellView+Gutter.swift` uses for the cell-margin gutter glyph,
/// so the two affordances render through one recipe.
struct CopyChrome: Sendable {
    /// Stable identity. Keys per-button state on `BlockCellView.copyFlashByActionId`
    /// and the matching `SubviewPlan` `flashingCopyIds` set.
    let id: UUID

    /// Hit zone in layout-local coords. 18pt square (`gutterHitSize`).
    let hitRect: CGRect

    /// SF Symbol center in layout-local coords. Symbol bounds derive
    /// from `gutterSymbolPointSize`; the cell composes that into the
    /// final draw rect at paint time.
    let center: CGPoint

    /// Pasteboard payload written by `HitAction.copy(id:text:)`.
    let text: String

    /// Deterministically derive a per-section `CopyChrome.id` from a
    /// base UUID + an integer slot. Owners with multiple cards sharing
    /// one source id (today: `BashChildLayout`, where command / stdout /
    /// stderr cards live under one `BashChild.id`) call this to get
    /// stable, non-colliding ids. The derivation is a byte-level XOR of
    /// the slot's little-endian bytes into the base UUID's trailing 8
    /// bytes — same `(base, slot)` pair always returns the same UUID,
    /// and the 64-bit residual entropy keeps collisions with sibling
    /// children's caller-supplied UUIDs astronomically improbable.
    nonisolated static func derivedId(base: UUID, slot: Int) -> UUID {
        var bytes = base.uuid
        let raw = UInt64(bitPattern: Int64(slot))
        bytes.8 ^= UInt8(truncatingIfNeeded: raw)
        bytes.9 ^= UInt8(truncatingIfNeeded: raw >> 8)
        bytes.10 ^= UInt8(truncatingIfNeeded: raw >> 16)
        bytes.11 ^= UInt8(truncatingIfNeeded: raw >> 24)
        bytes.12 ^= UInt8(truncatingIfNeeded: raw >> 32)
        bytes.13 ^= UInt8(truncatingIfNeeded: raw >> 40)
        bytes.14 ^= UInt8(truncatingIfNeeded: raw >> 48)
        bytes.15 ^= UInt8(truncatingIfNeeded: raw >> 56)
        return UUID(uuid: bytes)
    }

    /// Lay out a chrome anchored at the top-right corner of `container`,
    /// using the shared `codeBlockChrome*` insets. Returns `nil` when
    /// the container is too narrow to host an 18pt hit zone past the
    /// right inset — callers fall back to "no copy button" instead of
    /// painting one that overlaps the body's left padding.
    ///
    /// `id` and `text` come from the owner; `container` is the card /
    /// container rect in layout-local coords (`y` flipped — top-left
    /// origin). The factory does no clamping beyond the narrowness
    /// guard; callers wanting a leftward-displaced chrome (e.g. to
    /// reserve room for a language badge) anchor manually via the
    /// `CopyChrome.init(...)` memberwise initializer.
    nonisolated static func topRight(
        of container: CGRect, id: UUID, text: String
    ) -> CopyChrome? {
        let hitSize = BlockStyle.gutterHitSize
        let topInset = BlockStyle.codeBlockChromeTopInset
        let rightInset = BlockStyle.codeBlockChromeRightInset
        guard container.width >= hitSize + 2 * rightInset else { return nil }
        let rightEdge = container.maxX - rightInset
        let leftEdge = rightEdge - hitSize
        let hit = CGRect(
            x: leftEdge,
            y: container.minY + topInset,
            width: hitSize,
            height: hitSize)
        let center = CGPoint(x: hit.midX, y: hit.midY)
        return CopyChrome(id: id, hitRect: hit, center: center, text: text)
    }

    /// Render the affordance at `origin` offset. Owns symbol name /
    /// tint / hover background / glyph weight so all copy icons in the
    /// product render at one recipe.
    ///
    ///   • `hovered == true` → paint the rounded `gutterHoverBackground`
    ///     behind the glyph (same chip used by the cell-margin gutter).
    ///   • `flashing == true` → swap `doc.on.doc` → `checkmark` (with
    ///     `.semibold` weight) for the post-click feedback window.
    ///
    /// Drawn into a `flipped: true` graphics context so the SF Symbol
    /// composites upright inside the cell's y-down coordinate space —
    /// matching `CodeBlockLayout` / `BashChildLayout`'s pre-refactor
    /// drawing recipe so the visual is bit-identical.
    nonisolated func draw(
        in ctx: CGContext, origin: CGPoint,
        hovered: Bool, flashing: Bool
    ) {
        if hovered {
            let bg = hitRect.offsetBy(dx: origin.x, dy: origin.y)
            let path = CGPath(
                roundedRect: bg,
                cornerWidth: BlockStyle.gutterHoverCornerRadius,
                cornerHeight: BlockStyle.gutterHoverCornerRadius,
                transform: nil)
            ctx.setFillColor(BlockStyle.gutterHoverBackground.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        let name = flashing ? "checkmark" : "doc.on.doc"
        let tint: NSColor =
            hovered
            ? BlockStyle.gutterHoverForeground
            : BlockStyle.gutterIdleForeground
        let weight: NSFont.Weight = flashing ? .semibold : .regular
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
        let centerOnScreen = CGPoint(
            x: origin.x + center.x, y: origin.y + center.y)
        let rect = CGRect(
            x: centerOnScreen.x - size.width / 2,
            y: centerOnScreen.y - size.height / 2,
            width: size.width,
            height: size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: ctx, flipped: true)
        symbol.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
