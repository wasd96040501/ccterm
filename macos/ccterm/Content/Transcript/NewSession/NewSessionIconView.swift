import AppKit
import CoreImage
import QuartzCore

/// The New view's decoration (design 08 *The New view*): the app icon at 64 pt
/// over a soft glow made of the icon's cursor ramp, both holding still until
/// Send. `rise()` is Send's one motion: a white light passes up the icon's
/// cursor, row by row from the bottom, while the glow swells.
///
/// The icon is `AppIconArt`, the rendition `design/icon` exports for each
/// appearance (full bleed, as the Dock draws it), so Dark shows the Dark
/// rendition. Its cursor sits at fixed fractions of the image, which is where
/// the light's rows go.
@MainActor
final class NewSessionIconView: NSView {
    /// The icon's side, points.
    static let side: CGFloat = 64
    /// Send's rise, seconds (design 08: 600 ms, decelerating).
    static let riseDuration: TimeInterval = 0.6
    /// A row's onset, seconds, counted from the bottom row (k = 0): `65k + 5k²` ms —
    /// the moments an ease-out level reaches each row.
    static func onset(ofRow k: Int) -> TimeInterval { TimeInterval(65 * k + 5 * k * k) / 1000 }
    /// A row's flash, seconds.
    static let flashDuration: TimeInterval = 0.24
    /// How bright a row's white flash gets.
    static let flashPeak: Float = 0.55
    /// The cursor's rows, bottom to top (layer names `rise-row-<k>`).
    static let rowCount = 5

    private let glowView = GlowView()
    private let artView = NSImageView()
    private let lightView = LightView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    private func configureHierarchy() {
        artView.image = NSImage(resource: .appIconArt)
        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.wantsLayer = true
        // `drop-shadow(0 6px 14px rgba(20, 18, 24, 0.22))`, from the icon's own alpha.
        artView.layer?.shadowColor = NSColor(srgbRed: 20 / 255, green: 18 / 255, blue: 24 / 255, alpha: 1).cgColor
        artView.layer?.shadowOpacity = 0.22
        artView.layer?.shadowRadius = 7
        artView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        artView.layer?.masksToBounds = false
        for subview in [glowView, artView, lightView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
    }

    private func configureConstraints() {
        var constraints = [
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ]
        for subview in [glowView, artView, lightView] {
            constraints += [
                subview.leadingAnchor.constraint(equalTo: leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: trailingAnchor),
                subview.topAnchor.constraint(equalTo: topAnchor),
                subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - The rise

    /// Plays Send's rise: the five rows' flashes and the glow's swell. The
    /// glow stays up when it ends. Not under Reduce Motion — the caller skips it.
    func rise() {
        lightView.flash(rows: Self.rowCount)
        glowView.swell()
    }

    /// Ends the rise where it is: the flashes gone, the glow back at rest, at once.
    func settle() {
        lightView.stop()
        glowView.settle()
    }
}

// MARK: - Glow

/// The glow: the cursor ramp (peach → coral → violet) as a vertical gradient
/// under a radial mask, blurred 20 pt, at 60 % of its full strength — 42 %,
/// 36 % in Dark — centred two thirds of the way down the icon.
@MainActor
private final class GlowView: NSView {
    /// The glow's own size, before the blur, points.
    private static let size = CGSize(width: 112, height: 84)
    private static let blur: CGFloat = 20
    /// Room around the glow for the blur to spread into.
    private static let margin: CGFloat = 60
    /// Where the glow sits on the icon: its centre, from the icon's top.
    private static let centerFromTop: CGFloat = 0.66
    /// The glow at rest as a share of its full strength.
    private static let restShare: Float = 0.6

    private let glowLayer = CALayer()
    private var isRisen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        glowLayer.name = "glow"
        glowLayer.contents = Self.image
        glowLayer.bounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: Self.size.width + 2 * Self.margin, height: Self.size.height + 2 * Self.margin))
        layer?.addSublayer(glowLayer)
        applyStrength()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The full strength: 42 %, 36 % in Dark.
    private var fullStrength: Float {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.36 : 0.42
    }

    private func applyStrength() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = isRisen ? fullStrength : fullStrength * Self.restShare
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStrength()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer's y runs up: the centre is `centerFromTop` down from the top.
        glowLayer.position = CGPoint(x: bounds.midX, y: bounds.maxY - bounds.height * Self.centerFromTop)
        CATransaction.commit()
    }

    /// The swell: opacity to full strength and the glow grows (1.08 × 1.18)
    /// and lifts 4 % of its height, on cubic-bezier(.2, .7, .2, 1), over the
    /// rise's 600 ms; it stays there.
    func swell() {
        let rest = glowLayer.opacity
        isRisen = true
        var risen = CATransform3DMakeTranslation(0, Self.size.height * 0.04, 0)
        risen = CATransform3DScale(risen, 1.08, 1.18, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = fullStrength
        glowLayer.transform = risen
        CATransaction.commit()

        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = rest
        opacity.toValue = fullStrength
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = CATransform3DIdentity
        transform.toValue = risen
        for animation in [opacity, transform] {
            animation.duration = NewSessionIconView.riseDuration
            animation.timingFunction = timing
        }
        glowLayer.add(opacity, forKey: "swell-opacity")
        glowLayer.add(transform, forKey: "swell-transform")
    }

    /// Back to rest at once: the swell's animations gone, strength and shape as before it.
    func settle() {
        isRisen = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.removeAllAnimations()
        glowLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        applyStrength()
    }

    /// The glow, blurred, drawn once: `margin` of room on every side.
    private static let image: CGImage? = {
        let scale: CGFloat = 2
        let pixels = CGSize(
            width: (size.width + 2 * margin) * scale, height: (size.height + 2 * margin) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: margin, y: margin, width: size.width, height: size.height)

        // Radial mask: opaque in the middle, clear at the closest side (an ellipse).
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: size.width / 2, y: size.height / 2)
        let maskColors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray
        guard let mask = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: maskColors, locations: [0, 1])
        else { return nil }
        // The mask as an alpha image: draw it, then keep only where it is opaque.
        context.drawRadialGradient(
            mask, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()

        // The ramp, through the mask. The context's y runs up; the ramp's peach is on top.
        context.setBlendMode(.sourceIn)
        let ramp =
            [
                CGColor(srgbRed: 1, green: 0xB4 / 255, blue: 0x6C / 255, alpha: 1),
                CGColor(srgbRed: 1, green: 0x6E / 255, blue: 0x7C / 255, alpha: 1),
                CGColor(srgbRed: 0xB9 / 255, green: 0x5C / 255, blue: 0xF8 / 255, alpha: 1),
            ] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: ramp, locations: [0, 0.5, 1]) else { return nil }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        guard let sharp = context.makeImage() else { return nil }

        // 20 pt of blur (a standard deviation of 20 points).
        let blurred = CIImage(cgImage: sharp)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blur * scale))
            .cropped(to: CGRect(origin: .zero, size: pixels))
        return CIContext().createCGImage(blurred, from: blurred.extent, format: .RGBA8, colorSpace: space)
    }()
}

// MARK: - Light

/// The rise's light: a white row over each of the icon's cursor rows, each
/// dark until its flash.
@MainActor
private final class LightView: NSView {
    /// The cursor, on the icon's 1024-unit canvas (`design/icon`'s `SHIP`:
    /// 48-unit pixels, the cursor 3 × 5 pixels at x 608, from y 428 down).
    private static let canvas: CGFloat = 1024
    private static let cursor = CGRect(x: 608, y: 428, width: 144, height: 240)

    private var rowLayers: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for k in 0..<NewSessionIconView.rowCount {
            let row = CALayer()
            row.name = "rise-row-\(k)"
            row.backgroundColor = NSColor.white.cgColor
            row.opacity = 0
            layer?.addSublayer(row)
            rowLayers.append(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let unit = bounds.width / Self.canvas
        let rowHeight = Self.cursor.height / CGFloat(NewSessionIconView.rowCount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, row) in rowLayers.enumerated() {
            // Row k counts from the bottom; the canvas's y runs down, the layer's up.
            let fromTop = Self.cursor.minY + CGFloat(NewSessionIconView.rowCount - 1 - k) * rowHeight
            row.frame = CGRect(
                x: Self.cursor.minX * unit, y: bounds.height - (fromTop + rowHeight) * unit,
                width: Self.cursor.width * unit, height: rowHeight * unit)
        }
        CATransaction.commit()
    }

    /// Every row dark again, at once.
    func stop() {
        for row in rowLayers { row.removeAllAnimations() }
    }

    /// Each row flashes white — up to 55 % in the first 30 % of 240 ms, then
    /// out, ease-out — from its onset; row 0 answers at once.
    func flash(rows: Int) {
        let start = layer.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? 0
        for (k, row) in rowLayers.enumerated() where k < rows {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, NewSessionIconView.flashPeak, 0]
            animation.keyTimes = [0, 0.3, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
            animation.duration = NewSessionIconView.flashDuration
            animation.beginTime = start + NewSessionIconView.onset(ofRow: k)
            animation.fillMode = .backwards
            row.add(animation, forKey: "flash")
        }
    }
}
