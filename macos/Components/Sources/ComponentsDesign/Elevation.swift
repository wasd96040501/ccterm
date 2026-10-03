import AppKit

/// A surface the design lifts off what is behind it — a window, a sheet: a
/// fill with rounded corners, a hairline edge, and its shadows, all as the
/// design's CSS draws them (`design/settings/index.html`, `.window` and
/// `.sheet`; `design/transcript/preview.css`, `.window`). Its content is
/// clipped to the corners; the shadows fall outside the view's bounds.
final class ElevatedView: NSView {
    /// `box-shadow`, one value per appearance.
    struct Shadow {
        /// `0 0 0 .5px`: the hairline outside the edge.
        var ring: (light: NSColor, dark: NSColor)
        /// Dark mode's `inset 0 0 0 .5px`: a light hairline inside the edge.
        var innerRing: NSColor?
        /// `0 <dy> <blur>` colours: the shadows under it, nearest last.
        var drops: [(dy: CGFloat, blur: CGFloat, light: NSColor, dark: NSColor)]
    }

    /// What goes inside; clipped to the corners.
    let content = NSView()

    private let radius: CGFloat
    private let fill: NSColor
    private let elevation: Shadow
    private let ringLayer = CALayer()
    private let dropLayers: [CALayer]

    init(radius: CGFloat, fill: NSColor, shadow: Shadow) {
        self.radius = radius
        self.fill = fill
        self.elevation = shadow
        dropLayers = elevation.drops.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [ringLayer] + dropLayers {
            layer.cornerCurve = .continuous
            layer.cornerRadius = radius
            self.layer?.addSublayer(layer)
        }
        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let rect = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = rect.insetBy(dx: -0.5, dy: -0.5)
        ringLayer.cornerRadius = radius + 0.5
        for (layer, drop) in zip(dropLayers, elevation.drops) {
            layer.frame = rect
            layer.cornerRadius = radius
            layer.shadowPath = CGPath(
                roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            // CSS blur is the Gaussian's diameter; a layer's radius is half.
            layer.shadowRadius = drop.blur / 2
            layer.shadowOffset = CGSize(width: 0, height: drop.dy)
            layer.shadowOpacity = 1
        }
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill = self.fill.cgColor
            ringLayer.backgroundColor = (isDark ? elevation.ring.dark : elevation.ring.light).cgColor
            for (layer, drop) in zip(dropLayers, elevation.drops) {
                // The shadow is cast by a layer with a fill; the content hides it.
                layer.backgroundColor = fill
                layer.shadowColor = (isDark ? drop.dark : drop.light).cgColor
            }
            content.layer?.backgroundColor = fill
            content.layer?.borderWidth = isDark && elevation.innerRing != nil ? 0.5 : 0
            content.layer?.borderColor = elevation.innerRing?.cgColor
        }
    }
}

extension NSColor {
    /// A colour of the design's: one value per appearance.
    static func design(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func design(white: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(white: white, alpha: alpha)
    }

    /// `#rrggbb` as the design writes it.
    static func design(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}
