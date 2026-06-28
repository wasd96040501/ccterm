import AppKit

/// AppKit replacement for the rounded-pill chip that appears verbatim-identical
/// in `PermissionMcpCardBody.serverChip` (`PermissionMcpCardBody.swift:117-128`)
/// and `PermissionTaskAgentCardBody.chipView`
/// (`PermissionTaskAgentCardBody.swift:123-134`). A small display-only label on
/// a tinted rounded backplate.
///
/// 1:1 visual relocation, constants lifted verbatim:
/// - text font = `NSFont.systemFont(ofSize: 10, weight: .medium)`
/// - foreground = `secondaryLabelColor` (SwiftUI `.secondary`)
/// - padding = 6pt horizontal + 2pt vertical (per side)
/// - background = `RoundedRectangle(cornerRadius: 6, .continuous)` filled with
///   `Color.primary.opacity(0.06)` → `labelColor` at alpha 0.06
///
/// Scope: this is ONLY the rounded-pill (Mcp / TaskAgent) form. WebFetch's
/// domain chip and Skill's cwd chip are a SEPARATE icon+label form (SF Symbol +
/// size-11 label, no pill background) — those bodies render their icon+label
/// inline and do NOT use `PermissionBodyChip` (plan §4.4 / chip-shape-ambiguity
/// risk).
///
/// Display only — no interaction. Self-sizing leaf: `intrinsicContentSize` =
/// measured text size + padding.
final class PermissionBodyChip: NSView {

    // MARK: - Constants (verbatim from PermissionMcpCardBody.swift:117-128)

    /// Text font (`PermissionMcpCardBody.swift:120`).
    static let textFontSize: CGFloat = 10
    /// Horizontal padding per side (`PermissionMcpCardBody.swift:122`).
    static let horizontalPadding: CGFloat = 6
    /// Vertical padding per side (`PermissionMcpCardBody.swift:123`).
    static let verticalPadding: CGFloat = 2
    /// Background corner radius (`PermissionMcpCardBody.swift:125`).
    static let cornerRadius: CGFloat = 6
    /// Background fill alpha — `Color.primary.opacity(0.06)`
    /// (`PermissionMcpCardBody.swift:126`).
    static let backgroundAlpha: CGFloat = 0.06

    // MARK: - Subviews / layers

    private let backgroundLayer = CALayer()
    private let label = NSTextField(labelWithString: "")

    let text: String

    // MARK: - Init

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.cornerRadius = Self.cornerRadius
        layer?.addSublayer(backgroundLayer)

        label.stringValue = text
        label.font = .systemFont(ofSize: Self.textFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)

        applyContentsScale()
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    var resolvedBackgroundColor: CGColor? { backgroundLayer.backgroundColor }
    var resolvedCornerRadius: CGFloat { backgroundLayer.cornerRadius }
    var resolvedTextColor: NSColor? { label.textColor }

    // MARK: - Sizing (self-sizing leaf — text + padding)

    override var intrinsicContentSize: NSSize {
        let textSize = label.intrinsicContentSize
        return NSSize(
            width: textSize.width + 2 * Self.horizontalPadding,
            height: textSize.height + 2 * Self.verticalPadding)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
        let radius = min(Self.cornerRadius, min(bounds.width, bounds.height) / 2)
        backgroundLayer.cornerRadius = max(0, radius)
        backgroundLayer.cornerCurve = .continuous
    }

    // MARK: - Appearance / backing re-resolve (R14)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    private func applyContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        backgroundLayer.contentsScale = scale
    }

    /// `labelColor` at alpha 0.06 (= SwiftUI `Color.primary.opacity(0.06)`).
    /// `CALayer.cgColor` freezes on a dark/light flip — re-resolve, wrapped in a
    /// disabled `CATransaction` so it doesn't crossfade (R14, easy to miss on
    /// the smallest leaf).
    private func applyBackgroundColor() {
        var resolved: CGColor = NSColor.labelColor.withAlphaComponent(Self.backgroundAlpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.withAlphaComponent(Self.backgroundAlpha).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.backgroundColor = resolved
        CATransaction.commit()
    }
}
