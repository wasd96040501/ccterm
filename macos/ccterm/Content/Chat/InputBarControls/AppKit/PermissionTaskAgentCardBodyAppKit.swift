import AgentSDK
import AppKit

/// AppKit body for `.taskAgent` permission requests (Task / Agent) — the 1:1
/// relocation of the SwiftUI `PermissionTaskAgentCardBody`
/// (`InputBarControls/PermissionTaskAgentCardBody.swift:19-135`). Built for the
/// pure-AppKit permission card (migration plan §4.4): an `NSStackView` column of
/// `NSTextField`s + the shared `PermissionBodyChip` / `PermissionMonospaceScrollBlock`
/// helpers.
///
/// Surfaces the structured sub-task so the user can read it before approving:
/// - `subagent_type` (Explore / Plan / …) as the size-12 medium headline.
/// - `description` (3–5 word summary) dimmed below, 2-line clamp.
/// - `isolation == "worktree"` + a `model` override as size-10 rounded chips.
/// - `prompt` in a 200pt-cap monospace scroll so a long prompt doesn't push the
///   decision buttons off-screen.
///
/// **Data getters reused VERBATIM.** All field extraction
/// (`subagentType` / `description` / `prompt` / `isolation` / `modelOverride` /
/// `subtitle` / `chips`, including the localized `"Run %@ agent"` / `"Run sub-task"`
/// / `"Isolated worktree"` / `"model: %@"` strings) lives on the still-extant
/// SwiftUI `PermissionTaskAgentCardBody` struct and is read straight off an
/// instance of it. That keeps the parsing single-sourced and means the existing
/// `PermissionTaskAgentCardBodyTests` already pins the data layer — this file
/// only owns the AppKit layout.
@MainActor
final class PermissionTaskAgentCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionTaskAgentCardBody.swift)

    /// Outer VStack spacing (`PermissionTaskAgentCardBody.swift:23`).
    static let stackSpacing: CGFloat = 8
    /// Chip-row HStack spacing (`PermissionTaskAgentCardBody.swift:38`).
    static let chipRowSpacing: CGFloat = 6
    /// Subtitle font size (`PermissionTaskAgentCardBody.swift:25`).
    static let subtitleFontSize: CGFloat = 12
    /// Description font size (`PermissionTaskAgentCardBody.swift:32`).
    static let descriptionFontSize: CGFloat = 11
    /// Description line clamp (`PermissionTaskAgentCardBody.swift:33` — `.lineLimit(2)`).
    static let descriptionLineLimit: Int = 2
    /// Prompt monospace scroll height cap (`PermissionTaskAgentCardBody.swift:52`).
    static let promptScrollMaxHeight: CGFloat = 200

    // MARK: - Subviews

    private let stack = NSStackView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// Optional — present only when `description` is non-nil/non-empty.
    private var descriptionLabel: NSTextField?
    /// Optional — present only when `chips` is non-empty.
    private var chipRow: NSStackView?
    /// Optional — present only when `prompt` is non-nil/non-empty.
    private var promptBlock: PermissionMonospaceScrollBlock?

    // MARK: - Init

    init(request: PermissionRequest) {
        // Reuse the SwiftUI body's data getters VERBATIM — same parsing, same
        // localized strings, same chip composition (already pinned by
        // `PermissionTaskAgentCardBodyTests`).
        let data = PermissionTaskAgentCardBody(request: request)
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
        setAccessibilityLabel(data.subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — the card column drives the width; content the height)

    /// Publish `noIntrinsicMetric` width so the body never leaks a min-width up
    /// to the full-pane card host (plan R1). The card controller caps the card
    /// at `BlockStyle.maxLayoutWidth`; height flows from the stacked content.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(data: PermissionTaskAgentCardBody) {
        // Subtitle — size-12 medium, primary, single line, middle truncation
        // (`PermissionTaskAgentCardBody.swift:24-29`).
        subtitleLabel.stringValue = data.subtitle
        subtitleLabel.font = .systemFont(ofSize: Self.subtitleFontSize, weight: .medium)
        subtitleLabel.textColor = .labelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the leading-aligned label stretches to fill the card column
        // (SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`).
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(subtitleLabel)
        subtitleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        subtitleLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Description — size-11 secondary, 2-line clamp
        // (`PermissionTaskAgentCardBody.swift:30-36`).
        if let description = data.description, !description.isEmpty {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: Self.descriptionFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = Self.descriptionLineLimit
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            descriptionLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // Chip row — `[Isolated worktree] [model: X]` rounded pills, spacing 6
        // (`PermissionTaskAgentCardBody.swift:37-43`). Each chip is the shared
        // `PermissionBodyChip` (size-10 medium secondaryLabelColor text on a
        // labelColor@0.06 backplate).
        let chips = data.chips
        if !chips.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            // SwiftUI `HStack(spacing: 6)` with no explicit alignment → `.center`
            // (vertical centering), `PermissionTaskAgentCardBody.swift:38`.
            row.alignment = .centerY
            row.spacing = Self.chipRowSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            for chip in chips {
                row.addArrangedSubview(PermissionBodyChip(text: chip))
            }
            chipRow = row
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        }

        // Prompt — 200pt-cap monospace scroll (`PermissionTaskAgentCardBody.swift:44-53`).
        if let prompt = data.prompt, !prompt.isEmpty {
            let block = PermissionMonospaceScrollBlock(
                text: prompt, maxHeight: Self.promptScrollMaxHeight)
            promptBlock = block
            stack.addArrangedSubview(block)
            block.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            block.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The subtitle (headline) text actually rendered.
    var renderedSubtitle: String { subtitleLabel.stringValue }
    /// The description text rendered, or `nil` when the row was omitted.
    var renderedDescription: String? { descriptionLabel?.stringValue }
    /// The chip texts rendered, in row order (empty when no chip row).
    var renderedChipTexts: [String] {
        (chipRow?.arrangedSubviews ?? []).compactMap { ($0 as? PermissionBodyChip)?.text }
    }
    /// Whether the prompt monospace scroll block was mounted.
    var hasPromptBlock: Bool { promptBlock != nil }
    /// The prompt scroll block's resolved (clamped) height, or `nil` when absent.
    var promptResolvedHeight: CGFloat? { promptBlock?.resolvedHeight }
    /// The description label's line clamp (parity with SwiftUI `.lineLimit(2)`).
    var descriptionMaxLines: Int? { descriptionLabel?.maximumNumberOfLines }
    /// The subtitle label's line clamp (SwiftUI `.lineLimit(1)`).
    var subtitleMaxLines: Int { subtitleLabel.maximumNumberOfLines }
}

// MARK: - Body builder

/// The `PermissionCardBodyBuilding` conformer for `.taskAgent`. Named distinctly
/// from the dispatch stub `PermissionTaskAgentCardBodyBuilder` (in
/// `PermissionCardBodyBuilding.swift`) so this file adds the real port WITHOUT
/// editing the dispatch switch — the integration step repoints `.taskAgent` to
/// this builder. The body ignores `engine` (no diff family).
@MainActor
struct PermissionTaskAgentCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionTaskAgentCardBodyView(request: request)
    }
}
