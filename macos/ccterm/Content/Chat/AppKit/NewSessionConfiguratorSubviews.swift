import AppKit

// MARK: - Capsule pill button (worktree / branch meta pills)

/// The worktree + branch meta pills (`NewSessionConfigurator.swift:496-566`).
/// AppKit equivalent of SwiftUI `.buttonStyle(HoverCapsuleStyle())` PLUS the
/// static `Capsule().strokeBorder(separatorColor.opacity(0.7), 0.5)` overlay:
///
/// - a 0.5pt `separatorColor`@0.7 capsule stroke at rest (so the pill reads as
///   a button even before hover — the SwiftUI comment calls this load-bearing),
/// - a `labelColor` capsule fill at 0.08 hover / 0.15 press
///   (`HoverCapsuleStyle.swift:48-50`),
/// - 6pt horizontal / 4pt vertical content inset
///   (`HoverCapsuleModifier.swift:34-35`).
///
/// Content is an SF-symbol image + a 12pt label, `.secondaryLabelColor`. The
/// stroke cgColor is re-resolved on appearance change (R14).
@MainActor
final class CapsulePillButton: NSControl {
    nonisolated deinit {}

    /// `HoverCapsuleModifier` content insets.
    private static let hInset: CGFloat = 6
    private static let vInset: CGFloat = 4

    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleNone
        addSubview(imageView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        NSLayoutConstraint.activate([
            // 14×14 icon frame (`NewSessionConfigurator.swift:515,541`).
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 4pt icon→label spacing (`HStack(spacing: 4)`).
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.vInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(symbolName: String, title: String) {
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        label.stringValue = title
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasInside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if wasInside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2  // capsule
        // Hover/press fill (labelColor 0.08 hover / 0.15 press).
        let fillAlpha: CGFloat = isPressed ? 0.15 : (isHovered ? 0.08 : 0)
        if fillAlpha > 0 {
            NSColor.labelColor.withAlphaComponent(fillAlpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        // Static 0.5pt separatorColor@0.7 stroke at rest (inset so it stays
        // fully inside bounds).
        let strokeRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let strokePath = NSBezierPath(
            roundedRect: strokeRect, xRadius: radius - 0.25, yRadius: radius - 0.25)
        strokePath.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        strokePath.stroke()
    }
}

// MARK: - Compose bar host

/// Bottom-anchored stack of the embedded input bar pill + its chrome row, with
/// the compose card insets (`.padding(.horizontal, 28).padding(.bottom, 18)`,
/// `NewSessionConfigurator.swift:418-419`). Unlike the chat resting bar's
/// `RestingBarContainerView`, the compose overlay applies NO inner width cap —
/// the bar fills the main column minus the 28pt side insets. Sizing is regime B:
/// publishes a content-driven HEIGHT (so the pill can grow with text /
/// completion popup) and NO intrinsic width (`noIntrinsicMetric`, plan R1).
@MainActor
final class ComposeBarHostView: NSView {
    nonisolated deinit {}

    private let bottomInset: CGFloat
    private let innerContent = NSView()

    init(
        barView: InputBarView,
        chromeRow: NSView,
        horizontalInset: CGFloat,
        bottomInset: CGFloat,
        barSpacing: CGFloat
    ) {
        self.bottomInset = bottomInset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Re-query our cached intrinsic height when the bar re-sums (text grow /
        // attachment band / completion popup) so the intrinsic path can't win
        // with a stale value (R7).
        barView.onIntrinsicHeightChanged = { [weak self] in
            self?.invalidateIntrinsicContentSize()
        }

        innerContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerContent)
        barView.translatesAutoresizingMaskIntoConstraints = false
        chromeRow.translatesAutoresizingMaskIntoConstraints = false
        innerContent.addSubview(barView)
        innerContent.addSubview(chromeRow)

        NSLayoutConstraint.activate([
            innerContent.topAnchor.constraint(equalTo: topAnchor),
            innerContent.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            innerContent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            innerContent.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -horizontalInset),

            barView.topAnchor.constraint(equalTo: innerContent.topAnchor),
            barView.leadingAnchor.constraint(equalTo: innerContent.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: innerContent.trailingAnchor),

            chromeRow.topAnchor.constraint(equalTo: barView.bottomAnchor, constant: barSpacing),
            chromeRow.leadingAnchor.constraint(equalTo: innerContent.leadingAnchor),
            chromeRow.trailingAnchor.constraint(equalTo: innerContent.trailingAnchor),
            chromeRow.bottomAnchor.constraint(equalTo: innerContent.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Regime B: content-driven HEIGHT, no intrinsic width (plan R1).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: innerContent.fittingSize.height + bottomInset)
    }
}

// MARK: - Card surface

/// The compose card's surface: an `NSVisualEffectView` (.ultraThinMaterial
/// analogue) with a continuous-rounded mask + 0.5pt `separatorColor` border + a
/// shadow on an OUTER compositing wrapper (shadow-outside-clip, mirroring
/// `BarSurfaceView`). Migration plan §4.6 appkitMapping.
///
/// CRITICAL (plan R1): the root publishes `intrinsicContentSize = .zero` so its
/// min-size constraints never leak up into `ComposeContentView`'s 4-edge-pinned
/// root and collapse the window. The card is sized by the centerX/centerY +
/// width/height band the parent applies; this view contributes no `fittingSize`.
@MainActor
final class CardSurfaceView: NSView {
    nonisolated deinit {}

    private let cornerRadius: CGFloat
    private let effectView = NSVisualEffectView()
    private let glowView = AtmosphericGlowView()
    /// Columns are added here so they clip to the rounded corner.
    let contentContainer = NSView()
    private let borderLayer = CAShapeLayer()

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Shadow lives on THIS (the outer wrapper), outside the clip:
        // .black 0.22, radius 30, x0 y10 (:170).
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: 10)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        addSubview(effectView)

        glowView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(glowView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = cornerRadius
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.masksToBounds = true
        effectView.addSubview(contentContainer)

        // 0.5pt separatorColor border on top.
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 0.5
        borderLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer?.addSublayer(borderLayer)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glowView.topAnchor.constraint(equalTo: effectView.topAnchor),
            glowView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            glowView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            glowView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Publish `.zero` so the card's min-size band never leaks `fittingSize`
    /// up through the 4-edge-pinned `ComposeContentView` root (plan R1).
    override var intrinsicContentSize: NSSize { .zero }

    override func layout() {
        super.layout()
        updateBorderPath()
        layer?.shadowPath =
            CGPath(
                roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var resolved = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        }
        borderLayer.strokeColor = resolved
        CATransaction.commit()
    }

    private func updateBorderPath() {
        // 0.5pt inset so the stroke sits fully inside the bounds.
        let inset = bounds.insetBy(dx: 0.25, dy: 0.25)
        borderLayer.frame = bounds
        borderLayer.path =
            CGPath(
                roundedRect: inset, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil)
    }

    private static func maskImage(cornerRadius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Atmospheric glow

/// Radial accent glow anchored top-left (`atmosphericGlow`, :209-219): accent
/// 0.10 → 0.0, center UnitPoint(0.18, 0.10), endRadius 420. Drawn so it tracks
/// the appearance automatically.
@MainActor
private final class AtmosphericGlowView: NSView {
    nonisolated deinit {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.width * 0.18, y: bounds.height * (1 - 0.10))
        let accent = NSColor.controlAccentColor
        let colors =
            [accent.withAlphaComponent(0.10).cgColor, accent.withAlphaComponent(0.0).cgColor]
            as CFArray
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                locations: [0, 1])
        else { return }
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420,
            options: [])
    }
}

// MARK: - Tinted left column

/// The recents column recess: slate-blue tint (RGB 0.40/0.47/0.60 @ 0.05,
/// :138) + 0.5pt trailing `separatorColor` hairline (:139-143). Drawn so the
/// tint + hairline re-resolve on appearance flip (semantic NSColor in `draw`).
@MainActor
final class TintedColumnView: NSView {
    nonisolated deinit {}

    private static let tint = NSColor(red: 0.40, green: 0.47, blue: 0.60, alpha: 0.05)

    override func draw(_ dirtyRect: NSRect) {
        Self.tint.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
    }
}

// MARK: - Plus hover button

/// The `+` button in the Projects header (`PlusHoverButtonStyle`, :744-758):
/// 22×22 hit target, SF "plus" .system(size:12,weight:.semibold) .secondary,
/// circle fill primary 0.08 hover / 0.15 press.
@MainActor
final class PlusHoverButton: NSControl {
    nonisolated deinit {}

    var onClick: (() -> Void)?
    private let imageView = NSImageView()
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }
    override func mouseUp(with event: NSEvent) {
        let wasInside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if wasInside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isPressed ? 0.15 : (isHovered ? 0.08 : 0)
        guard alpha > 0 else { return }
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Recent project row

/// A recents-list row: project name (`.system(13,.medium)`) over the
/// abbreviated path (`.system(11)` .secondary, truncation .middle). Layout
/// constants from `recentRow` (:344-357).
@MainActor
final class RecentProjectRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("RecentProjectRowView")

    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.usesSingleLineMode = true
        addSubview(nameLabel)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.cell?.usesSingleLineMode = true
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, abbreviatedPath: String) {
        nameLabel.stringValue = name
        pathLabel.stringValue = abbreviatedPath
    }
}

// MARK: - Resume (recent-session) row

/// A "Recent Sessions" row: title (`.system(13)` .primary) + monospaced-digit
/// relative time (`.system(11)` .secondary). Flat link-style, rounded-6
/// hover/press fill (`ResumeRowButtonStyle`, :763-778). Layout from `resumeRow`
/// (:629-655).
@MainActor
final class ResumeRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResumeRowView")

    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        addSubview(titleLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, relativeTime: String) {
        titleLabel.stringValue = title
        timeLabel.stringValue = relativeTime
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    // Press feedback (`ResumeRowButtonStyle` pressed 0.10 / hover 0.06,
    // `NewSessionConfigurator.swift:766-776`). Forward to `super` so the
    // enclosing NSTableView still receives the click → its `action`
    // (`recentSessionRowClicked` → `onResumeSession`) fires.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isPressed ? 0.10 : (isHovered ? 0.06 : 0)
        guard alpha > 0 else { return }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0, dy: 0), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        shape.fill()
    }
}
