import AppKit

/// One full-width option row in the AskUserQuestion wizard (migration plan
/// §4.5). The AppKit replacement for the SwiftUI `optionRow` + `AskOptionRowStyle`
/// (`PermissionAskUserQuestionCardBody.swift:194-221,531-583`).
///
/// A self-drawn, flipped `NSView` whose height is `AskUserQuestionLayout.rowHeight`
/// (36pt) as a FLOOR (`>=`, plus 8pt vertical padding) — matching the SwiftUI
/// `.padding(.vertical, 8).frame(minHeight: rowHeight)` on `AskOptionRowStyle`
/// (`:546-548`), so a row carrying a 2-line description grows past 36pt instead
/// of clipping. (The Other EDITING row is the fixed-36pt case — that lives in
/// `AskOtherRowView`.) It hosts a label + optional 2-line description on the
/// leading edge and a trailing ✓ when selected. Hover lightens the fill;
/// selected pulls in the accent fill + stroke (verbatim color math). No
/// press-deflate scale (`:530`) — D5 keeps transitions opacity-only.
///
/// Interaction is a stateful `mouseDown` → `mouseUp`-inside action (NOT a nested
/// `nextEvent` pump — repo rule from Phase-1 #42/#79). Dynamic cgColors are
/// re-resolved in `viewDidChangeEffectiveAppearance` wrapped in a disabled
/// `CATransaction` (R14). Accessibility role `.button` + label = option label
/// (§4.5-7 — SwiftUI Buttons were accessible free).
@MainActor
final class AskOptionRowView: NSView {

    // MARK: - Inputs

    let label: String
    let optionDescription: String?
    /// Fired on mouse-up inside the row.
    var onTap: (() -> Void)?

    // MARK: - State

    var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            applyColors(animated: false)
            checkmark.isHidden = !isSelected
            updateAccessibilitySelected()
        }
    }

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyColors(animated: true)
        }
    }

    private var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            applyColors(animated: true)
        }
    }

    private var trackingArea: NSTrackingArea?

    // MARK: - Layers / subviews

    private let fillLayer = CALayer()
    private let strokeLayer = CAShapeLayer()
    private let labelField = NSTextField(labelWithString: "")
    private let descField = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let textStack = NSStackView()

    // MARK: - Init

    init(label: String, description: String?, selected: Bool) {
        self.label = label
        self.optionDescription = description
        self.isSelected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        fillLayer.cornerCurve = .continuous
        fillLayer.cornerRadius = AskUserQuestionLayout.rowCornerRadius
        fillLayer.masksToBounds = true
        layer?.addSublayer(fillLayer)

        strokeLayer.fillColor = nil
        layer?.addSublayer(strokeLayer)

        // Leading label + optional description column (spacing 1, leading —
        // `:201`).
        labelField.stringValue = label
        labelField.font = .systemFont(ofSize: AskUserQuestionLayout.optionLabelSize)
        labelField.textColor = .labelColor
        labelField.maximumNumberOfLines = 1
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = AskUserQuestionLayout.optionTextSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(labelField)

        if let description, !description.isEmpty {
            descField.stringValue = description
            descField.font = .systemFont(ofSize: AskUserQuestionLayout.optionDescriptionSize)
            descField.textColor = .secondaryLabelColor
            descField.maximumNumberOfLines = 2  // `:209`
            descField.lineBreakMode = .byTruncatingTail
            descField.translatesAutoresizingMaskIntoConstraints = false
            textStack.addArrangedSubview(descField)
        }

        // Trailing checkmark (size 11 semibold, tint — `:213-216`).
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: AskUserQuestionLayout.checkmarkSize, weight: .semibold))
        checkmark.contentTintColor = .controlAccentColor
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.isHidden = !selected

        addSubview(textStack)
        addSubview(checkmark)

        // Option rows use a MIN height (not fixed) + 8pt vertical padding so a
        // row carrying a 2-line description grows past 36pt — matching the
        // SwiftUI `.padding(.vertical, 8).frame(minHeight: rowHeight)` on
        // `AskOptionRowStyle` (`:546-548`). (The Other EDITING row is the one
        // that stays a fixed 36pt — that lives in `AskOtherRowView`.) The text
        // stack is pinned top/bottom with the 8pt inset at a priority below
        // required so the `>= rowHeight` floor wins for a single-line row, and
        // centered so a single line sits mid-row.
        let minHeight = heightAnchor.constraint(
            greaterThanOrEqualToConstant: AskUserQuestionLayout.rowHeight)
        let topPad = textStack.topAnchor.constraint(
            equalTo: topAnchor, constant: AskUserQuestionLayout.optionVPadding)
        topPad.priority = .defaultHigh
        let bottomPad = textStack.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -AskUserQuestionLayout.optionVPadding)
        bottomPad.priority = .defaultHigh

        NSLayoutConstraint.activate([
            minHeight,
            topPad,
            bottomPad,
            textStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: AskUserQuestionLayout.rowHPadding),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: checkmark.leadingAnchor,
                constant: -AskUserQuestionLayout.rowContentSpacing),
            checkmark.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -AskUserQuestionLayout.rowHPadding),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        updateAccessibilitySelected()

        applyContentsScale()
        applyColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Flipped (origin top-left so layout reads naturally)

    override var isFlipped: Bool { true }

    // MARK: - Test-observation points (read-only; not consumed in production)

    var resolvedFillColor: CGColor? { fillLayer.backgroundColor }
    var resolvedStrokeColor: CGColor? { strokeLayer.strokeColor }
    var resolvedStrokeWidth: CGFloat { strokeLayer.lineWidth }
    var isCheckmarkVisible: Bool { !checkmark.isHidden }

    // MARK: - In-place label update (used by AskOtherRowView's collapsed form)

    /// Update the displayed label in place (the collapsed Other row shows the
    /// typed text when non-empty). Keeps the same row identity so a pure text
    /// change never recreates the view.
    func setLabel(_ newLabel: String) {
        labelField.stringValue = newLabel
        setAccessibilityLabel(newLabel)
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
    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
    }

    // MARK: - Click (stateful mouseDown → mouseUp-inside; no nextEvent pump)

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onTap?() }
    }

    // MARK: - Appearance / backing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    private func applyContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        fillLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
    }

    // MARK: - Color math (verbatim `:569-582`)

    /// `:569-578`.
    private var fillColor: NSColor {
        if isSelected {
            return pressed
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.controlAccentColor.withAlphaComponent(0.12)
        }
        if pressed { return NSColor.labelColor.withAlphaComponent(0.14) }
        if hovering { return NSColor.labelColor.withAlphaComponent(0.08) }
        return NSColor.labelColor.withAlphaComponent(0.04)
    }

    /// `:580-582`.
    private var strokeColor: NSColor {
        isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.55) : .separatorColor
    }

    /// `:561` — selected 1pt, unselected 0.5pt.
    private var strokeWidth: CGFloat { isSelected ? 1 : 0.5 }

    private func applyColors(animated: Bool) {
        var fill: CGColor = fillColor.cgColor
        var stroke: CGColor = strokeColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = self.fillColor.cgColor
            stroke = self.strokeColor.cgColor
        }
        let width = strokeWidth

        if animated {
            // Hover/press cross-fade — 0.08s hover / 0.06s press linear (`:565-566`).
            CATransaction.begin()
            let duration =
                pressed
                ? AskUserQuestionLayout.pressAnimDuration
                : AskUserQuestionLayout.hoverAnimDuration
            let fillAnim = CABasicAnimation(keyPath: "backgroundColor")
            fillAnim.duration = duration
            fillAnim.timingFunction = CAMediaTimingFunction(name: .linear)
            fillLayer.add(fillAnim, forKey: "rowFill")
            fillLayer.backgroundColor = fill
            strokeLayer.strokeColor = stroke
            strokeLayer.lineWidth = width
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.removeAnimation(forKey: "rowFill")
            fillLayer.backgroundColor = fill
            strokeLayer.strokeColor = stroke
            strokeLayer.lineWidth = width
            CATransaction.commit()
        }
    }

    private func applyGeometry() {
        let radius = AskUserQuestionLayout.rowCornerRadius
        fillLayer.frame = bounds
        fillLayer.cornerRadius = radius
        fillLayer.cornerCurve = .continuous

        let inset = strokeWidth / 2
        let strokeRect = bounds.insetBy(dx: inset, dy: inset)
        let strokeRadius = max(0, radius - inset)
        strokeLayer.frame = bounds
        if bounds.width > 0, bounds.height > 0 {
            strokeLayer.path = BarSurfaceMask.continuousRoundedPath(
                in: strokeRect, cornerRadius: strokeRadius)
        } else {
            strokeLayer.path = nil
        }
    }

    private func updateAccessibilitySelected() {
        setAccessibilityValue(isSelected)
    }
}
