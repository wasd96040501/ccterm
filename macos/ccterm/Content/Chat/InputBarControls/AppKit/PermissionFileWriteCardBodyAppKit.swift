import AgentSDK
import AppKit

/// AppKit body for `.fileEdit` / `.fileWrite` permission requests — the 1:1
/// relocation of the SwiftUI `PermissionFileWriteCardBody`
/// (`InputBarControls/PermissionFileWriteCardBody.swift`). Built for the
/// pure-AppKit permission card (migration plan §4.4-5): an `NSStackView` column
/// of an optional subtitle (`Edit / Create / Overwrite <basename>`) + either the
/// shared `PermissionBoundedDiffView` (when a diff resolves) or the localized
/// secondary-text fallback hint (when it doesn't).
///
/// Surfaces the proposed change so the user can read it before approving:
/// - subtitle: size-12 medium primary, single line, middle truncation.
/// - diff arm: the shared `PermissionBoundedDiffView` — diff chrome stripped
///   (`showsLangBadge = false`, `showsCopyIcon = false`, there is nothing useful
///   to copy out of a pending edit), 240pt height cap, owns the highlight Task.
/// - nil-diff arm: the size-11 secondary fallback hint (FileWrite does NOT
///   append a literal command — that append is the SedEdit body's behavior).
///
/// **Data getters reused VERBATIM.** All field extraction
/// (`filePath` / `basename` / `fileExists` / `subtitle` / `diffBlock`, including
/// the localized `"Edit %@"` / `"Create %@"` / `"Overwrite %@"` subtitle strings
/// and the FS read in `writeDiffBlock`) lives on the still-extant SwiftUI
/// `PermissionFileWriteCardBody` struct and is read straight off an instance of
/// it. That keeps the parsing single-sourced and means the existing
/// `PermissionFileWriteCardBodyTests` already pin the data layer — this file only
/// owns the AppKit layout.
///
/// **The diff (and its FS read) is resolved at BUILD TIME**, once, in `init`
/// (via `data.diffBlock` → `writeDiffBlock`'s synchronous `String(contentsOf:)`)
/// — never in a `layout` / `draw` path (plan §4.4-5).
@MainActor
final class PermissionFileWriteCardBodyView: NSView {

    // MARK: - Constants (verbatim from PermissionFileWriteCardBody.swift)

    /// Outer VStack spacing (`PermissionFileWriteCardBody.swift:35`).
    static let stackSpacing: CGFloat = 8
    /// Subtitle font size (`PermissionFileWriteCardBody.swift:38`).
    static let subtitleFontSize: CGFloat = 12
    /// Fallback hint font size (`PermissionFileWriteCardBody.swift:59`).
    static let fallbackFontSize: CGFloat = 11
    /// Embedded diff height cap (`PermissionFileWriteCardBody.diffMaxHeight = 240`).
    static let diffMaxHeight: CGFloat = 240

    // MARK: - Subviews

    private let stack = NSStackView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// Present only when `diffBlock` resolves.
    private var diffView: PermissionBoundedDiffView?
    /// Present only when `diffBlock` is nil (the fallback hint).
    private var fallbackLabel: NSTextField?

    // MARK: - Init

    init(request: PermissionRequest, engine: SyntaxHighlightEngine?) {
        // Reuse the SwiftUI body's data getters VERBATIM — same parsing, same
        // localized strings, same diff resolution (already pinned by
        // `PermissionFileWriteCardBodyTests`).
        let kind = PermissionCardKind.kind(for: request)
        let data = PermissionFileWriteCardBody(request: request, kind: kind)
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

        buildArrangedSubviews(data: data, engine: engine)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(data.subtitle ?? PermissionCardCopy.title(for: request))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`. The embedded
    /// `PermissionBoundedDiffView` cancels its highlight Task on
    /// `removeFromSuperview`, so teardown is removal-driven, not deinit-timed.
    nonisolated deinit {}

    // MARK: - Sizing (regime-B — the card column drives the width; content the height)

    /// Publish `noIntrinsicMetric` width so the body never leaks a min-width up
    /// to the full-pane card host (plan R1). The card controller caps the card
    /// at `BlockStyle.maxLayoutWidth`; height flows from the stacked content.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Build

    private func buildArrangedSubviews(
        data: PermissionFileWriteCardBody, engine: SyntaxHighlightEngine?
    ) {
        // Subtitle — size-12 medium, primary, single line, middle truncation
        // (`PermissionFileWriteCardBody.swift:36-43`). Omitted when there's no
        // basename to name (`subtitle == nil`).
        if let subtitle = data.subtitle {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.font = .systemFont(ofSize: Self.subtitleFontSize, weight: .medium)
            subtitleLabel.textColor = .labelColor  // SwiftUI `.primary`
            subtitleLabel.maximumNumberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingMiddle  // SwiftUI `.truncationMode(.middle)`
            subtitleLabel.cell?.usesSingleLineMode = true
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            // Hug low so the leading-aligned label stretches to fill the card
            // column and truncates inside it (SwiftUI `.frame(maxWidth:
            // .infinity, alignment: .leading)`), never grows the row to the
            // path's full width.
            subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(subtitleLabel)
            subtitleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            subtitleLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // Diff (build-time resolved) OR fallback hint — exactly one
        // (`PermissionFileWriteCardBody.swift:44-61`).
        if let diff = data.diffBlock {
            // The FS read for Write already happened inside `data.diffBlock`
            // (build time, once). The bounded-diff view owns the highlight Task
            // + 240pt cap, with diff chrome stripped (showsLangBadge/Copy =
            // false set inside it), matching `DiffView(diff:, showsLangBadge:
            // false, showsCopyIcon: false)`.
            let view = PermissionBoundedDiffView(
                diff: diff, engine: engine, maxHeight: Self.diffMaxHeight)
            diffView = view
            stack.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        } else {
            // size-11 secondary fallback (`PermissionFileWriteCardBody.swift:57-60`).
            let label = NSTextField(
                wrappingLabelWithString: String(
                    localized: "Path missing — open the transcript to inspect"))
            label.font = .systemFont(ofSize: Self.fallbackFontSize)
            label.textColor = .secondaryLabelColor  // SwiftUI `.secondary`
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fallbackLabel = label
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The subtitle text actually rendered, or `nil` when the row was omitted
    /// (no derivable basename).
    var renderedSubtitle: String? {
        subtitleLabel.superview != nil ? subtitleLabel.stringValue : nil
    }
    /// Whether the bounded-diff view was mounted (the diff arm).
    var hasDiffView: Bool { diffView != nil }
    /// The embedded `DiffNSView`'s resolved `DiffBlock`, for asserting the parsed
    /// fields rendered through the real diff surface (nil when the fallback arm).
    var renderedDiff: DiffBlock? { diffView?.diff }
    /// The diff scroll's resolved (clamped) height, or `nil` when absent.
    var diffResolvedHeight: CGFloat? { diffView?.resolvedHeight }
    /// Whether the fallback hint was mounted (the nil-diff arm).
    var hasFallbackHint: Bool { fallbackLabel != nil }
    /// The fallback hint text rendered, or `nil` when the diff arm took over.
    var renderedFallbackText: String? { fallbackLabel?.stringValue }
    /// The subtitle label's line clamp (SwiftUI `.lineLimit(1)`).
    var subtitleMaxLines: Int { subtitleLabel.maximumNumberOfLines }
}

// MARK: - Body builder

/// The `PermissionCardBodyBuilding` conformer for `.fileEdit` / `.fileWrite`.
/// Named distinctly from the dispatch stub `PermissionFileWriteCardBodyBuilder`
/// (in `PermissionCardBodyBuilding.swift`) so this file adds the real port
/// WITHOUT editing the dispatch switch — the integration step repoints
/// `.fileEdit` / `.fileWrite` to this builder. Threads `engine` into the diff
/// arm's `PermissionBoundedDiffView`.
@MainActor
struct PermissionFileWriteCardBodyBuilder: PermissionCardBodyBuilding {
    func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
        PermissionFileWriteCardBodyView(request: request, engine: engine)
    }
}
