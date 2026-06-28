import AppKit

/// AppKit replacement for `InputBarView2`'s `circleButton` send/stop control
/// (migration plan §4.1-9). A 24pt circle (`sendButtonSize = 24`) filled with
/// the state color, centered white SF Symbol glyph (`iconPointSize = 13`,
/// `.bold`).
///
/// Two states:
/// - **not running** → send: `controlAccentColor` fill, `arrow.up` glyph,
///   action = `handleSend`, gated by `canSend` (disabled → `alphaValue 0.4`
///   + non-clickable, matching `.opacity(0.4)` + `.disabled`).
/// - **running** → stop: `systemGray` fill, `stop.fill` glyph, action =
///   `interrupt`, always clickable.
///
/// The send→stop swap and the disabled fade are imperative (`setRunning(_:)`
/// / `updateEnabled()`), driven by the controller's `withObservationTracking`
/// over `session.isRunning` and the `canSend` gate. The `.smooth(0.35)`
/// value-change animation (`animationDuration`) runs inside an
/// `NSAnimationContext.runAnimationGroup` (D5: opacity-only, no scale).
final class SendStopButton: NSControl {

    /// Circle diameter (`InputBarView2.sendButtonSize = 24`).
    static let size: CGFloat = 24
    /// Glyph point size (`InputBarView2.iconPointSize = 13`, `.bold`).
    private static let iconPointSize: CGFloat = 13
    /// `.smooth(duration: 0.35)` value-change animation
    /// (`InputBarView2.animationDuration`).
    private static let animationDuration: TimeInterval = 0.35

    /// Fired when the send button (not running) is clicked and `canSend`.
    var onSend: (() -> Void)?
    /// Fired when the stop button (running) is clicked.
    var onStop: (() -> Void)?

    private(set) var isRunning: Bool = false
    /// Whether send is permitted (text/attachment present AND `submitEnabled`).
    /// Only meaningful in the send state; the stop state is always clickable.
    private(set) var canSend: Bool = false

    private let circleLayer = CALayer()
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        circleLayer.masksToBounds = true
        layer?.addSublayer(circleLayer)

        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])

        setAccessibilityRole(.button)
        applyState(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }

    // MARK: - State

    /// Flip the send↔stop appearance. Imperative — mirrors `setLoading`.
    func setRunning(_ running: Bool, animated: Bool = true) {
        guard running != isRunning else { return }
        isRunning = running
        applyState(animated: animated)
    }

    /// Update the send-gate. No-op visual change while running (stop is
    /// always enabled). Cheap to call on every text/attachment/cwd change —
    /// only animates the disabled fade (`alphaValue`), never rebuilds the
    /// glyph (matching the SwiftUI `.opacity(canSend ? 1 : 0.4)` enable path).
    func updateEnabled(_ enabled: Bool) {
        guard enabled != canSend else { return }
        canSend = enabled
        if !isRunning {
            alphaValue = canSend ? 1.0 : 0.4
        }
    }

    private func applyState(animated: Bool) {
        let symbol: String
        let targetAlpha: CGFloat
        if isRunning {
            symbol = "stop.fill"
            targetAlpha = 1.0
        } else {
            symbol = "arrow.up"
            targetAlpha = canSend ? 1.0 : 0.4
        }

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .bold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = .white

        setAccessibilityLabel(
            isRunning
                ? String(localized: "Stop") : String(localized: "Send a message"))

        let applyColors = {
            // `.controlAccentColor` / `.systemGray` are dynamic system colors;
            // resolve them against THIS view's effective appearance, not the
            // ambient `NSAppearance.current` (which may differ before the view
            // is windowed). Mirrors the drop-stroke helpers.
            self.circleLayer.backgroundColor = self.resolvedFill.cgColor
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animationDuration
                ctx.allowsImplicitAnimation = true
                applyColors()
                self.animator().alphaValue = targetAlpha
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyColors()
            CATransaction.commit()
            alphaValue = targetAlpha
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        circleLayer.frame = bounds
        circleLayer.cornerRadius = min(bounds.width, bounds.height) / 2
        // cgColor freezes on appearance flip — re-resolve.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circleLayer.backgroundColor = resolvedFill.cgColor
        CATransaction.commit()
    }

    /// The state fill resolved against this view's effective appearance.
    private var resolvedFill: NSColor {
        let base: NSColor = isRunning ? .systemGray : .controlAccentColor
        var resolved = base
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: base.cgColor) ?? base
        }
        return resolved
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circleLayer.backgroundColor = resolvedFill.cgColor
        CATransaction.commit()
    }

    // MARK: - Click (non-blocking press tracking)

    /// Whether the current drag is over the button bounds — set in
    /// `mouseDown`/`mouseDragged`, read in `mouseUp`. Tracking across
    /// separate event deliveries (NOT a synchronous `nextEvent(matching:)`
    /// pump) keeps the main runloop draining dispatch / Observation / CA
    /// work between drag events — the bar shares the runloop with the
    /// transcript-swap `CATransaction` and the `isRunning` sink.
    private var isPressInside = false

    override func mouseDown(with event: NSEvent) {
        // Send state but disabled → no-op (matches `.disabled(!canSend)`).
        if !isRunning && !canSend { return }
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        if !isRunning && !canSend { return }
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressInside else { return }
        isPressInside = false
        if isRunning {
            onStop?()
        } else if canSend {
            onSend?()
        }
    }
}
