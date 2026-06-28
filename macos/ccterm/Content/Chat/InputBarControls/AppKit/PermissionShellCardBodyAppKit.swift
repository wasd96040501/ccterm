import AgentSDK
import AppKit

/// AppKit body for `.bash` / `.powerShell` permission requests — the real
/// per-kind body the parallel fan-out (plan §4.4) swaps in for the
/// `PermissionShellCardBodyBuilder` STUB the dispatch spine registered
/// (`PermissionCardBodyBuilding.swift`). 1:1 relocation of the SwiftUI
/// `PermissionShellCardBody` (`PermissionShellCardBody.swift`), constants lifted
/// verbatim.
///
/// **Shape.** The command is always rendered as a code-block card via the shared
/// `PermissionBoundedDiffView` in `isNewFile` mode (`oldString == nil` → no
/// `+`/`-` sign column; reads as a code listing, not an all-additions diff),
/// with the chrome stripped (`showsLangBadge = false`, `showsCopyIcon = false`)
/// exactly as the SwiftUI body does (`PermissionShellCardBody.swift:39-42`):
/// the language pill would always read "bash"/"powershell" (redundant with the
/// kind icon on the card) and the copy button would hand out a command the user
/// hasn't yet authorised. The diff height caps at
/// `PermissionShellCardBody.commandMaxHeight` (240) and scrolls — buttons always
/// stay reachable. Below it: the optional `description` (dim, 2-line) and the
/// optional compound-command hint (`list.bullet.indent` + count).
///
/// There is **no nil-diff arm** for Shell — `commandDiffBlock` always produces a
/// `DiffBlock` (empty command renders as `"—"`), so the diff arm is
/// unconditional. This differs from FileWrite/SedEdit, which carry a localized
/// secondary-text fallback when their diff is nil (and SedEdit also appends the
/// literal command); Shell never does. The per-kind data getters
/// (`command` / `description` / `isCompoundCommand` / `bashRuleCount` /
/// `compoundHint` / `commandDiffBlock`) are reused VERBATIM by delegating to the
/// SwiftUI `PermissionShellCardBody`'s `internal` getters — same inputs the
/// `PermissionShellCardBodyTests` assert on, no re-derivation.
///
/// Pure synchronous build: the `DiffBlock` is computed at build time (no FS read
/// — the command text comes straight from `rawInput`), and the embedded
/// `PermissionBoundedDiffView` owns the cancellable highlight `Task`. No state
/// lives on this view; it is a function of the request.
final class PermissionShellCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionShellCardBody.swift)

    /// Outer VStack spacing (`PermissionShellCardBody.swift:33`).
    static let stackSpacing: CGFloat = 6
    /// `description` / `compoundHint` font size — `.system(size: 11)`
    /// (`PermissionShellCardBody.swift:46,53,58`).
    static let secondaryFontSize: CGFloat = 11
    /// `description` max line count (`PermissionShellCardBody.swift:48`).
    static let descriptionMaxLines: Int = 2
    /// Compound-hint `Label` icon↔text gap. The SwiftUI hint is a
    /// `Label { Text } icon { Image }` (`PermissionShellCardBody.swift:52-60`),
    /// whose icon-to-title gap is the system Label spacing (~6), NOT an explicit
    /// HStack spacing.
    static let hintRowSpacing: CGFloat = 6
    /// Diff height cap (`PermissionShellCardBody.commandMaxHeight`, 240).
    static let commandMaxHeight: CGFloat = PermissionShellCardBody.commandMaxHeight

    // MARK: - Inputs (data getters reused verbatim via the SwiftUI body)

    let request: PermissionRequest
    let kind: PermissionCardKind

    /// The SwiftUI body, held only as the source of the verbatim per-kind data
    /// getters (`command` / `description` / `compoundHint` / `commandDiffBlock`).
    /// Never rendered — its `internal` getters are pure derivations of `request`
    /// (`PermissionShellCardBody.swift:70-138`), so reusing them here is the
    /// literal "reuse the per-kind data getters VERBATIM" the plan calls for.
    private let dataSource: PermissionShellCardBody

    // MARK: - Subviews

    private let stack = NSStackView()
    /// The command diff (always present). Retained so its highlight `Task` stays
    /// alive for the card's lifetime and is cancellable on teardown.
    private let diffBlock: PermissionBoundedDiffView

    // MARK: - Init

    /// - Parameters:
    ///   - request: the pending permission's request.
    ///   - kind: `.bash` or `.powerShell` (drives the synthetic `.sh`/`.ps1`
    ///     highlight language inside `commandDiffBlock`).
    ///   - engine: the shared syntax engine (`DetailContext.syntaxEngine`) for
    ///     the diff highlight pass; nil-safe (then the command renders
    ///     un-highlighted, matching `DiffView.runHighlight`'s `guard let engine`).
    init(request: PermissionRequest, kind: PermissionCardKind, engine: SyntaxHighlightEngine?) {
        self.request = request
        self.kind = kind
        let source = PermissionShellCardBody(request: request, kind: kind)
        self.dataSource = source
        self.diffBlock = PermissionBoundedDiffView(
            diff: source.commandDiffBlock, engine: engine, maxHeight: Self.commandMaxHeight)
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

        buildArrangedSubviews()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`. The diff's
    /// highlight Task is cancelled in `PermissionBoundedDiffView.removeFromSuperview`
    /// / `stop()`, not here.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The currently-arranged top-level subviews (diff / description / hint), in
    /// order. Read-only — a measurement test asserts the gating (description and
    /// hint present only when non-nil/non-empty).
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }
    /// The command diff view (always present).
    var resolvedDiffView: PermissionBoundedDiffView { diffBlock }
    /// The description label, present only when a non-empty `description` exists.
    private(set) var descriptionLabel: NSTextField?
    /// The compound-hint row (icon + text), present only when `compoundHint`
    /// resolved non-nil.
    private(set) var compoundHintRow: NSView?
    /// The resolved hint text (mirrors `compoundHint`), for a measurement test.
    var resolvedCompoundHint: String? { dataSource.compoundHint }
    /// The resolved description (mirrors the body's getter), for a test.
    var resolvedDescription: String? { dataSource.description }

    // MARK: - Sizing (regime-B — content drives size; never leak a min up to host)

    /// The card content (not this body) governs the card width; publish
    /// `noIntrinsicMetric` width so a long single-line command never leaks a
    /// min-width up into the full-pane card host (R1). Height flows from the
    /// arranged content via the vertical stack's edge pins.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews() {
        // Command diff — always present (`PermissionShellCardBody.swift:34-43`).
        diffBlock.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(diffBlock)
        diffBlock.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        diffBlock.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Description — only when non-empty (`PermissionShellCardBody.swift:44-50`).
        if let description = dataSource.description, !description.isEmpty {
            let label = makeDescriptionLabel(description)
            descriptionLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            // `==` so the wrapping/truncating label has a bounded width to lay out
            // inside the card column (matching the SwiftUI body's
            // `.frame(maxWidth: .infinity, alignment: .leading)`,
            // `PermissionShellCardBody.swift:49`).
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // Compound-command hint — only when `compoundHint` resolved non-nil
        // (`PermissionShellCardBody.swift:51-61`).
        if let hint = dataSource.compoundHint {
            let row = makeCompoundHintRow(hint)
            compoundHintRow = row
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    /// The dim 2-line description (`PermissionShellCardBody.swift:45-49`):
    /// `.font(.system(size: 11))`, `.foregroundStyle(.secondary)`,
    /// `.lineLimit(2)`, leading-aligned full width.
    private func makeDescriptionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: Self.secondaryFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = Self.descriptionMaxLines
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the stack stretches it across the card column, giving the
        // wrap a bounded width rather than a single growing line.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// The compound-command hint `Label` (`PermissionShellCardBody.swift:51-61`):
    /// `list.bullet.indent` icon size 11 secondary + text size 11 secondary, the
    /// system Label icon↔text gap.
    private func makeCompoundHintRow(_ hint: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Self.hintRowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "list.bullet.indent", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: Self.secondaryFontSize, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSTextField(wrappingLabelWithString: hint)
        text.font = .systemFont(ofSize: Self.secondaryFontSize)
        text.textColor = .secondaryLabelColor
        text.alignment = .left
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        // Stretch the text across the rest of the row so a long hint wraps within
        // the card column rather than growing to one clipped line.
        text.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        return row
    }
}

// MARK: - Body builder

/// The real `PermissionCardBodyBuilding` conformer for `.bash` / `.powerShell`,
/// returned by `permissionCardBodyBuilder(for:)`
/// (`PermissionCardBodyBuilding.swift:50-51`). Replaces the STUB of the same name
/// the dispatch spine registered — the integration step (which builds once for
/// all bodies) drops the stub so only this real builder remains. This file owns
/// EXACTLY the body view + this builder; it does NOT edit the dispatch switch or
/// any sibling-body / shared file.
struct PermissionShellCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionShellCardBodyView(
            request: request,
            kind: PermissionCardKind.kind(for: request),
            engine: engine)
    }
}
