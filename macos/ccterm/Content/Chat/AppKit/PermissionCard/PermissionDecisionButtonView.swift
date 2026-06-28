import AppKit

/// AppKit replacement for the SwiftUI `PermissionDecisionButton`
/// (`PermissionCardView.swift:262-322`). A compact decision button — 24pt
/// tall, 8pt radius, three visual weights (primary / secondary / destructive).
/// Hover lifts the fill so the affordance reads on top of the card surface.
/// Shared across the permission card's generic chrome button row AND the
/// AskUserQuestion wizard's Deny / Confirm row (ported once — plan §4.4 / §4.5).
///
/// This is a 1:1 visual relocation of the SwiftUI button, not a redesign. All
/// numeric constants + color math are lifted verbatim:
///
/// - height = 24pt; corner radius = 8 (`.continuous`); horizontal text padding
///   = 12pt; title font = `NSFont.systemFont(ofSize: 12, weight: .medium)`;
///   stroke `lineWidth` = 0.5 (`PermissionCardView.swift:277-288`)
/// - hover animation = `.linear(duration: 0.1)` on the `hovering` flag
///   (`PermissionCardView.swift:293`) → a 0.1s linear CA animation over the
///   fill + text + stroke colors (D5 opacity-style color cross-fade, NOT a
///   transform/scale)
///
/// Color mapping (`PermissionCardView.swift:296-321`), SwiftUI → AppKit:
/// - foreground: primary → `.white`; secondary → `.primary` = `labelColor`;
///   destructive → `.red` = `systemRed`
/// - background: primary → `controlAccentColor` (hover α 0.92 / rest α 1.0);
///   secondary → `labelColor` α 0.10 hover / 0.04 rest; destructive →
///   `systemRed` α 0.16 hover / 0.08 rest
/// - stroke: primary → `.clear`; secondary → `separatorColor`; destructive →
///   `systemRed` α 0.4
///
/// Disabled / pressed are NOT modeled (the SwiftUI source is a plain `Button`
/// + `.plain` style) — only hover changes appearance; a click fires the action
/// immediately. The hit target is the full 24pt-tall rounded pill
/// (`PermissionCardView.swift:289` `.contentShape(Rectangle())`).
///
/// Named `PermissionDecisionButtonView` (not `PermissionDecisionButton`) only
/// because the SwiftUI `struct PermissionDecisionButton: View`
/// (`PermissionCardView.swift:262`) still exists in this phase — two top-level
/// declarations with the same name would be a duplicate-declaration error. When
/// the SwiftUI `PermissionCardView` is deleted (Phase 2b, per the plan), this
/// type takes over the bare `PermissionDecisionButton` name.
final class PermissionDecisionButtonView: NSControl {

    enum Role {
        case primary, secondary, destructive
    }

    // MARK: - Constants (verbatim from PermissionCardView.swift:277-288)

    /// Button height (`PermissionCardView.swift:280`).
    static let height: CGFloat = 24
    /// Corner radius (`PermissionCardView.swift:282,286`).
    static let cornerRadius: CGFloat = 8
    /// Horizontal text padding (`PermissionCardView.swift:279`).
    static let horizontalPadding: CGFloat = 12
    /// Title font (`PermissionCardView.swift:277`).
    static let titleFontSize: CGFloat = 12
    /// Stroke line width (`PermissionCardView.swift:287`).
    static let strokeLineWidth: CGFloat = 0.5
    /// Hover animation duration — `.linear(duration: 0.1)`
    /// (`PermissionCardView.swift:293`).
    static let hoverAnimationDuration: TimeInterval = 0.1

    // MARK: - Public

    let role: Role
    let title: String

    /// Fired on mouse-up inside the button (matching SwiftUI `Button(action:)`).
    /// Held in addition to the NSControl target/action so the card / wizard can
    /// wire it as a closure exactly like the SwiftUI call sites do.
    var onClick: (() -> Void)?

    // MARK: - State

    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyColors(animated: true)
        }
    }

    private var trackingArea: NSTrackingArea?

    // MARK: - Layers / subviews

    private let fillLayer = CALayer()
    private let strokeLayer = CAShapeLayer()
    private let titleLabel = NSTextField(labelWithString: "")

    // MARK: - Init

    init(title: String, role: Role, onClick: (() -> Void)? = nil) {
        self.title = title
        self.role = role
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        fillLayer.cornerCurve = .continuous
        fillLayer.cornerRadius = Self.cornerRadius
        fillLayer.masksToBounds = true
        layer?.addSublayer(fillLayer)

        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = Self.strokeLineWidth
        layer?.addSublayer(strokeLayer)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: Self.titleFontSize, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byClipping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.horizontalPadding),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.horizontalPadding),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        applyContentsScale()
        // Rest-state colors must NOT animate the first paint — wrap in a
        // disabled transaction so they snap (only the deliberate 0.1s hover
        // transition animates, plan §4.4 "Animation duration parity" risk).
        applyColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)
    //
    // Mirror `BarSurfaceView`'s precedent (BarSurfaceView.swift:207-258): expose
    // resolved layer / label state so CI-gate tests can assert the role→color
    // mapping + hover flip against the real production object. Read-only, no
    // mutation seam, no production consumers.

    var resolvedFillColor: CGColor? { fillLayer.backgroundColor }
    var resolvedStrokeColor: CGColor? { strokeLayer.strokeColor }
    var resolvedTextColor: NSColor? { titleLabel.textColor }
    var resolvedCornerRadius: CGFloat { fillLayer.cornerRadius }

    /// Whether a 0.1s linear hover color transition is currently pending on the
    /// fill layer — reads the REAL `CABasicAnimation` the animated path adds
    /// under the `hoverFill` key (snap writes add none). No production write;
    /// surfaces the live animation, not a product-set boolean. Tests assert the
    /// 0.1s linear hover animation is wired (`PermissionCardView.swift:293`).
    var hasPendingHoverAnimation: Bool { fillLayer.animation(forKey: "hoverFill") != nil }

    // MARK: - Hit target (full 24pt pill — PermissionCardView.swift:289)

    override var intrinsicContentSize: NSSize {
        // Width = title width + 2 * horizontal padding; height fixed at 24.
        let titleWidth = titleLabel.intrinsicContentSize.width
        return NSSize(width: titleWidth + 2 * Self.horizontalPadding, height: Self.height)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        applyGeometry()
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: - Click (mouse-up inside → action)

    override func mouseDown(with event: NSEvent) {
        // Swallow so the press doesn't fall through to the card surface.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        fire()
    }

    /// Single action source of truth — fires the stored closure AND the
    /// NSControl target/action (so either wiring style works). Used by the
    /// production click path and `sendAction`.
    private func fire() {
        onClick?()
        if let action {
            sendAction(action, to: target)
        }
    }

    // MARK: - Appearance / backing re-resolve

    /// `CALayer` cgColors freeze on a dark/light flip; the accent color
    /// (`controlAccentColor`) and `systemRed` are dynamic and must be
    /// re-resolved. Wrapped in a disabled `CATransaction` so the appearance
    /// change doesn't crossfade (R14, §4.4-3).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    // MARK: - Color resolution (verbatim mapping — PermissionCardView.swift:296-321)

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    private func applyContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        fillLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
    }

    /// SwiftUI `foreground` (PermissionCardView.swift:296-302).
    private var foregroundColor: NSColor {
        switch role {
        case .primary: return .white
        case .secondary: return .labelColor
        case .destructive: return .systemRed
        }
    }

    /// SwiftUI `background` (PermissionCardView.swift:304-313).
    private var backgroundColor: NSColor {
        switch role {
        case .primary:
            return hovering
                ? NSColor.controlAccentColor.withAlphaComponent(0.92)
                : NSColor.controlAccentColor
        case .secondary:
            return NSColor.labelColor.withAlphaComponent(hovering ? 0.10 : 0.04)
        case .destructive:
            return NSColor.systemRed.withAlphaComponent(hovering ? 0.16 : 0.08)
        }
    }

    /// SwiftUI `stroke` (PermissionCardView.swift:315-321).
    private var strokeColor: NSColor {
        switch role {
        case .primary: return .clear
        case .secondary: return .separatorColor
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.4)
        }
    }

    /// Resolve all three colors against the current appearance and write them
    /// to the layers / label. When `animated`, the fill + stroke colors
    /// cross-fade over 0.1s linear (reproducing SwiftUI's
    /// `.animation(.linear(duration: 0.1), value: hovering)`); rest-state
    /// writes (init / appearance flip) snap with a disabled transaction so
    /// they never inherit an enclosing card-appear animation context.
    private func applyColors(animated: Bool) {
        var fill: CGColor = backgroundColor.cgColor
        var stroke: CGColor = strokeColor.cgColor
        var text: NSColor = foregroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = self.backgroundColor.cgColor
            stroke = self.strokeColor.cgColor
            text = self.foregroundColor
        }

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.hoverAnimationDuration)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .linear))
            let fillAnim = CABasicAnimation(keyPath: "backgroundColor")
            fillAnim.duration = Self.hoverAnimationDuration
            fillAnim.timingFunction = CAMediaTimingFunction(name: .linear)
            fillLayer.add(fillAnim, forKey: "hoverFill")
            let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
            strokeAnim.duration = Self.hoverAnimationDuration
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .linear)
            strokeLayer.add(strokeAnim, forKey: "hoverStroke")
            fillLayer.backgroundColor = fill
            strokeLayer.strokeColor = stroke
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Snap writes never animate — drop any pending hover transition so a
            // rest/appearance-flip write can't leave a stale animation behind.
            fillLayer.removeAnimation(forKey: "hoverFill")
            strokeLayer.removeAnimation(forKey: "hoverStroke")
            fillLayer.backgroundColor = fill
            strokeLayer.strokeColor = stroke
            CATransaction.commit()
        }
        titleLabel.textColor = text
    }

    private func applyGeometry() {
        let size = bounds.size
        let radius = min(Self.cornerRadius, min(size.width, size.height) / 2)
        fillLayer.frame = bounds
        fillLayer.cornerRadius = max(0, radius)
        fillLayer.cornerCurve = .continuous

        let inset = Self.strokeLineWidth / 2
        let strokeRect = bounds.insetBy(dx: inset, dy: inset)
        let strokeRadius = max(0, radius - inset)
        strokeLayer.frame = bounds
        if size.width > 0, size.height > 0 {
            strokeLayer.path = BarSurfaceMask.continuousRoundedPath(
                in: strokeRect, cornerRadius: strokeRadius)
        } else {
            strokeLayer.path = nil
        }
    }
}
