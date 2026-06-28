import AgentSDK
import AppKit
import Foundation

/// AppKit body for `.skill` permission requests — the 1:1 port of the SwiftUI
/// `PermissionSkillCardBody` (`Content/Chat/InputBarControls/PermissionSkillCardBody.swift`),
/// built as a `PermissionCardBodyBuilding` conformer so the dispatch
/// (`permissionCardBodyBuilder(for:)`) returns it for `.skill`. This struct keeps
/// the spine's stub name (`PermissionSkillCardBodyBuilder`); the integration step
/// (which builds once for all bodies) deletes the matching STUB from
/// `PermissionCardBodyBuilding.swift` so only this real builder remains — this
/// file never edits the dispatch switch.
///
/// Mirrors `SkillPermissionRequest` upstream: the skill name (quoted) as the
/// headline, the optional `args` rendered monospaced underneath, and a
/// working-directory chip so the user can see the per-cwd scope "Allow always"
/// would install. Upstream pulls the cwd from `originalCwd` on the tool-use
/// confirmation; that field doesn't reach us in `rawInput`, so we fall back to
/// the process's current working directory — the same value the CLI echoed when
/// the request was queued.
///
/// **cwd chip is the icon+label form, NOT `PermissionBodyChip`.** Skill's cwd
/// chip is the SF Symbol + size-11 label form with no pill backplate —
/// explicitly carved out from the rounded-pill `PermissionBodyChip` (Mcp /
/// TaskAgent) by that helper's docstring ("WebFetch's domain chip and Skill's
/// cwd chip are a SEPARATE icon+label form … those bodies render their
/// icon+label inline and do NOT use `PermissionBodyChip`"). It is rendered
/// inline here, exactly as the SwiftUI `HStack { Image("folder"); Text(cwdLabel) }`
/// did (`PermissionSkillCardBody.swift:36-43`).
///
/// **Verbatim constants (from the SwiftUI body, `:20-43`):**
/// - layout: `VStack(alignment: .leading, spacing: 8)` → vertical `NSStackView`
///   `spacing 8`, `.leading`.
/// - headline: `.system(size: 12, weight: .medium)` `.primary` (labelColor),
///   lineLimit 1, truncation `.middle`, full-width leading.
/// - args: `.system(size: 12, design: .monospaced)` `.primary`, lineLimit 3,
///   selectable, full-width leading; rendered only when non-empty.
/// - cwd chip: `HStack(spacing: 4)` of the `folder` SF Symbol (size-10
///   `.secondary`) + cwd-basename label (size-11 weight `.medium` `.secondary`).
///
/// **Per-kind data getters reused VERBATIM** from the SwiftUI body
/// (`skill` / `args`, `:53-63`) — copied byte-for-byte as free helpers on
/// `PermissionRequest` (prefixed `skill`) so the parsing behaviour is identical
/// and the AppKit body, the SwiftUI body, and both test classes share one source
/// of truth. The headline composition (`headline`) and the process-derived cwd
/// basename (`cwdLabel`, `:68-84`) live on the view because they compose/derive
/// rather than parse `rawInput`.
///
/// Localised strings reused verbatim from the SwiftUI source: `"Use skill"` and
/// `"Use skill \"%@\""` (both already in `Localizable.xcstrings` with zh-Hans).
/// No new catalog entries.
struct PermissionSkillCardBodyBuilder: PermissionCardBodyBuilding {

    // MARK: - Constants (verbatim from PermissionSkillCardBody.swift:20-43)

    /// Outer VStack spacing (`PermissionSkillCardBody.swift:20`).
    static let stackSpacing: CGFloat = 8
    /// Headline font size (`:22`).
    static let headlineFontSize: CGFloat = 12
    /// Monospaced `args` font size (`:29`).
    static let argsFontSize: CGFloat = 12
    /// Max visible `args` lines (`:31`).
    static let argsLineLimit: Int = 3
    /// cwd-chip icon↔label gap (`:36`).
    static let cwdRowSpacing: CGFloat = 4
    /// cwd-chip SF-Symbol point size (`:38`).
    static let cwdIconSize: CGFloat = 10
    /// cwd-chip label font size (`:41`).
    static let cwdLabelFontSize: CGFloat = 11

    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // `engine` is unused — Skill has no diff/highlight surface (the protocol
        // threads it for the diff-family bodies). Intentionally ignored.
        PermissionSkillCardBodyView(request: request)
    }
}

/// The Skill body's view. A vertical stack of: the quoted skill name headline,
/// an optional monospaced `args` line, and an optional inline cwd chip
/// (icon + basename).
@MainActor
final class PermissionSkillCardBodyView: NSView {

    // MARK: - Inputs

    let request: PermissionRequest

    // MARK: - Subviews

    private let stack = NSStackView()
    private let headlineLabel = NSTextField(labelWithString: "")

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The headline label's rendered string (the quoted skill name, or the
    /// no-skill fallback).
    var renderedHeadlineText: String { headlineLabel.stringValue }
    /// The args field, present only when `request.skillArgs` is non-empty.
    private(set) var argsField: NSTextField?
    /// The cwd-chip basename label, present only when `cwdLabel != nil`.
    private(set) var cwdChipLabel: NSTextField?
    /// The stack's currently-arranged subviews, in order — for a measurement test
    /// asserting the row composition (headline, optional args, optional cwd).
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }
    /// The args field's rendered string, or `nil` when no args row was built.
    var renderedArgsText: String? { argsField?.stringValue }
    /// The cwd chip's rendered basename, or `nil` when no cwd row was built.
    var renderedCwdText: String? { cwdChipLabel?.stringValue }
    /// Whether the args field is read-only + selectable (SwiftUI parity:
    /// `.textSelection(.enabled)` on a non-editable Text).
    var argsIsSelectableReadOnly: Bool {
        guard let field = argsField else { return false }
        return field.isSelectable && !field.isEditable
    }

    // MARK: - Init

    init(request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PermissionSkillCardBodyBuilder.stackSpacing
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
        setAccessibilityLabel(headline)
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
        // Headline — quoted skill name (or fallback), size-12 medium, single-line,
        // middle-truncated, full-width leading (`PermissionSkillCardBody.swift:21-26`).
        headlineLabel.stringValue = headline
        headlineLabel.font = .systemFont(
            ofSize: PermissionSkillCardBodyBuilder.headlineFontSize, weight: .medium)
        headlineLabel.textColor = .labelColor
        headlineLabel.maximumNumberOfLines = 1
        headlineLabel.cell?.usesSingleLineMode = true
        headlineLabel.lineBreakMode = .byTruncatingMiddle  // SwiftUI .truncationMode(.middle)
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hug low + compress low so a long skill name truncates inside the card
        // column rather than stretching the row (the SwiftUI `.frame(maxWidth:
        // .infinity, alignment: .leading)` + `.lineLimit(1)`).
        headlineLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headlineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(headlineLabel)
        headlineLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        headlineLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Args — monospaced, 3-line cap, selectable, full-width leading; rendered
        // only when non-empty (`PermissionSkillCardBody.swift:27-34`).
        if let args = request.skillArgs {
            let field = makeArgsField(args)
            argsField = field
            stack.addArrangedSubview(field)
            field.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            field.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // cwd chip (icon + basename) — only when a non-empty cwd basename exists
        // (`PermissionSkillCardBody.swift:35-44`).
        if let cwdLabel {
            stack.addArrangedSubview(makeCwdChip(basename: cwdLabel))
        }
    }

    /// Monospaced `args` text, 3-line cap, read-only + selectable, full-width
    /// leading (`PermissionSkillCardBody.swift:28-33`).
    private func makeArgsField(_ args: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: args)
        field.font = .monospacedSystemFont(
            ofSize: PermissionSkillCardBodyBuilder.argsFontSize, weight: .regular)
        field.textColor = .labelColor
        field.maximumNumberOfLines = PermissionSkillCardBodyBuilder.argsLineLimit
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = true  // SwiftUI .textSelection(.enabled)
        field.isEditable = false
        field.allowsEditingTextAttributes = false
        field.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the stack stretches it across the card column — a bounded
        // width to wrap inside (the SwiftUI `.frame(maxWidth: .infinity,
        // alignment: .leading)`).
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// `HStack(spacing: 4) { Image("folder") size10 .secondary; Text(cwdLabel)
    /// size11 weight.medium .secondary }` (`PermissionSkillCardBody.swift:36-43`).
    private func makeCwdChip(basename: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        // SwiftUI `HStack(spacing: 4)` with no explicit alignment → `.center`.
        row.alignment = .centerY
        row.spacing = PermissionSkillCardBodyBuilder.cwdRowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: PermissionSkillCardBodyBuilder.cwdIconSize, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: basename)
        label.font = .systemFont(
            ofSize: PermissionSkillCardBodyBuilder.cwdLabelFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cwdChipLabel = label

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    // MARK: - Composed / derived display values

    /// Headline subtitle. Quotes the skill name to match upstream's
    /// `Use skill "X"?` phrasing — the quotes also visually separate the skill
    /// identifier from the surrounding verb. (Verbatim from
    /// `PermissionSkillCardBody.headline`, `:68-73`.)
    var headline: String {
        if let skill = request.skillName {
            return String(localized: "Use skill \"\(skill)\"")
        }
        return String(localized: "Use skill")
    }

    /// Basename of the working directory the "Allow always" rule would scope to.
    /// Empty / unreadable cwd hides the chip rather than rendering a misleading
    /// "/" — the rule would still install against whatever cwd the CLI sees.
    /// (Verbatim from `PermissionSkillCardBody.cwdLabel`, `:79-84`.)
    var cwdLabel: String? {
        let cwd = FileManager.default.currentDirectoryPath
        guard !cwd.isEmpty else { return nil }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }
}

// MARK: - Per-kind data getters (VERBATIM from PermissionSkillCardBody.swift:53-63)
//
// Lifted from the SwiftUI body onto `PermissionRequest` so the parsing behaviour
// is identical and the AppKit body, the SwiftUI body, and both test classes
// share one source of truth. Prefixed `skill` to avoid colliding with any other
// per-kind getter on the request type.

extension PermissionRequest {

    /// The skill name (`"commit"`, `"review-pr"`, …). Falls through
    /// `skill` → `skillName` for older camelCase builds. `nil` when absent or
    /// empty. (Verbatim from `PermissionSkillCardBody.skill`, `:53-58`.)
    var skillName: String? {
        let raw =
            (rawInput["skill"] as? String)
            ?? (rawInput["skillName"] as? String)
        return raw?.isEmpty == false ? raw : nil
    }

    /// The skill's `args` string — `nil` when absent or empty. (Verbatim from
    /// `PermissionSkillCardBody.args`, `:60-63`.)
    var skillArgs: String? {
        let raw = rawInput["args"] as? String
        return raw?.isEmpty == false ? raw : nil
    }
}
