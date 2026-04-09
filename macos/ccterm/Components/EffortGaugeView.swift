import SwiftUI
import AppKit

/// A tiny gauge icon with a rotating needle.
/// Uses Circle trim + Capsule for clean rendering at small sizes.
struct EffortGaugeView: View {
    /// 0.0 = leftmost (low), 1.0 = rightmost (max)
    var value: Double
    var size: CGFloat = 12

    /// Arc spans 270° (open 90° at bottom).
    private let arcFraction: Double = 270.0 / 360.0
    /// Rotation to center the 90° gap at the bottom.
    private let arcRotation: Double = 135

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
                .rotationEffect(.degrees(arcRotation))
                .opacity(0.5)
                .padding(size * 0.10)

            Circle()
                .frame(width: size * 0.20, height: size * 0.20)
                .offset(y: -size * 0.14)
                .rotationEffect(.degrees(-135 + 270 * value))
                .animation(.smooth(duration: 0.4), value: value)
        }
        .frame(width: size, height: size)
    }

    /// Render the gauge into an NSImage for use in NSMenu items.
    static func renderImage(value: Double, size: CGFloat, tintColor: NSColor) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let padding = size * 0.15
        let totalSize = size + padding * 2
        let content = EffortGaugeView(value: value, size: size)
            .foregroundStyle(Color(nsColor: tintColor))
            .padding(padding)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSApp.effectiveAppearance
        let fittingSize = NSSize(width: totalSize, height: totalSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layout()

        let pixelSize = NSSize(width: totalSize * scale, height: totalSize * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = fittingSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            // NSHostingView renders y-down but bitmap context is y-up — flip
            ctx.translateBy(x: 0, y: totalSize)
            ctx.scaleBy(x: 1, y: -1)
            hostingView.layer?.render(in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: fittingSize)
        image.addRepresentation(rep)
        return image
    }
}
