import AgentSDK
import AppKit

/// AppKit body for `.exitPlanMode` permission requests
/// (`ExitPlanMode` / `ExitPlanModeV2`) — the 1:1 relocation of the SwiftUI
/// `PermissionExitPlanModeCardBody`
/// (`InputBarControls/PermissionExitPlanModeCardBody.swift:25-82`). Built for the
/// pure-AppKit permission card (migration plan §4.4): an `NSStackView` column of
/// an `NSTextField` headline + the shared `PermissionMonospaceScrollBlock` helper.
///
/// **v1 in ccterm** (mirroring the SwiftUI body's doc): render the plan as plain
/// monospaced text in a 480pt-cap scroll so a long plan stays inspectable without
/// pushing the decision buttons off-screen. **V2 fallback:** `ExitPlanModeV2`
/// writes the plan to a file the CLI reads back — we can't reach it via
/// `rawInput`, so the body shows a short hint instead of an empty scroll.
///
/// Two-branch body (verbatim from `PermissionExitPlanModeCardBody.body`, `:28-51`):
/// - headline: size-12 medium, primary (labelColor), full-width leading.
/// - if `plan` non-empty → a 480pt-cap monospace scroll (`PermissionMonospaceScrollBlock`,
///   which reproduces the verbatim `ScrollView(.vertical, showsIndicators: true) {
///   Text(...size12 monospaced .primary .textSelection(.enabled)) }.frame(maxHeight: 480)`).
/// - else → the empty-plan hint as size-11 secondary text, full-width leading.
///
/// **Data getters reused VERBATIM.** All field extraction (`isV2` / `plan` /
/// `headline` / `emptyPlanHint`, including the three localized strings) lives on
/// the still-extant SwiftUI `PermissionExitPlanModeCardBody` struct and is read
/// straight off an instance of it. That keeps the parsing + the v1/V2 branch
/// single-sourced and means the existing `PermissionExitPlanModeCardBodyTests`
/// already pins the data layer — this file only owns the AppKit layout. (Same
/// posture as `PermissionTaskAgentCardBodyView`.)
@MainActor
final class PermissionExitPlanModeCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionExitPlanModeCardBody.swift:28-48)

    /// Outer VStack spacing (`PermissionExitPlanModeCardBody.swift:29`).
    static let stackSpacing: CGFloat = 8
    /// Headline font size (`PermissionExitPlanModeCardBody.swift:31` —
    /// `.system(size: 12, weight: .medium)`).
    static let headlineFontSize: CGFloat = 12
    /// Empty-plan hint font size (`PermissionExitPlanModeCardBody.swift:45` —
    /// `.system(size: 11)`).
    static let emptyHintFontSize: CGFloat = 11
    /// Plan monospace scroll height cap (`PermissionExitPlanModeCardBody.swift:42`
    /// — `.frame(maxHeight: 480)`).
    static let planScrollMaxHeight: CGFloat = 480

    // MARK: - Subviews

    private let stack = NSStackView()
    private let headlineLabel = NSTextField(labelWithString: "")
    /// Present only when `plan` is non-nil/non-empty (the v1-with-plan branch).
    private var planBlock: PermissionMonospaceScrollBlock?
    /// Present only when `plan` is nil/empty (the V2 / empty-plan branch).
    private var emptyHintLabel: NSTextField?

    // MARK: - Init

    init(request: PermissionRequest) {
        // Reuse the SwiftUI body's data getters VERBATIM — same parsing, same
        // v1/V2 branch, same localized strings (already pinned by
        // `PermissionExitPlanModeCardBodyTests`).
        let data = PermissionExitPlanModeCardBody(request: request)
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
        setAccessibilityLabel(data.headline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — the card column drives the width; content the height)

    /// Publish `noIntrinsicMetric` width so the body never leaks a min-width up
    /// to the full-pane card host (plan R1). The card controller caps the card
    /// at `BlockStyle.maxLayoutWidth`; height flows from the stacked content (the
    /// scroll block clamps its own height to `min(used, 480)`).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(data: PermissionExitPlanModeCardBody) {
        // Headline — size-12 medium, primary, full-width leading
        // (`PermissionExitPlanModeCardBody.swift:30-33`).
        headlineLabel.stringValue = data.headline
        headlineLabel.font = .systemFont(ofSize: Self.headlineFontSize, weight: .medium)
        headlineLabel.textColor = .labelColor
        // SwiftUI `Text` with no `.lineLimit` wraps freely; the headline is a
        // short fixed sentence, but match the wrapping behavior (no truncation).
        headlineLabel.maximumNumberOfLines = 0
        headlineLabel.lineBreakMode = .byWordWrapping
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the leading-aligned label stretches to fill the card column
        // (SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`).
        headlineLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headlineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(headlineLabel)
        headlineLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        headlineLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        if let plan = data.plan, !plan.isEmpty {
            // v1-with-plan — 480pt-cap monospace scroll
            // (`PermissionExitPlanModeCardBody.swift:34-42`). The shared block
            // reproduces the size-12 monospaced, primary, selectable text in a
            // `showsIndicators: true` vertical scroll capped at 480.
            let block = PermissionMonospaceScrollBlock(
                text: plan, maxHeight: Self.planScrollMaxHeight)
            planBlock = block
            stack.addArrangedSubview(block)
            block.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            block.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        } else {
            // V2 / empty-plan — size-11 secondary hint, full-width leading
            // (`PermissionExitPlanModeCardBody.swift:43-48`).
            let label = NSTextField(wrappingLabelWithString: data.emptyPlanHint)
            label.font = .systemFont(ofSize: Self.emptyHintFontSize)
            label.textColor = .secondaryLabelColor
            // SwiftUI `Text` with no `.lineLimit` wraps freely (no truncation).
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            emptyHintLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The headline text actually rendered.
    var renderedHeadline: String { headlineLabel.stringValue }
    /// Whether the v1-with-plan monospace scroll block was mounted.
    var hasPlanBlock: Bool { planBlock != nil }
    /// The plan scroll block's resolved (clamped) height, or `nil` when absent —
    /// the `min(usedTextHeight, 480)` value the cap is applied to.
    var planResolvedHeight: CGFloat? { planBlock?.resolvedHeight }
    /// The plan scroll block's height cap (parity with SwiftUI `.frame(maxHeight: 480)`).
    var planScrollMaxHeight: CGFloat? { planBlock?.maxHeight }
    /// The empty-plan hint text rendered, or `nil` when the plan branch was taken.
    var renderedEmptyHint: String? { emptyHintLabel?.stringValue }
    /// The stack's currently-arranged subviews, in order — for a measurement test
    /// asserting the two-branch row composition (headline + one of plan/hint).
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }
}

// MARK: - Body builder

/// The `PermissionCardBodyBuilding` conformer for `.exitPlanMode`. Named
/// distinctly from the dispatch stub `PermissionExitPlanModeCardBodyBuilder` (in
/// `PermissionCardBodyBuilding.swift`) so this file adds the real port WITHOUT
/// editing the dispatch switch — the integration step repoints `.exitPlanMode`
/// to this builder. The body ignores `engine` (no diff family). Mirrors the
/// `PermissionTaskAgentCardBodyBuilder` naming precedent.
@MainActor
struct PermissionExitPlanModeCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionExitPlanModeCardBodyView(request: request)
    }
}
