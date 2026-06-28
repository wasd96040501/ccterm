import AgentSDK
import AppKit

/// AppKit body for `.enterPlanMode` permission requests — the real per-kind body
/// the parallel fan-out (plan §4.4) swaps in for the
/// `PermissionEnterPlanModeCardBodyBuilder` STUB the dispatch spine registered
/// (`PermissionCardBodyBuilding.swift`). 1:1 relocation of the SwiftUI
/// `PermissionEnterPlanModeCardBody` (`PermissionEnterPlanModeCardBody.swift`),
/// constants lifted verbatim.
///
/// **Shape.** A `NSStackView` column (spacing 10) of three sections, mirroring
/// the SwiftUI body (`PermissionEnterPlanModeCardBody.swift:32-60`):
/// 1. An intro row: a tinted `wand.and.stars` SF Symbol (size 12, baseline
///    aligned) + the size-12 primary intro sentence that fills the column width.
/// 2. A bullet block (inner spacing 4): the size-11 secondary header
///    (`"In plan mode, Claude will:"`) followed by the four ` · <bullet>`
///    size-11 secondary lines.
/// 3. The size-11 secondary closing reassurance.
///
/// **Static product copy, no agent data.** Unlike the diff / chip families,
/// `.enterPlanMode` has NO per-request fields — the bullets and the intro /
/// header / closing strings are product copy hard-coded on the SwiftUI body
/// (`PermissionEnterPlanModeCardBody.swift:25-77`). The data getters
/// (`intro` / `bulletHeader` / `closing` + the `static bullets`) are reused
/// VERBATIM by reading them off an instance of the SwiftUI struct, so the
/// localized strings stay single-sourced and `PermissionEnterPlanModeCardBodyTests`
/// already pins their exact phrasing — this file only owns the AppKit layout.
///
/// The CLI's dedicated plan-mode accent (`color="planMode"`) is not plumbed into
/// the card yet (same as the SwiftUI body); the icon uses `controlAccentColor`
/// (SwiftUI `.tint`). No FS read, no Task, no state — the body is a pure function
/// of the (otherwise-ignored) request.
@MainActor
final class PermissionEnterPlanModeCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionEnterPlanModeCardBody.swift)

    /// Outer VStack spacing (`PermissionEnterPlanModeCardBody.swift:33`).
    static let stackSpacing: CGFloat = 10
    /// Bullet-block inner VStack spacing (`PermissionEnterPlanModeCardBody.swift:43`).
    static let bulletBlockSpacing: CGFloat = 4
    /// Intro HStack icon↔text spacing (`PermissionEnterPlanModeCardBody.swift:34`).
    static let introRowSpacing: CGFloat = 6
    /// Intro icon + intro text font size (`PermissionEnterPlanModeCardBody.swift:36,39`).
    static let introFontSize: CGFloat = 12
    /// Bullet header + bullet line + closing font size
    /// (`PermissionEnterPlanModeCardBody.swift:45,49,55`).
    static let secondaryFontSize: CGFloat = 11

    // MARK: - Subviews

    private let stack = NSStackView()
    private let introIcon = NSImageView()
    private let introLabel = NSTextField(wrappingLabelWithString: "")
    private let bulletHeaderLabel = NSTextField(wrappingLabelWithString: "")
    private var bulletLabels: [NSTextField] = []
    private let closingLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - Init

    init(request: PermissionRequest) {
        // Reuse the SwiftUI body's data getters VERBATIM — the static `bullets`
        // and the `intro` / `bulletHeader` / `closing` localized strings (already
        // pinned by `PermissionEnterPlanModeCardBodyTests`). `.enterPlanMode`
        // carries no per-request data, so the request only identifies the kind.
        let data = PermissionEnterPlanModeCardBody(request: request)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildArrangedSubviews(data: data)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(data.intro)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — the card column drives the width; content the height)

    /// Publish `noIntrinsicMetric` width so the body never leaks a min-width up to
    /// the full-pane card host (plan R1). The card controller caps the card at
    /// `BlockStyle.maxLayoutWidth`; height flows from the stacked content.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(data: PermissionEnterPlanModeCardBody) {
        // 1. Intro row — tinted wand icon + size-12 primary intro sentence
        //    (`PermissionEnterPlanModeCardBody.swift:34-42`).
        let introRow = makeIntroRow(intro: data.intro)
        stack.addArrangedSubview(introRow)
        introRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        introRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // 2. Bullet block — size-11 secondary header + four ` · <bullet>` lines,
        //    inner spacing 4 (`PermissionEnterPlanModeCardBody.swift:43-53`).
        let bulletBlock = makeBulletBlock(
            header: data.bulletHeader, bullets: PermissionEnterPlanModeCardBody.bullets)
        stack.addArrangedSubview(bulletBlock)
        bulletBlock.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        bulletBlock.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // 3. Closing reassurance — size-11 secondary, leading-aligned full width
        //    (`PermissionEnterPlanModeCardBody.swift:54-57`).
        configureSecondaryLabel(closingLabel, text: data.closing)
        stack.addArrangedSubview(closingLabel)
        closingLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        closingLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    /// The intro row (`PermissionEnterPlanModeCardBody.swift:34-42`): a
    /// `HStack(alignment: .firstTextBaseline, spacing: 6)` of the tinted
    /// `wand.and.stars` icon (size 12, `.tint` = `controlAccentColor`) and the
    /// size-12 primary intro sentence that stretches to fill the column and wraps.
    private func makeIntroRow(intro: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        // SwiftUI `HStack(alignment: .firstTextBaseline, …)` → align on the first
        // text baseline so the icon sits on the intro sentence's baseline.
        row.alignment = .firstBaseline
        row.spacing = Self.introRowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        introIcon.image = NSImage(
            systemSymbolName: "wand.and.stars", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.introFontSize, weight: .regular))
        // SwiftUI `.foregroundStyle(.tint)` → the control accent color.
        introIcon.contentTintColor = .controlAccentColor
        introIcon.translatesAutoresizingMaskIntoConstraints = false
        introIcon.setContentHuggingPriority(.required, for: .horizontal)
        introIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        introLabel.stringValue = intro
        introLabel.font = .systemFont(ofSize: Self.introFontSize)
        introLabel.textColor = .labelColor  // SwiftUI `.foregroundStyle(.primary)`
        introLabel.alignment = .left
        introLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the leading-aligned label stretches across the column
        // (SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`) and wraps.
        introLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        introLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(introIcon)
        row.addArrangedSubview(introLabel)
        // Stretch the intro text across the rest of the row so it wraps within the
        // card column rather than growing to one clipped line.
        introLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        return row
    }

    /// The bullet block (`PermissionEnterPlanModeCardBody.swift:43-53`): a
    /// `VStack(alignment: .leading, spacing: 4)` of the size-11 secondary header
    /// and four size-11 secondary ` · <bullet>` lines.
    private func makeBulletBlock(header: String, bullets: [String]) -> NSStackView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = Self.bulletBlockSpacing
        block.translatesAutoresizingMaskIntoConstraints = false

        // Header — size-11 secondary. SwiftUI `Text` has no `.lineLimit`, so it
        // wraps freely; build it as a wrapping label pinned across the block.
        bulletHeaderLabel.stringValue = header
        bulletHeaderLabel.font = .systemFont(ofSize: Self.secondaryFontSize)
        bulletHeaderLabel.textColor = .secondaryLabelColor
        bulletHeaderLabel.alignment = .left
        bulletHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        bulletHeaderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bulletHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        block.addArrangedSubview(bulletHeaderLabel)
        bulletHeaderLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor).isActive = true
        bulletHeaderLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor).isActive = true

        // Bullets — ` · <bullet>` size-11 secondary, leading-aligned, full width
        // so a long bullet wraps within the card column.
        for bullet in bullets {
            let label = NSTextField(wrappingLabelWithString: " · \(bullet)")
            label.font = .systemFont(ofSize: Self.secondaryFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            bulletLabels.append(label)
            block.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: block.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: block.trailingAnchor).isActive = true
        }
        return block
    }

    /// A dim size-11 secondary wrapping label, leading-aligned, that stretches to
    /// the column width (SwiftUI `.font(.system(size: 11))`,
    /// `.foregroundStyle(.secondary)`, `.frame(maxWidth: .infinity, alignment: .leading)`).
    private func configureSecondaryLabel(_ label: NSTextField, text: String) {
        label.stringValue = text
        label.font = .systemFont(ofSize: Self.secondaryFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The intro sentence actually rendered.
    var renderedIntro: String { introLabel.stringValue }
    /// The bullet-block header actually rendered.
    var renderedBulletHeader: String { bulletHeaderLabel.stringValue }
    /// The bullet lines actually rendered, in order, with the ` · ` prefix
    /// stripped so a test can compare against the raw bullet copy.
    var renderedBullets: [String] {
        bulletLabels.map { label in
            let value = label.stringValue
            let prefix = " · "
            return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        }
    }
    /// The bullet lines as actually rendered, WITH the ` · ` prefix intact — so a
    /// test can assert the prefix is present (the stripped `renderedBullets` can't).
    var renderedBulletsRaw: [String] { bulletLabels.map(\.stringValue) }
    /// The closing reassurance actually rendered.
    var renderedClosing: String { closingLabel.stringValue }
    /// The intro icon's tint color (parity with SwiftUI `.foregroundStyle(.tint)`).
    var introIconTint: NSColor? { introIcon.contentTintColor }
    /// The intro label's text color (parity with SwiftUI `.primary`).
    var renderedIntroColor: NSColor? { introLabel.textColor }
    /// The closing label's text color (parity with SwiftUI `.secondary`).
    var renderedClosingColor: NSColor? { closingLabel.textColor }
}

// MARK: - Body builder

/// The `PermissionCardBodyBuilding` conformer for `.enterPlanMode`. Named
/// distinctly from the dispatch stub `PermissionEnterPlanModeCardBodyBuilder` (in
/// `PermissionCardBodyBuilding.swift`) so this file adds the real port WITHOUT
/// editing the dispatch switch — the integration step repoints `.enterPlanMode`
/// to this builder. The body ignores `engine` (no diff family).
@MainActor
struct PermissionEnterPlanModeCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionEnterPlanModeCardBodyView(request: request)
    }
}
