import AppKit

/// AppKit replacement for `PopoverList.swift` (migration plan §4.2, §5). The
/// shared visual building blocks for the chrome-row popovers (permission /
/// model+effort), rendered as `NSStackView`-of-rows content inside an
/// `NSPopover` (NOT `NSTableView` — §4.2-4, no cell reuse so spinning glyphs
/// and tap rows have no recycle hazard).
///
/// Constants reused verbatim from `PopoverList.swift:10-18`.
enum PopoverListMetrics {
    static let width: CGFloat = 240
    static let rowHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 10
    static let outerPadding: CGFloat = 6
    static let maxHeight: CGFloat = 480

    /// Section header font (`PopoverList.swift:27` system 11 weight .medium).
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Row title font (`PopoverList.swift:49` system 13).
    static let rowTitleFont = NSFont.systemFont(ofSize: 13)
    /// Two-line model row secondary font (`ModelEffortPicker.swift:272` size 11).
    static let rowSubtitleFont = NSFont.systemFont(ofSize: 11)
    /// Hover background alpha (`PopoverList.swift:92` `Color.primary.opacity(0.06)`).
    static let hoverAlpha: CGFloat = 0.06
    /// Pressed background alpha (`PopoverList.swift:91` `Color.primary.opacity(0.12)`).
    static let pressedAlpha: CGFloat = 0.12
    /// Hover animation (`PopoverList.swift:87` `.animation(.linear(duration: 0.08))`).
    static let hoverAnimationDuration: CFTimeInterval = 0.08
    /// Row hover background corner radius (`PopoverList.swift:83` r6 .continuous).
    static let rowCornerRadius: CGFloat = 6
}

/// Section header line ("Mode" / "Models" / "Effort" / "Fast mode"). NOT
/// localized — CLI vocabulary (`PopoverList.swift:22-34`, `InputBarLabelsTests`
/// guards this).
final class PopoverSectionHeaderView: NSView {

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = PopoverListMetrics.headerFont
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // padding horizontal 10 / top 6 / bottom 2 (PopoverList.swift:30-32).
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverListMetrics.horizontalInset),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}
}

/// A self-drawn, hover-tracking row base for popover rows. Subclasses lay out
/// their content; this base paints the rounded hover/press background and
/// fires `onSelect` on click. No NSButton (so the two-line model row + the
/// fast-mode switch row share one hover treatment, matching SwiftUI's
/// `PopoverRowHoverStyle`).
class PopoverRowBaseView: NSView {

    let onSelect: () -> Void

    private let backgroundLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var pressed = false

    init(onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.cornerRadius = PopoverListMetrics.rowCornerRadius
        backgroundLayer.opacity = 0
        layer?.addSublayer(backgroundLayer)
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshBackground(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        refreshBackground(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
        refreshBackground(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        refreshBackground(animated: true)
        guard isPressInside else { return }
        isPressInside = false
        onSelect()
    }

    /// Whether the current drag is over the row bounds — set in
    /// `mouseDown`/`mouseDragged`, read in `mouseUp`. Stateful tracking across
    /// separate event deliveries (NOT a synchronous `nextEvent(matching:)`
    /// pump) keeps the main runloop draining dispatch / Observation /
    /// CoreAnimation work between drag events, so a press on a popover row can't
    /// stall an in-flight transcript-swap / isRunning `CATransaction` (the same
    /// pattern SendStopButton adopted).
    private var isPressInside = false

    private func refreshBackground(animated: Bool) {
        let target: Float = (pressed || hovering) ? 1 : 0
        if animated {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = backgroundLayer.presentation()?.opacity ?? backgroundLayer.opacity
            anim.toValue = target
            anim.duration = PopoverListMetrics.hoverAnimationDuration
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            backgroundLayer.add(anim, forKey: "opacity")
        }
        backgroundLayer.opacity = target
        // Pressed darkens; hover is the lighter fill. The opacity drives
        // 0→1; the base color encodes the *hover* alpha and pressed gets a
        // separate, fully-opaque-at-pressed-alpha re-color.
        applyBackgroundColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyBackgroundColor()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backgroundLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    private func applyBackgroundColor() {
        let alpha = pressed ? PopoverListMetrics.pressedAlpha : PopoverListMetrics.hoverAlpha
        var resolved: CGColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
        backgroundLayer.backgroundColor = resolved
    }
}

/// One selectable popover row: leading title (system 13 primary), trailing
/// checkmark (SF Symbol "checkmark", system 11 semibold secondary) when
/// selected. Height 28, horizontal inset 10 (`PopoverList.swift:39-66`).
final class PopoverRowView: PopoverRowBaseView {

    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        super.init(onSelect: onSelect)

        let label = NSTextField(labelWithString: title)
        label.font = PopoverListMetrics.rowTitleFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverListMetrics.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: PopoverListMetrics.rowHeight),
        ])

        if isSelected {
            let checkmark = Self.checkmarkImageView()
            addSubview(checkmark)
            NSLayoutConstraint.activate([
                checkmark.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset),
                checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -6),
            ])
        } else {
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset
            ).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    /// Trailing checkmark image view (SF Symbol "checkmark", pointSize 11
    /// weight .semibold, secondaryLabelColor — `PopoverList.swift:54-56`).
    static func checkmarkImageView() -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

/// Two-line model row: primary (CLI `value`, system 13 primary) + secondary
/// (`description`, system 11 secondary, single line tail-truncated). Trailing
/// checkmark when selected. Vertical padding 6 (`ModelEffortPicker.swift:258-293`).
final class ModelPopoverRowView: PopoverRowBaseView {

    init(title: String, subtitle: String?, isSelected: Bool, onSelect: @escaping () -> Void) {
        super.init(onSelect: onSelect)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = PopoverListMetrics.rowTitleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleLabel)

        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = PopoverListMetrics.rowSubtitleFont
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(subtitleLabel)
        }

        addSubview(stack)

        let checkmark: NSImageView? = isSelected ? PopoverRowView.checkmarkImageView() : nil
        if let checkmark { addSubview(checkmark) }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverListMetrics.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        if let checkmark {
            NSLayoutConstraint.activate([
                checkmark.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset),
                checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -6),
            ])
        } else {
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset
            ).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}
}

/// Fast-mode toggle row: "Enable fast mode" label (system 13 primary) +
/// trailing NSSwitch (controlSize .mini). Whole-row click flips the switch
/// (`ModelEffortPicker.swift:300-331`). Height 28.
final class FastModeToggleRowView: PopoverRowBaseView {

    private let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(enabled: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        // The base's onSelect flips the toggle (whole-row click).
        super.init(onSelect: {})
        // Re-route onSelect after super.init (base captured a no-op closure
        // above; we override the click behavior by handling it here).

        let label = NSTextField(labelWithString: String(localized: "Enable fast mode"))
        label.font = PopoverListMetrics.rowTitleFont
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        toggle.controlSize = .mini
        toggle.state = enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(switchToggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverListMetrics.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverListMetrics.horizontalInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: PopoverListMetrics.rowHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    /// Whole-row click flips the switch (matching the SwiftUI
    /// `onToggle(!enabled)` button action). Stateful press tracking (NOT a
    /// `nextEvent` pump) so the runloop keeps draining between drag events.
    private var rowPressInside = false

    override func mouseDown(with event: NSEvent) {
        rowPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        rowPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard rowPressInside else { return }
        rowPressInside = false
        toggle.state = toggle.state == .on ? .off : .on
        onToggle(toggle.state == .on)
    }

    @objc private func switchToggled() {
        onToggle(toggle.state == .on)
    }
}
