import AgentSDK
import AppKit

/// The images behind `ComposerModel.Glyph`: SF Symbols, the Claude mark asset,
/// and the effort meter — five bars filled to a level, drawn because it is a
/// measured shape, not an icon (design 08 *One shape language*: sized by its
/// width, 13 of 16, as SF Symbols' cellular bars are).
@MainActor
enum ComposerGlyph {
    /// The glyph as an image of `size` points square (template, so a view's
    /// tint colours it) — except the Claude mark, which is the asset as is.
    static func image(_ glyph: ComposerModel.Glyph, size: CGFloat = 14) -> NSImage? {
        switch glyph {
        case .fast: symbol("bolt.fill", size * 0.78)
        case .later: symbol("clock", size * 0.72)
        case .permissionMode(let mode): symbol(symbolName(of: mode), size * 0.86)
        case .effort(let level): meter(level: level, size: size)
        case .subscription: claudeMark(size: size)
        case .provider: symbol("server.rack", size * 0.86)
        case .restart: symbol("arrow.clockwise", size * 0.86)
        case .check: symbol("checkmark", size * 0.72, weight: .semibold)
        }
    }

    /// The SF Symbol a permission mode wears.
    static func symbolName(of mode: PermissionMode) -> String {
        switch mode {
        case .default: "shield"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .auto: "sparkles"
        case .dontAsk: "nosign"
        case .bypassPermissions: "exclamationmark.shield"
        }
    }

    private static func symbol(_ name: String, _ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage.symbol(name, pointSize: pointSize, weight: weight)
    }

    private static func claudeMark(size: CGFloat) -> NSImage {
        let image = NSImage(resource: .claudeMark).copy() as? NSImage ?? NSImage(resource: .claudeMark)
        image.size = NSSize(width: size, height: size)
        return image
    }

    // MARK: - The effort meter

    /// Bars rising left to right, `level` of the five filled; the rest at 28 %.
    static func meter(level: Int?, size: CGFloat) -> NSImage {
        let key = MeterKey(level: level ?? 0, size: size)
        if let image = meters[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // The design's 16-pt grid: bars 2 wide on a 2.9 pitch, 3 to 12 tall.
            let scale = size / 16 * 0.956
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.scale(by: scale)
            transform.translateX(by: -7.8, yBy: -7)
            transform.concat()
            for index in 0..<5 {
                let height = 3 + CGFloat(index) * 2.25
                let bar = NSRect(x: 1 + CGFloat(index) * 2.9, y: 13 - height, width: 2, height: height)
                // The grid has y down; the image's y goes up.
                let flipped = NSRect(x: bar.minX, y: 14 - bar.maxY, width: bar.width, height: bar.height)
                NSColor.black.withAlphaComponent(index < (level ?? 0) ? 1 : 0.28).setFill()
                NSBezierPath(roundedRect: flipped, xRadius: 0.8, yRadius: 0.8).fill()
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
