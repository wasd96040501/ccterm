import AgentSDK
import AppKit
import Foundation

/// AppKit body for `.mcp` permission requests (tools whose name starts with
/// `mcp__`) — the 1:1 port of the SwiftUI `PermissionMcpCardBody`
/// (`Content/Chat/InputBarControls/PermissionMcpCardBody.swift`), built as a
/// `PermissionCardBodyBuilding` conformer so the dispatch
/// (`permissionCardBodyBuilder(for:)`) returns it for `.mcp`.
///
/// Upstream has no dedicated MCP component — these would otherwise fall through
/// to the fallback. We parse the canonical `mcp__<server>__<tool>` triple so the
/// user sees both the originating MCP server (the trust boundary) and the bare
/// tool name. The full `rawInput` renders as pretty-printed JSON inside a
/// 200pt-cap monospace scroll (`PermissionMonospaceScrollBlock`), matching the
/// shape of the `taskAgent` / `notebook` bodies. The optional agent-supplied
/// `description` is dimmed under the headline.
///
/// **Verbatim constants (from the SwiftUI body, `:20-52,117-128`):**
/// - layout: `VStack(alignment: .leading, spacing: 8)` → vertical `NSStackView`
///   `spacing 8`, `.leading`.
/// - headline row: `HStack(.firstTextBaseline, spacing: 6)` → tool name (size-12
///   `.medium`, `labelColor`, single-line, middle truncation) + optional server
///   chip (`PermissionBodyChip`, the rounded-pill form, §4.4 chip-shape note) +
///   trailing spacer.
/// - description: size-11 `secondaryLabelColor`, up to 3 lines, full width.
/// - JSON block: `PermissionMonospaceScrollBlock(maxHeight: 200)` — size-12
///   monospaced, selectable, scroller present at rest, capped at 200pt.
///
/// **Per-kind data getters reused VERBATIM** from the SwiftUI body
/// (`components` / `serverName` / `toolDisplayName` / `description` /
/// `inputJSON`) — copied byte-for-byte as free helpers on `PermissionRequest` so
/// the parsing + JSON-serialisation behaviour is identical (the existing
/// `PermissionMcpCardBodyTests` still exercises the SwiftUI struct; the new
/// `PermissionMcpBodyTests` drives this AppKit surface).
struct PermissionMcpCardBodyBuilder: PermissionCardBodyBuilding {

    // MARK: - Constants (verbatim from PermissionMcpCardBody.swift:20-52)

    /// Outer VStack spacing (`PermissionMcpCardBody.swift:21`).
    static let stackSpacing: CGFloat = 8
    /// Headline HStack spacing (`PermissionMcpCardBody.swift:22`).
    static let headlineSpacing: CGFloat = 6
    /// Tool-name font size (`PermissionMcpCardBody.swift:24`).
    static let toolNameFontSize: CGFloat = 12
    /// Description font size (`PermissionMcpCardBody.swift:35`).
    static let descriptionFontSize: CGFloat = 11
    /// Description line cap (`PermissionMcpCardBody.swift:37`).
    static let descriptionLineLimit: Int = 3
    /// JSON monospace-scroll height cap (`PermissionMcpCardBody.swift:48`).
    static let jsonMaxHeight: CGFloat = 200

    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // `engine` is unused — the MCP body has no diff/highlight surface (the
        // protocol threads it for the diff-family bodies). Intentionally ignored.
        PermissionMcpCardBodyView(request: request)
    }
}

/// The MCP body's view. A vertical stack of: headline (tool name + optional
/// server chip), optional dimmed description, optional capped JSON scroll.
@MainActor
final class PermissionMcpCardBodyView: NSView {

    // MARK: - Inputs

    let request: PermissionRequest

    // MARK: - Subviews

    private let stack = NSStackView()

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The tool-name label (always present).
    private(set) var toolNameLabel: NSTextField!
    /// The server chip, present only when the triple parses a server segment.
    private(set) var serverChip: PermissionBodyChip?
    /// The dimmed description label, present only when a non-empty description
    /// was supplied.
    private(set) var descriptionLabel: NSTextField?
    /// The capped monospace JSON scroll, present only when `inputJSON` is
    /// non-nil and non-empty.
    private(set) var jsonBlock: PermissionMonospaceScrollBlock?

    /// The stack's currently-arranged subviews, in order — for a measurement
    /// test asserting the 4-branch row composition.
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }

    // MARK: - Init

    init(request: PermissionRequest) {
        self.request = request
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PermissionMcpCardBodyBuilder.stackSpacing
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
        setAccessibilityLabel(request.mcpToolDisplayName)
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
        // Headline row: tool name + optional server chip + trailing spacer.
        let headline = makeHeadlineRow()
        stack.addArrangedSubview(headline)
        headline.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        headline.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Description (only when non-empty) — size-11 secondary, up to 3 lines,
        // full width leading-aligned (`PermissionMcpCardBody.swift:33-39`).
        if let description = request.mcpDescription, !description.isEmpty {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: PermissionMcpCardBodyBuilder.descriptionFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = PermissionMcpCardBodyBuilder.descriptionLineLimit
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            // Hug low so the stack stretches it to the card column, giving the
            // wrapping label a bounded width to wrap inside (mirrors the
            // SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`).
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            descriptionLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // JSON block (only when there's something to show) — pretty-printed,
        // size-12 monospaced, capped at 200pt + scrolling
        // (`PermissionMcpCardBody.swift:40-49`).
        if let json = request.mcpInputJSON, !json.isEmpty {
            let block = PermissionMonospaceScrollBlock(
                text: json, maxHeight: PermissionMcpCardBodyBuilder.jsonMaxHeight)
            block.translatesAutoresizingMaskIntoConstraints = false
            jsonBlock = block
            stack.addArrangedSubview(block)
            block.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            block.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func makeHeadlineRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = PermissionMcpCardBodyBuilder.headlineSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        // Tool name — size-12 medium, primary, single-line, middle truncation
        // (`PermissionMcpCardBody.swift:23-27`).
        let name = NSTextField(labelWithString: request.mcpToolDisplayName)
        name.font = .systemFont(
            ofSize: PermissionMcpCardBodyBuilder.toolNameFontSize, weight: .medium)
        name.textColor = .labelColor
        name.maximumNumberOfLines = 1
        name.cell?.usesSingleLineMode = true
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        // Hug low so the name takes the available width and truncates in the
        // middle rather than pushing the chip / spacer off the row.
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolNameLabel = name
        row.addArrangedSubview(name)

        // Optional server chip — the rounded-pill form (§4.4 chip-shape note:
        // the Mcp serverChip is `PermissionBodyChip`, NOT the icon+label form).
        if let server = request.mcpServerName {
            let chip = PermissionBodyChip(text: server)
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            serverChip = chip
            row.addArrangedSubview(chip)
        }

        // Trailing spacer — SwiftUI `Spacer(minLength: 0)` keeps the row
        // leading-packed.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        return row
    }
}

// MARK: - Per-kind data getters (VERBATIM from PermissionMcpCardBody.swift:54-115)
//
// Lifted from the SwiftUI body onto `PermissionRequest` so the parsing +
// JSON-serialisation behaviour is identical and the AppKit body, the SwiftUI
// body, and both test classes share one source of truth. Prefixed `mcp` to
// avoid colliding with any other per-kind getter on the request type.

extension PermissionRequest {

    /// Parsed triple from `mcp__<server>__<tool>`. Returns `nil` when the tool
    /// name doesn't match the prefix — but `kind(for:)` only routes the MCP body
    /// for names that do, so the body always has at least a `server` and `tool`.
    /// (Verbatim from `PermissionMcpCardBody.components`, `:60-79`.)
    var mcpComponents: (server: String, tool: String)? {
        let name = toolName
        guard name.hasPrefix("mcp__") else { return nil }
        let stripped = String(name.dropFirst("mcp__".count))
        let parts = stripped.components(separatedBy: "__")
        switch parts.count {
        case 0: return nil
        case 1:
            // No tool segment — server name alone. Surface the server as both
            // pieces so the headline isn't blank.
            return (parts[0], parts[0])
        default:
            // `mcp__server__a__b` — the upstream convention is that everything
            // after the second `__` is the tool name, joined back with `__`.
            let server = parts[0]
            let tool = parts.dropFirst().joined(separator: "__")
            return (server, tool)
        }
    }

    /// The parsed MCP server segment (the trust boundary), if any.
    var mcpServerName: String? { mcpComponents?.server }

    /// The parsed MCP tool segment, if any.
    var mcpToolName: String? { mcpComponents?.tool }

    /// Display name for the tool. Falls back to the literal `toolName` when
    /// parsing fails — better the user sees `mcp__weird` than an empty headline.
    /// (Verbatim from `PermissionMcpCardBody.toolDisplayName`, `:87-89`.)
    var mcpToolDisplayName: String { mcpToolName ?? toolName }

    /// The agent-supplied `description` from the raw input, when non-empty.
    /// (Verbatim from `PermissionMcpCardBody.description`, `:91-94`.)
    var mcpDescription: String? {
        let raw = rawInput["description"] as? String
        return raw?.isEmpty == false ? raw : nil
    }

    /// Pretty-printed JSON for the input map. Sorted keys so the order is stable
    /// across renders — MCP servers don't guarantee any particular key order.
    /// Returns `nil` when there's nothing to show (empty rawInput) and `""` when
    /// serialisation fails so the body collapses the row. (Verbatim from
    /// `PermissionMcpCardBody.inputJSON`, `:101-115`.)
    var mcpInputJSON: String? {
        let dict = rawInput
        guard !dict.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(dict) else {
            return ""
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
