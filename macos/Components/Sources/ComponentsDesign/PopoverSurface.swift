import AppKit
import Components

/// A menu open in its system popover, drawn still (design 08 *Menus are
/// popovers*, preview-live.js `shapePopover`): what `NSPopover` draws around
/// `MenuPanelViewController`, which an off-screen page can't open — the body
/// at the content's size with continuous 20-pt corners, the arrow 10.5 tall
/// and 28 across on the control's centre, its tip 2.5 off the control, the
/// popover's own material (`.popover`, as the account heads that stick over
/// the list are), a hairline and the shadow under it. The live specimen opens
/// the real one.
final class PopoverSurface: NSView {
    /// The side the arrow is on: the control's side.
    enum Edge {
        /// Under the control, pointing up.
        case top
        /// Over the control, pointing down.
        case bottom
    }

    static let arrowHeight: CGFloat = 10.5
    static let arrowBase: CGFloat = 28
    /// From the arrow's tip to the control.
    static let tipGap: CGFloat = 2.5

    private let edge: Edge
    private let bodySize: NSSize
    /// The arrow's centre, from the body's leading edge.
    private let arrowX: CGFloat
    private let body = NSView()
    private let material = NSVisualEffectView()
    private let hairline = CALayer()
    private let drop = CALayer()

    /// `view` at `size` in a popover whose arrow is on `edge`, `arrowX` along
    /// it (its middle when `nil`, kept clear of the corners).
    init(holding view: NSView, size: NSSize, edge: Edge, arrowX: CGFloat? = nil) {
        self.edge = edge
        bodySize = size
        let half = Self.arrowBase / 2
        self.arrowX = min(
            max(arrowX ?? size.width / 2, CornerRadius.systemPopover + half),
            size.width - CornerRadius.systemPopover - half)
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + Self.arrowHeight))
        wantsLayer = true
        for layer in [drop, hairline] { self.layer?.addSublayer(layer) }
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.frame = bounds
        addSubview(material)
        body.wantsLayer = true
        body.layer?.cornerRadius = CornerRadius.systemPopover
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        body.frame = NSRect(
            origin: NSPoint(x: 0, y: edge == .top ? Self.arrowHeight : 0), size: size)
        addSubview(body)
        view.frame = body.bounds
        view.autoresizingMask = [.width, .height]
        body.addSubview(view)
        shape()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// Placed against `control` (in the superview's coordinates): centred on
    /// it, the arrow's tip 2.5 off its edge, the arrow kept on its centre.
    static func frame(for size: NSSize, edge: Edge, against control: NSRect, flipped: Bool) -> NSRect {
        let height = size.height + arrowHeight
        let x = (control.midX - size.width / 2).rounded()
        // `edge` is the control's side: under it in a flipped view is larger y.
        let below = edge == .top
        let y: CGFloat =
            flipped
            ? (below ? control.maxY + tipGap : control.minY - tipGap - height)
            : (below ? control.minY - tipGap - height : control.maxY + tipGap)
        return NSRect(x: x, y: y, width: size.width, height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shape()
    }

    private func shape() {
        let path = framePath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [drop, hairline] { layer.frame = bounds }
        material.maskImage = Self.mask(path, size: bounds.size)
        // A path's shadow is cast whatever the layer holds.
        drop.shadowPath = path
        // `0 8px 22px`: down, in this flipped view's layers.
        drop.shadowOffset = CGSize(width: 0, height: 8)
        drop.shadowRadius = 11
        drop.shadowOpacity = 1
        hairline.shadowPath = path
        hairline.shadowOffset = .zero
        hairline.shadowRadius = 0.4
        hairline.shadowOpacity = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            hairline.shadowColor = (isDark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.42)).cgColor
            drop.shadowColor = NSColor(white: 0, alpha: isDark ? 0.4 : 0.16).cgColor
        }
        CATransaction.commit()
    }

    /// `path` (flipped, as this view draws) as the material's mask.
    private static func mask(_ path: CGPath, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
    }

    /// The body's continuous corners and the arrow, flaring into the body's
    /// edge and rounded at its tip, in this view's flipped coordinates.
    private func framePath() -> CGPath {
        let w = bodySize.width
        let h = bodySize.height
        let a = Self.arrowHeight
        let top = edge == .top ? a : 0
        let path = CGMutablePath()
        path.addPath(
            Self.continuousRect(width: w, height: h, radius: CornerRadius.systemPopover),
            transform: CGAffineTransform(translationX: 0, y: top))
        let half = Self.arrowBase / 2
        let x = arrowX
        // The base on the body's edge; the tip 0.4 short of the frame's.
        let base = edge == .top ? a : h
        let tip = edge == .top ? 0.4 : h + a - 0.4
        path.move(to: CGPoint(x: x - half - 2, y: base))
        path.addCurve(
            to: CGPoint(x: x, y: tip), control1: CGPoint(x: x - half + 6, y: base),
            control2: CGPoint(x: x - 3.2, y: tip))
        path.addCurve(
            to: CGPoint(x: x + half + 2, y: base), control1: CGPoint(x: x + 3.2, y: tip),
            control2: CGPoint(x: x + half - 6, y: base))
        path.closeSubpath()
        return path
    }

    /// A rectangle with continuous corners: preview-live.js `contRect`, the
    /// curve `cornerCurve = .continuous` draws.
    private static func continuousRect(width w: CGFloat, height h: CGFloat, radius: CGFloat) -> CGPath {
        let r = min(radius, min(w, h) / 2 / 1.52866483)
        let k = [1.52866483, 1.08849299, 0.86840701, 0.63149399, 0.074911, 0.37282401, 0.16905899, 0.02101100].map {
            $0 * r
        }
        let (a, b, c, d, e, f, g, i) = (k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7])
        let path = CGMutablePath()
        func curve(_ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat)) {
            path.addCurve(
                to: CGPoint(x: to.0, y: to.1), control1: CGPoint(x: c1.0, y: c1.1),
                control2: CGPoint(x: c2.0, y: c2.1))
        }
        path.move(to: CGPoint(x: a, y: 0))
        path.addLine(to: CGPoint(x: w - a, y: 0))
        curve((w - b, 0), (w - c, i), (w - d, e))
        curve((w - f, g), (w - g, f), (w - e, d))
        curve((w - i, c), (w, b), (w, a))
        path.addLine(to: CGPoint(x: w, y: h - a))
        curve((w, h - b), (w - i, h - c), (w - e, h - d))
        curve((w - g, h - f), (w - f, h - g), (w - d, h - e))
        curve((w - c, h - i), (w - b, h), (w - a, h))
        path.addLine(to: CGPoint(x: a, y: h))
        curve((b, h), (c, h - i), (d, h - e))
        curve((f, h - g), (g, h - f), (e, h - d))
        curve((i, h - c), (0, h - b), (0, h - a))
        path.addLine(to: CGPoint(x: 0, y: a))
        curve((0, b), (i, c), (e, d))
        curve((g, f), (f, g), (d, e))
        curve((c, i), (b, 0), (a, 0))
        path.closeSubpath()
        return path
    }
}
