import AgentSDK
import AppKit

/// The images behind `ComposerModel.Glyph`: the design sheet's glyphs, generated
/// into the asset catalog by `make composer-icons` (design/composer-icons), the
/// Claude mark asset, and the effort meter — five bars filled to a level, drawn
/// because it is a measured shape, not an icon (design 08 *One shape
/// language*: sized by its width, 13 of 16, as SF Symbols' cellular bars are).
@MainActor
enum ComposerGlyph {
    /// The glyph centred in a `size`-point square (template, so a view's tint
    /// colours it) — as a menu row or a panel draws it — except the Claude
    /// mark, which is the asset as is.
    static func image(_ glyph: ComposerModel.Glyph, size: CGFloat = 14) -> NSImage? {
        switch glyph {
        case .fast: centred(.composerBolt, in: size, scale: size / 16)
        case .later: asset(.composerClock, NSSize(width: size, height: size))
        case .permissionMode(let mode): asset(resource(of: mode), NSSize(width: size, height: size))
        case .effort(let level): meter(level: level, size: size)
        case .subscription: claudeMark(size: size)
        case .provider: symbol("server.rack", size * 0.86)
        case .restart: symbol("arrow.clockwise", size * 0.86)
        case .check: symbol("checkmark", size * 0.72, weight: .semibold)
        }
    }

    /// The glyph at the box a chip gives it (preview-live.css `.chip`): 14 pt
    /// for the effort meter and a mode, the bolt 10 × 12, the clock 10.
    static func chipImage(_ glyph: ComposerModel.Glyph) -> NSImage? {
        switch glyph {
        case .fast: asset(.composerBolt, NSSize(width: 10, height: 12))
        case .later: asset(.composerClock, NSSize(width: 10, height: 10))
        default: image(glyph, size: 14)
        }
    }

    /// The chips' chevron, 8 pt.
    static var chevron: NSImage { asset(.composerChevron, NSSize(width: 8, height: 8)) }

    /// The image of a permission mode, as the sheet's `MODE_GLYPH` draws it.
    static func resource(of mode: PermissionMode) -> ImageResource {
        switch mode {
        case .default: .composerModeDefault
        case .acceptEdits: .composerModeAcceptEdits
        case .plan: .composerModePlan
        case .auto: .composerModeAuto
        case .dontAsk: .composerModeDontAsk
        case .bypassPermissions: .composerModeBypass
        }
    }

    /// `resource` at `size`; the catalog's SVG scales without loss.
    static func asset(_ resource: ImageResource, _ size: NSSize) -> NSImage {
        let image = NSImage(resource: resource).copy() as? NSImage ?? NSImage(resource: resource)
        image.size = size
        return image
    }

    /// `resource` at its own aspect, `scale` times its size, centred in a square.
    private static func centred(_ resource: ImageResource, in side: CGFloat, scale: CGFloat) -> NSImage {
        let glyph = NSImage(resource: resource)
        let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            glyph.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                    height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String, _ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage.symbol(name, pointSize: pointSize, weight: weight)
    }

    private static func claudeMark(size: CGFloat) -> NSImage {
        asset(.claudeMark, NSSize(width: size, height: size))
    }

    // MARK: - The effort meter

    /// Bars rising left to right, `level` of the five filled; the rest at 28 %.
    static func meter(level: Int?, size: CGFloat) -> NSImage {
        let key = MeterKey(level: level ?? 0, size: size)
        if let image = meters[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            // The sheet's `bars`: on the 16-pt grid, y down, bars 2 wide on a
            // 2.9 pitch, 3 to 12 tall, ending at 13; scaled 0.956 about (7.8, 7)
            // onto the box's centre.
            let scale = size / 16
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.scale(by: scale * 0.956)
            transform.translateX(by: -7.8, yBy: -7)
            transform.concat()
            for index in 0..<5 {
                let height = 3 + CGFloat(index) * 2.25
                let bar = NSRect(x: 1 + CGFloat(index) * 2.9, y: 13 - height, width: 2, height: height)
                NSColor.black.withAlphaComponent(index < (level ?? 0) ? 1 : 0.28).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        meters[key] = image
        return image
    }

    private struct MeterKey: Hashable {
        var level: Int
        var size: CGFloat
    }

    private static var meters: [MeterKey: NSImage] = [:]
}
