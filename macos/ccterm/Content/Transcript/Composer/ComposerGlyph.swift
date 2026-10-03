import AgentSDK
import AppKit

/// The images behind `ComposerModel.Glyph` (design 08 *Glyphs match by eye*):
/// an SF Symbol wherever one has the sheet's shape, at the point size and
/// weight whose ink matches the sheet's glyph (box and area, measured against
/// preview-live.js's own geometry); the sheet's own geometry, generated into
/// the asset catalog by `make composer-icons`, for the modes SF Symbols has no
/// shape for; the Claude mark asset; and the effort meter — five bars filled
/// to a level, drawn because it is a measured shape, not an icon. Every glyph
/// is centred in the box the sheet gives it, so a chip is as wide as the
/// sheet's.
@MainActor
enum ComposerGlyph {
    /// The glyph centred in a `size`-point square (template, so a view's tint
    /// colours it) — as a menu row or a panel draws it — except the Claude
    /// mark, which is the asset as is.
    static func image(_ glyph: ComposerModel.Glyph, size: CGFloat = 14) -> NSImage? {
        let box = NSSize(width: size, height: size)
        switch glyph {
        // The sheet's bolt is 10 × 12 wherever it stands, measured in the chip's 14.
        case .fast: return symbol(.bolt, scale: size / 14, in: box)
        case .later: return symbol(.clock, scale: size / 10, in: box)
        case .permissionMode(let mode): return modeImage(mode, size: size)
        case .effort(let level): return meter(level: level, size: size)
        case .subscription: return asset(.claudeMark, box)
        case .provider: return symbol(.rack, scale: size / 16, in: box)
        case .restart: return symbol(.restart, scale: size / 16, in: box)
        // The panel passes its 14-pt slot for the sheet's 10-pt check.
        case .check: return symbol(.check, scale: size / 14, in: box)
        }
    }

    /// The glyph at the box a chip gives it (preview-live.css `.chip`): 14 pt
    /// for the effort meter and a mode, the bolt 10 × 12, the clock 10.
    static func chipImage(_ glyph: ComposerModel.Glyph) -> NSImage? {
        switch glyph {
        case .fast: symbol(.bolt, scale: 1, in: NSSize(width: 10, height: 12))
        case .later: symbol(.clock, scale: 1, in: NSSize(width: 10, height: 10))
        default: image(glyph, size: 14)
        }
    }

    /// The glyph at the 16-pt box a menu row gives it (`.mi .g`): the bolt
    /// stays the chip's 10 × 12 in it (`padding: 2px 3px`).
    static func menuImage(_ glyph: ComposerModel.Glyph) -> NSImage? {
        switch glyph {
        case .fast: symbol(.bolt, scale: 1, in: NSSize(width: 16, height: 16))
        default: image(glyph, size: 16)
        }
    }

    /// The chips' chevron, in its 8-pt box.
    static var chevron: NSImage { symbol(.chevron, scale: 1, in: NSSize(width: 8, height: 8)) }

    /// The action button's arrow, in its 14-pt box.
    static var send: NSImage { symbol(.send, scale: 1, in: NSSize(width: 14, height: 14)) }

    /// The action button's stop square, in its 10-pt box.
    static var stop: NSImage { symbol(.stop, scale: 1, in: NSSize(width: 10, height: 10)) }

    /// The failure's octagon, red with a white bang, in its 16-pt box.
    static var failure: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13.4, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        let symbol =
            NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        return centred(symbol, in: NSSize(width: 16, height: 16), template: false)
    }

    // MARK: - Symbols

    /// An SF Symbol and the point size and weight at which its ink matches the
    /// sheet's glyph in the box it was measured in.
    private struct Symbol {
        var name: String
        var pointSize: CGFloat
        var weight: NSFont.Weight

        static let defaultMode = Symbol(name: "shield", pointSize: 11.4, weight: .medium)  // in 14
        static let bypassMode = Symbol(name: "exclamationmark.shield", pointSize: 11.4, weight: .medium)  // in 14
        static let clock = Symbol(name: "clock", pointSize: 9.4, weight: .semibold)  // in 10
        static let bolt = Symbol(name: "bolt.fill", pointSize: 8.8, weight: .bold)  // 10 × 12
        static let send = Symbol(name: "arrow.up", pointSize: 12, weight: .bold)  // in 14
        static let stop = Symbol(name: "stop.fill", pointSize: 10.6, weight: .bold)  // in 10
        static let check = Symbol(name: "checkmark", pointSize: 9.2, weight: .bold)  // in 10
        static let chevron = Symbol(name: "chevron.down", pointSize: 7.6, weight: .bold)  // in 8
        static let restart = Symbol(name: "arrow.clockwise", pointSize: 11.8, weight: .bold)  // in 16
        static let rack = Symbol(name: "server.rack", pointSize: 9.8, weight: .bold)  // in 16
    }

    private static func symbol(_ symbol: Symbol, scale: CGFloat, in box: NSSize) -> NSImage {
        let image =
            NSImage.symbol(symbol.name, pointSize: symbol.pointSize * scale, weight: symbol.weight) ?? NSImage()
        return centred(image, in: box, template: true)
    }

    /// The permission mode's glyph in a `size` square: the SF Symbol where one
    /// has the sheet's shape, else the sheet's own.
    private static func modeImage(_ mode: PermissionMode, size: CGFloat) -> NSImage {
        let box = NSSize(width: size, height: size)
        switch mode {
        case .default: return symbol(.defaultMode, scale: size / 14, in: box)
        case .bypassPermissions: return symbol(.bypassMode, scale: size / 14, in: box)
        case .acceptEdits: return asset(.composerModeAcceptEdits, box)
        case .plan: return asset(.composerModePlan, box)
        case .auto: return asset(.composerModeAuto, box)
        case .dontAsk: return asset(.composerModeDontAsk, box)
        }
    }

    /// `resource` at `size`; the catalog's SVG scales without loss.
    private static func asset(_ resource: ImageResource, _ size: NSSize) -> NSImage {
        let image = NSImage(resource: resource).copy() as? NSImage ?? NSImage(resource: resource)
        image.size = size
        return image
    }

    /// `image` at its own size, centred in `box`.
    private static func centred(_ image: NSImage, in box: NSSize, template: Bool) -> NSImage {
        let size = image.size
        let boxed = NSImage(size: box, flipped: false) { rect in
            image.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                    height: size.height))
            return true
        }
        boxed.isTemplate = template
        return boxed
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
