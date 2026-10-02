import AgentSDK
import AppKit

/// A picture to paste into a prompt in a test: a PNG with a gradient and a grid,
/// so a thumbnail's crop and an image document's size can be told by eye.
enum ImageFixture {
    @MainActor
    static func png(width: Int, height: Int, hue: CGFloat = 0.58) -> ImageBlock {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(
            colors: [
                NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1),
                NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.7, alpha: 1),
            ])?.draw(in: bounds, angle: 315)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let grid = NSBezierPath()
        let step = CGFloat(max(width, height)) / 8
        var x = step
        while x < CGFloat(width) {
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: CGFloat(height)))
            x += step
        }
        var y = step
        while y < CGFloat(height) {
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: CGFloat(width), y: y))
            y += step
        }
        grid.lineWidth = 2
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return ImageBlock(data: rep.representation(using: .png, properties: [:])!, mediaType: "image/png")
    }
}
