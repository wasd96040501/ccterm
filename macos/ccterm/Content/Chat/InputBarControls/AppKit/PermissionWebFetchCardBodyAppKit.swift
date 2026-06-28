import AgentSDK
import AppKit
import Foundation

/// AppKit body for `.webFetch` permission requests — the 1:1 port of the SwiftUI
/// `PermissionWebFetchCardBody` (`Content/Chat/InputBarControls/PermissionWebFetchCardBody.swift`),
/// built as a `PermissionCardBodyBuilding` conformer so the dispatch
/// (`permissionCardBodyBuilder(for:)`) returns it for `.webFetch`.
///
/// Mirrors `WebFetchPermissionRequest` upstream: a prominent monospaced URL, a
/// domain chip so the user can pattern-match "this is the domain Allow always
/// would whitelist", and the agent's `prompt` rendered as secondary text below.
/// The CLI's "Yes, and don't ask again for <hostname>" branch maps to our
/// shared "Allow always" button (which forwards the request's
/// `permissionSuggestions` — typically `domain:<host>`). No per-domain branching
/// at the button level — the rule the request would install is opaque, just
/// like every other kind.
///
/// **Domain chip is the icon+label form, NOT `PermissionBodyChip`.** WebFetch's
/// chip is the SF Symbol + size-11 label form with no pill backplate —
/// explicitly carved out from the rounded-pill `PermissionBodyChip` (Mcp /
/// TaskAgent) by that helper's docstring ("WebFetch's domain chip and Skill's
/// cwd chip are a SEPARATE icon+label form … those bodies render their
/// icon+label inline and do NOT use `PermissionBodyChip`"). It is rendered
/// inline here, exactly as the SwiftUI `HStack { Image("network"); Text(host) }`
/// did (`PermissionWebFetchCardBody.swift:27-36`).
///
/// **Verbatim constants (from the SwiftUI body, `:19-43`):**
/// - layout: `VStack(alignment: .leading, spacing: 8)` → vertical `NSStackView`
///   `spacing 8`, `.leading`.
/// - URL: `.system(size: 12, design: .monospaced)` `.primary` (labelColor),
///   lineLimit 2, truncation `.middle`, selectable, full-width leading; the
///   placeholder `"—"` shows when `url` is nil.
/// - domain chip: `HStack(spacing: 4)` of the `network` SF Symbol (size-11
///   `.secondary`) + host label (size-11 weight `.medium` `.secondary`).
/// - prompt: size-11 `.secondary`, up to 3 lines, full-width leading.
///
/// **Per-kind data getters reused VERBATIM** from the SwiftUI body
/// (`url` / `hostname` / `prompt`, `:50-66`) — copied byte-for-byte as free
/// helpers on `PermissionRequest` (prefixed `webFetch`) so the parsing behaviour
/// is identical and the AppKit body, the SwiftUI body, and both test classes
/// share one source of truth.
///
/// No user-visible strings to localise: URL / hostname / prompt are request
/// data, `"network"` is an SF Symbol name, and `"—"` is a glyph placeholder —
/// matching the SwiftUI source, which has none either.
struct PermissionWebFetchCardBodyBuilder: PermissionCardBodyBuilding {

    // MARK: - Constants (verbatim from PermissionWebFetchCardBody.swift:19-43)

    /// Outer VStack spacing (`PermissionWebFetchCardBody.swift:19`).
    static let stackSpacing: CGFloat = 8
    /// URL monospaced font size (`:21`).
    static let urlFontSize: CGFloat = 12
    /// URL line cap (`:24`).
    static let urlLineLimit: Int = 2
    /// Domain-chip icon↔label gap (`:28`).
    static let chipSpacing: CGFloat = 4
    /// Domain-chip icon + label font size (`:30,33`).
    static let chipFontSize: CGFloat = 11
    /// Prompt font size (`:39`).
    static let promptFontSize: CGFloat = 11
    /// Prompt line cap (`:41`).
    static let promptLineLimit: Int = 3
    /// Placeholder shown when `url` is nil (`:20`).
    static let missingURLPlaceholder = "—"

    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // `engine` is unused — WebFetch has no diff/highlight surface (the
        // protocol threads it for the diff-family bodies). Intentionally ignored.
        PermissionWebFetchCardBodyView(request: request)
    }
}

/// The WebFetch body's view. A vertical stack of: a prominent monospaced URL,
/// an optional inline domain chip (icon + host), and an optional dimmed prompt.
@MainActor
final class PermissionWebFetchCardBodyView: NSView {

    // MARK: - Inputs

    let request: PermissionRequest

    // MARK: - Subviews

    private let stack = NSStackView()
    private let urlLabel = NSTextField(labelWithString: "")

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The URL string actually shown (the placeholder `"—"` when `url == nil`).
    var renderedURLText: String { urlLabel.stringValue }
    /// The domain-chip host label, present only when `webFetchHostname != nil`.
    private(set) var domainChipLabel: NSTextField?
    /// The dimmed prompt label, present only when `webFetchPrompt` is non-empty.
    private(set) var promptLabel: NSTextField?
    /// The stack's currently-arranged subviews, in order — for a measurement
    /// test asserting the row composition.
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }

    // MARK: - Init

    init(request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PermissionWebFetchCardBodyBuilder.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buildArrangedSubviews()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(request.webFetchURL ?? request.webFetchHostname ?? "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — content drives size; never leak a min up)

    /// The card content (the outer `PermissionCardContentView` stack) drives the
    /// width; this body publishes no intrinsic metric so it can't leak a
    /// min-width up into the full-pane permission-card host (plan R1). Height
    /// flows from the arranged subviews via the stack's constraints.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews() {
        // URL — prominent monospaced line, 2-line cap, middle-truncated,
        // selectable, full-width leading (`PermissionWebFetchCardBody.swift:20-26`).
        urlLabel.stringValue =
            request.webFetchURL ?? PermissionWebFetchCardBodyBuilder.missingURLPlaceholder
        urlLabel.font = .monospacedSystemFont(
            ofSize: PermissionWebFetchCardBodyBuilder.urlFontSize, weight: .regular)
        urlLabel.textColor = .labelColor
        urlLabel.maximumNumberOfLines = PermissionWebFetchCardBodyBuilder.urlLineLimit
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.isSelectable = true
        urlLabel.allowsEditingTextAttributes = false
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the stack stretches it to the card column, giving the
        // two-line middle-truncation a bounded width (mirrors the SwiftUI
        // `.frame(maxWidth: .infinity, alignment: .leading)`).
        urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(urlLabel)
        urlLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        urlLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Domain chip (icon + label) — only when the URL parses to a host
        // (`PermissionWebFetchCardBody.swift:27-36`).
        if let host = request.webFetchHostname {
            stack.addArrangedSubview(makeDomainChip(host: host))
        }

        // Prompt — dimmed secondary text, 3-line cap, wrapping, full-width
        // leading (`PermissionWebFetchCardBody.swift:37-43`).
        if let prompt = request.webFetchPrompt, !prompt.isEmpty {
            let label = makePromptLabel(prompt)
            promptLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    /// `HStack(spacing: 4) { Image("network") size11 .secondary; Text(host)
    /// size11 weight.medium .secondary }` (`PermissionWebFetchCardBody.swift:27-36`).
    private func makeDomainChip(host: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        // SwiftUI `HStack(spacing: 4)` with no explicit alignment → `.center`.
        row.alignment = .centerY
        row.spacing = PermissionWebFetchCardBodyBuilder.chipSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(
                    pointSize: PermissionWebFetchCardBodyBuilder.chipFontSize, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: host)
        label.font = .systemFont(
            ofSize: PermissionWebFetchCardBodyBuilder.chipFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        domainChipLabel = label

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    /// Dimmed secondary prompt text, 3-line cap, wrapping
    /// (`PermissionWebFetchCardBody.swift:37-43`).
    private func makePromptLabel(_ prompt: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: prompt)
        label.font = .systemFont(ofSize: PermissionWebFetchCardBodyBuilder.promptFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = PermissionWebFetchCardBodyBuilder.promptLineLimit
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the stack stretches the wrapping label across the card
        // column — a bounded width to wrap inside (the SwiftUI `.frame(maxWidth:
        // .infinity, alignment: .leading)`).
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

// MARK: - Per-kind data getters (VERBATIM from PermissionWebFetchCardBody.swift:50-66)
//
// Lifted from the SwiftUI body onto `PermissionRequest` so the parsing behaviour
// is identical and the AppKit body, the SwiftUI body, and both test classes
// share one source of truth. Prefixed `webFetch` to avoid colliding with any
// other per-kind getter on the request type.

extension PermissionRequest {

    /// The fetch URL — `nil` when absent or empty. (Verbatim from
    /// `PermissionWebFetchCardBody.url`, `:50-53`.)
    var webFetchURL: String? {
        let raw = rawInput["url"] as? String
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Parsed hostname for the domain chip. `nil` if `url` isn't a valid URL with
    /// a host component — the upstream falls back to the raw string in that case;
    /// we just hide the chip. (Verbatim from `PermissionWebFetchCardBody.hostname`,
    /// `:58-61`.)
    var webFetchHostname: String? {
        guard let url = webFetchURL, let parsed = URL(string: url) else { return nil }
        return parsed.host
    }

    /// The agent's question about the fetched content — `nil` when absent or
    /// empty. (Verbatim from `PermissionWebFetchCardBody.prompt`, `:63-66`.)
    var webFetchPrompt: String? {
        let raw = rawInput["prompt"] as? String
        return (raw?.isEmpty == false) ? raw : nil
    }
}
