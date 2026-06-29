import AgentSDK
import AppKit

/// AppKit replacement for the SwiftUI `PermissionCardView`
/// (`PermissionCardView.swift:35-149`) — the floating decision card's chrome:
/// header → per-kind body → optional decision-reason → Deny/Allow button row,
/// laid out in a vertical `NSStackView` and backed by the OPAQUE
/// `PermissionCardSurfaceView` (NOT the glass `BarSurfaceView` — §4.4-1
/// BLOCKER: the bar's material bled through and made diffs unreadable).
///
/// Named `PermissionCardContentView` (not `PermissionCardView`) — the original
/// SwiftUI `struct PermissionCardView: View` (which hosted the 11 per-kind
/// bodies + the `PermissionCardsDemoView`) was deleted in the D8 sweep; the
/// name is kept distinct because this AppKit type renders only the card chrome,
/// not the demo host. Same precedent as `PermissionDecisionButton`, which took
/// over its bare name once the SwiftUI button was deleted.
///
/// This is a 1:1 visual relocation, constants lifted verbatim:
/// - outer VStack(alignment:.leading, spacing:12) (`PermissionCardView.swift:59`)
/// - card padding .horizontal 14 / .vertical 12 (`PermissionCardView.swift:77-78`)
/// - maxWidth `BlockStyle.maxLayoutWidth` (780) leading-aligned (`:79`)
/// - cornerRadius 16 (`.continuous`) via the surface (`:49`)
/// - header HStack(.firstTextBaseline, spacing:8): `hand.raised.fill` size12
///   weight.semibold tint + title size13 weight.semibold primary + trailing
///   spacer (`:85-93`)
/// - reason Label (only when `decisionReason?.reason` non-empty): `info.circle`
///   size11 secondary + text size11 secondary (`:62-73`)
/// - button row HStack(spacing:8): [Deny .destructive] spacer [Allow once
///   .secondary] [Allow always .primary] (`:132-147`)
///
/// `bodyOwnsChrome` (`PermissionCardView.swift:56`) = `kind == .askUserQuestion`
/// is the §4.5 delegation point — header / reason / button row are NOT rendered
/// for AskUserQuestion (the wizard owns its full chrome). The body section is
/// always present (for AskUserQuestion it will be the wizard view, supplied by
/// the body builder / §4.5 once ported).
///
/// Pure UI: receives a `PermissionRequest` + the four decision callbacks +
/// the body builder, and the syntax engine for diff-family bodies. Wiring to
/// `session.respond(...)` lives in `permissionDecisionHandlers(for:session:)`,
/// called by `PermissionCardController`.
@MainActor
final class PermissionCardContentView: NSView {

    // MARK: - Constants (verbatim from PermissionCardView.swift)

    /// Outer stack spacing (`PermissionCardView.swift:59`).
    static let stackSpacing: CGFloat = 12
    /// Card horizontal padding (`PermissionCardView.swift:77`).
    static let horizontalPadding: CGFloat = 14
    /// Card vertical padding (`PermissionCardView.swift:78`).
    static let verticalPadding: CGFloat = 12
    /// Header / button-row HStack spacing (`PermissionCardView.swift:85,133`).
    static let rowSpacing: CGFloat = 8
    /// Reason `Label` icon↔text gap. The SwiftUI reason is a `Label { } icon { }`
    /// (`PermissionCardView.swift:65-73`), whose icon-to-title gap is the system
    /// Label spacing (~6), NOT the header's explicit `HStack(spacing: 8)`. Use a
    /// dedicated constant so the reason row isn't over-spaced.
    static let reasonRowSpacing: CGFloat = 6
    /// Header icon size (`PermissionCardView.swift:87`).
    static let headerIconSize: CGFloat = 12
    /// Header title size (`PermissionCardView.swift:90`).
    static let titleSize: CGFloat = 13
    /// Reason icon + text size (`PermissionCardView.swift:67,71`).
    static let reasonSize: CGFloat = 11
    /// Card max width (the transcript column width, `PermissionCardView.swift:79`).
    static let maxWidth: CGFloat = BlockStyle.maxLayoutWidth

    // MARK: - Inputs

    let request: PermissionRequest
    private let kind: PermissionCardKind
    /// §4.5 delegation: AskUserQuestion owns its full chrome.
    var bodyOwnsChrome: Bool { kind == .askUserQuestion }

    // MARK: - Subviews

    private let surface = PermissionCardSurfaceView()
    private let stack = NSStackView()
    /// The per-kind body view, retained so the highlight Task it may own stays
    /// alive for the card's lifetime.
    private let bodyView: NSView
    /// The AskUserQuestion wizard VC, retained for the card's lifetime when
    /// `bodyOwnsChrome` (its `view` is the `bodyView`). nil for every other kind.
    /// The card controller drives its focus + teardown (§4.5-1, §4.5-5).
    private(set) var askUserQuestionController: AskUserQuestionCardViewController?

    // MARK: - Init

    /// - Parameters:
    ///   - request: the pending permission's request.
    ///   - engine: the shared syntax engine for diff-family bodies (passed to
    ///     the body builder; nil-safe).
    ///   - onAllowOnce/onAllowAlways/onDeny: the three generic button actions.
    ///   - onAllowWithInput: the AskUserQuestion-only edited-input path (unused
    ///     by the generic chrome; threaded for parity with the SwiftUI card).
    ///   - bodyBuilder: dispatch override (defaults to
    ///     `permissionCardBodyBuilder(for:)`) so tests can inject a stub builder.
    init(
        request: PermissionRequest,
        engine: SyntaxHighlightEngine?,
        onAllowOnce: @escaping () -> Void,
        onAllowAlways: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onAllowWithInput: @escaping ([String: Any]?) -> Void = { _ in },
        bodyBuilder: ((PermissionCardKind) -> PermissionCardBodyBuilding)? = nil
    ) {
        self.request = request
        let resolvedKind = PermissionCardKind.kind(for: request)
        self.kind = resolvedKind
        if resolvedKind == .askUserQuestion {
            // §4.5 delegation: AskUserQuestion owns its full chrome. Build the
            // wizard VC (onSubmit ← onAllowWithInput, onCancel ← onDeny) and use
            // its `view` as the body section — `bodyOwnsChrome` suppresses the
            // generic header / reason / button row.
            let wizard = AskUserQuestionCardViewController(
                request: request, onSubmit: onAllowWithInput, onCancel: onDeny)
            self.askUserQuestionController = wizard
            self.bodyView = wizard.view
        } else {
            self.askUserQuestionController = nil
            let builder = (bodyBuilder ?? permissionCardBodyBuilder(for:))(resolvedKind)
            self.bodyView = builder.makeBody(request: request, engine: engine)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The opaque surface, pinned to the card's four edges (regime-B
        // background — the content drives the size).
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The content stack, inset by the card padding.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])

        buildArrangedSubviews(
            onAllowOnce: onAllowOnce, onAllowAlways: onAllowAlways, onDeny: onDeny)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(PermissionCardCopy.title(for: request))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)
    //
    // The arranged subviews so a measurement test can assert the
    // `bodyOwnsChrome` gating (AskUserQuestion renders NO header/reason/button
    // row; a generic kind renders header + body + button row) against the real
    // production object.

    /// The card's currently-arranged top-level subviews (header / body /
    /// reason / button row), in order. Read-only.
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }
    /// The header HStack, present only when `!bodyOwnsChrome`.
    private(set) var headerRow: NSView?
    /// The reason Label HStack, present only when `!bodyOwnsChrome` AND a
    /// non-empty `decisionReason.reason`.
    private(set) var reasonRow: NSView?
    /// The Deny/Allow button row, present only when `!bodyOwnsChrome`.
    private(set) var buttonRow: NSView?
    /// The three decision buttons (Deny / Allow once / Allow always), in row
    /// order, when the button row is present.
    private(set) var decisionButtons: [PermissionDecisionButton] = []
    /// The per-kind body view (always present).
    var resolvedBodyView: NSView { bodyView }

    // MARK: - Sizing (regime-B — content drives size)

    /// Width is capped to the transcript column by the card controller's outer
    /// constraint; height flows from the content. Publish `noIntrinsicMetric`
    /// width so the card never leaks a min-width up to the full-pane host (R1)
    /// — the controller pins `width <= maxWidth @required` instead.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(
        onAllowOnce: @escaping () -> Void,
        onAllowAlways: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        // header (only when !bodyOwnsChrome)
        if !bodyOwnsChrome {
            let header = makeHeader()
            headerRow = header
            stack.addArrangedSubview(header)
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // body (always)
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bodyView)
        bodyView.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        bodyView.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // reason (only when !bodyOwnsChrome && non-empty)
        if !bodyOwnsChrome, let reason = request.decisionReason?.reason, !reason.isEmpty {
            let row = makeReasonRow(reason)
            reasonRow = row
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            // `==` (matching header / button row) so the row spans the card
            // column and the wrapping label has a bounded width to wrap inside —
            // `<=` lets a single-line intrinsic width grow the row to the card
            // edge and never wrap (the SwiftUI `Label { Text(reason) }` wraps
            // inside the 780-wide leading-aligned VStack, `PermissionCardView.swift:62-74`).
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // button row (only when !bodyOwnsChrome)
        if !bodyOwnsChrome {
            let row = makeButtonRow(
                onAllowOnce: onAllowOnce, onAllowAlways: onAllowAlways, onDeny: onDeny)
            buttonRow = row
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func makeHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Self.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: Self.headerIconSize, weight: .semibold))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: PermissionCardCopy.title(for: request))
        title.font = .systemFont(ofSize: Self.titleSize, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(title)
        row.addArrangedSubview(spacer)
        return row
    }

    private func makeReasonRow(_ reason: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Self.reasonRowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.reasonSize, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSTextField(wrappingLabelWithString: reason)
        text.font = .systemFont(ofSize: Self.reasonSize)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the stack stretches the wrapping label to fill the row's
        // remaining width (the row is `==`-pinned to the card column), giving the
        // label a bounded width to wrap inside rather than a single growing line.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        // Stretch the text field across the rest of the row so a multi-line
        // reason wraps within the card column (`PermissionCardView.swift:62-74`).
        text.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        return row
    }

    private func makeButtonRow(
        onAllowOnce: @escaping () -> Void,
        onAllowAlways: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let deny = PermissionDecisionButton(
            title: String(localized: "Deny"), role: .destructive, onClick: onDeny)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let allowOnce = PermissionDecisionButton(
            title: String(localized: "Allow once"), role: .secondary, onClick: onAllowOnce)
        let allowAlways = PermissionDecisionButton(
            title: String(localized: "Allow always"), role: .primary, onClick: onAllowAlways)

        decisionButtons = [deny, allowOnce, allowAlways]
        deny.setContentHuggingPriority(.required, for: .horizontal)
        allowOnce.setContentHuggingPriority(.required, for: .horizontal)
        allowAlways.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(deny)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(allowOnce)
        row.addArrangedSubview(allowAlways)
        return row
    }
}
