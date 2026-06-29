import AgentSDK
import AppKit

/// AppKit body for `.notebookEdit` permission requests — the 1:1 relocation of
/// the SwiftUI `PermissionNotebookEditCardBody`
/// (`InputBarControls/PermissionNotebookEditCardBody.swift:15-105`). Built for the
/// pure-AppKit permission card (migration plan §4.4): a vertical `NSStackView`
/// column of `NSTextField`s + the shared `PermissionMonospaceScrollView` helper.
///
/// Mirrors the upstream `NotebookEditPermissionRequest` shape:
/// - `subtitle` — names the action (insert / delete / replace) and the target
///   notebook basename, as the size-12 medium headline (1 line, middle
///   truncation, full-width leading).
/// - `cellLabel` — `Cell <id> · <markdown|python>` dimmed below.
/// - `sourcePreview` — the cell's `new_source` in a 200pt-cap monospace scroll so
///   a long cell body doesn't push the decision buttons off-screen. For "delete"
///   `new_source` is typically empty, so the preview is suppressed and the user
///   identifies the cell from `cellLabel` only.
///
/// **Data getters reused VERBATIM.** All field extraction
/// (`notebookPath` / `basename` / `editMode` / `cellType` / `cellId` /
/// `subtitle` / `cellLabel` / `sourcePreview`, including the localized
/// `"Insert cell into %@"` / `"Delete cell from %@"` / `"Edit cell in %@"` /
/// `"Cell %@ · %@"` / `"markdown"` / `"python"` strings) lives on the still-extant
/// SwiftUI `PermissionNotebookEditCardBody` struct and is read straight off an
/// instance of it. That keeps the parsing single-sourced and means the existing
/// `PermissionNotebookEditCardBodyTests` already pins the data layer — this file
/// only owns the AppKit layout.
@MainActor
final class PermissionNotebookEditCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionNotebookEditCardBody.swift:18-42)

    /// Outer VStack spacing (`PermissionNotebookEditCardBody.swift:19`).
    static let stackSpacing: CGFloat = 8
    /// Subtitle font size (`PermissionNotebookEditCardBody.swift:22`).
    static let subtitleFontSize: CGFloat = 12
    /// Cell-label font size (`PermissionNotebookEditCardBody.swift:30`).
    static let cellLabelFontSize: CGFloat = 11
    /// Source-preview monospace scroll height cap
    /// (`PermissionNotebookEditCardBody.swift:41`).
    static let sourceScrollMaxHeight: CGFloat = 200

    // MARK: - Subviews

    private let stack = NSStackView()
    /// Optional — present only when `subtitle` is non-nil (requires a
    /// `notebook_path`).
    private var subtitleLabel: NSTextField?
    /// Optional — present only when `cellLabel` is non-nil (requires a `cell_id`).
    private var cellLabelField: NSTextField?
    /// Optional — present only when `sourcePreview` is non-nil/non-empty.
    private var sourceBlock: PermissionMonospaceScrollView?

    // MARK: - Init

    init(request: PermissionRequest) {
        // Reuse the SwiftUI body's data getters VERBATIM — same parsing, same
        // localized strings, same insert/delete/replace subtitle and cell-type
        // labeling (already pinned by `PermissionNotebookEditCardBodyTests`).
        let data = PermissionNotebookEditCardBody(request: request)
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
        setAccessibilityLabel(data.subtitle ?? data.cellLabel ?? "")
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

    private func buildArrangedSubviews(data: PermissionNotebookEditCardBody) {
        // Subtitle — size-12 medium, primary, single line, middle truncation,
        // full-width leading (`PermissionNotebookEditCardBody.swift:20-27`).
        // Present only when a notebook_path resolved a basename.
        if let subtitle = data.subtitle {
            let label = NSTextField(labelWithString: subtitle)
            label.font = .systemFont(ofSize: Self.subtitleFontSize, weight: .medium)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
            // Hug low so the leading-aligned label stretches to fill the card
            // column (SwiftUI `.frame(maxWidth: .infinity, alignment: .leading)`),
            // giving the middle-truncation a bounded width.
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitleLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // Cell label — size-11 secondary (`PermissionNotebookEditCardBody.swift:28-31`).
        // Present only when a cell_id resolved. The SwiftUI `Text(cellLabel)` has
        // no `.lineLimit`; the content is a short `Cell <id> · <type>` metadata
        // line, so a single-line `labelWithString:` field is a faithful match —
        // it sits leading-aligned in the column (no `maxWidth: .infinity` framing
        // upstream, so it hugs its content rather than stretching).
        if let cellLabel = data.cellLabel {
            let field = NSTextField(labelWithString: cellLabel)
            field.font = .systemFont(ofSize: Self.cellLabelFontSize)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cellLabelField = field
            stack.addArrangedSubview(field)
            field.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        }

        // Source preview — 200pt-cap monospace scroll
        // (`PermissionNotebookEditCardBody.swift:33-42`). The shared
        // `PermissionMonospaceScrollView` reproduces the
        // `ScrollView(.vertical, showsIndicators: true) { Text(...monospaced...,
        // .textSelection(.enabled)) }.frame(maxHeight: 200)` pattern. Suppressed
        // for "delete" (empty `new_source`).
        if let preview = data.sourcePreview, !preview.isEmpty {
            let block = PermissionMonospaceScrollView(
                text: preview, maxHeight: Self.sourceScrollMaxHeight)
            sourceBlock = block
            stack.addArrangedSubview(block)
            block.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            block.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The subtitle (headline) text rendered, or `nil` when the row was omitted
    /// (no notebook_path).
    var renderedSubtitle: String? { subtitleLabel?.stringValue }
    /// The subtitle label's line clamp (SwiftUI `.lineLimit(1)`).
    var subtitleMaxLines: Int? { subtitleLabel?.maximumNumberOfLines }
    /// The cell-label text rendered, or `nil` when the row was omitted (no cell_id).
    var renderedCellLabel: String? { cellLabelField?.stringValue }
    /// Whether the source-preview monospace scroll block was mounted.
    var hasSourceBlock: Bool { sourceBlock != nil }
    /// The source scroll block's resolved (clamped) height, or `nil` when absent.
    var sourceResolvedHeight: CGFloat? { sourceBlock?.resolvedHeight }
    /// The stack's currently-arranged subviews, in order — for a measurement test
    /// asserting the row composition.
    var arrangedSubviews: [NSView] { stack.arrangedSubviews }
}

// MARK: - Body builder

/// The `PermissionCardBodyBuilding` conformer for `.notebookEdit`. Named to MATCH
/// the dispatch stub `PermissionNotebookEditCardBodyBuilder` (in
/// `PermissionCardBodyBuilding.swift`) so the integration step deletes that stub
/// and this real builder takes over the name WITHOUT editing the dispatch switch
/// (the SedEdit / WebFetch convention; `PermissionCardDispatchTests` asserts the
/// dispatch returns `PermissionNotebookEditCardBodyBuilder.self`). The body
/// ignores `engine` (no diff family).
@MainActor
struct PermissionNotebookEditCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        // `engine` is unused — NotebookEdit has no diff/highlight surface (the
        // protocol threads it for the diff-family bodies). Intentionally ignored.
        PermissionNotebookEditCardBodyView(request: request)
    }
}
