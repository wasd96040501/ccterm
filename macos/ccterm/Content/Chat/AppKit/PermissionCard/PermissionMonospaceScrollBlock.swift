import AppKit

/// AppKit replacement for the verbatim-identical
/// `ScrollView(.vertical) { Text(...monospaced...) }.frame(maxHeight:)` pattern
/// in the permission card bodies — `PermissionMcpCardBody.swift:40-49`,
/// `PermissionTaskAgentCardBody.swift:44-53`,
/// `PermissionNotebookEditCardBody.swift:33-42`,
/// `PermissionExitPlanModeCardBody.swift:34-42`.
///
/// A height-capped vertical scroll wrapping a read-only, user-selectable
/// monospaced text view. Constants lifted verbatim:
/// - text font = `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`
///   (SwiftUI `.system(size: 12, design: .monospaced)`)
/// - foreground = `labelColor` (SwiftUI `.primary`)
/// - leading-aligned, wraps to full width
/// - selectable + ⌘C (SwiftUI `.textSelection(.enabled)`)
/// - vertical scroll indicator PRESENT at rest — all four callers use
///   `ScrollView(.vertical, showsIndicators: true)`
///   (`PermissionMcpCardBody.swift:41`, `PermissionTaskAgentCardBody.swift:45`,
///   `PermissionNotebookEditCardBody.swift:34`, `PermissionExitPlanModeCardBody.swift:35`),
///   so we use `autohidesScrollers = false` + `scrollerStyle = .legacy` (a
///   persistent track) rather than the autohiding `.overlay` scroller. This is
///   the OPPOSITE of `PermissionBoundedDiffView`, whose SwiftUI source
///   (`BoundedHeightScrollView.swift:30`) is `showsIndicators: false`.
///
/// **Bounded-height behavior (plan §4.4-7).** Reproduces
/// `BoundedHeightScrollView`'s `min(content.idealHeight, maxHeight)`: the block
/// sizes to its intrinsic content height when the text fits, and caps + scrolls
/// when it overflows. The resolved height is computed from the text view's
/// layout manager `usedRect` at the SETTLED wrap width (after
/// `layoutSubtreeIfNeeded`), NOT from a pre-layout intrinsic read (which
/// under-reports and collapses the block). The cap is per-caller (200pt for
/// Mcp / TaskAgent / NotebookEdit, 480pt for ExitPlanMode) — threaded as an
/// init parameter.
///
/// `isEditable == false` ⇒ no IME marked text (don't copy that machinery).
final class PermissionMonospaceScrollBlock: NSView {

    // MARK: - Constants (verbatim from PermissionMcpCardBody.swift:40-49)

    /// Monospaced text font size (`PermissionMcpCardBody.swift:43`).
    static let textFontSize: CGFloat = 12

    // MARK: - Public

    /// Per-caller height cap: 200 (Mcp / TaskAgent / NotebookEdit) or 480
    /// (ExitPlanMode). Threaded, never hardcoded.
    let maxHeight: CGFloat

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let textView: NSTextView

    /// The clamp constraint on the scroll view height — set per layout to
    /// `min(usedHeight, maxHeight)`.
    private var heightConstraint: NSLayoutConstraint!

    /// The width the used-height was last computed at, so we only re-measure on
    /// an actual width change (the §4.4-7 re-clamp on pane resize).
    private var lastMeasuredWidth: CGFloat = -1

    // MARK: - Init

    init(text: String, maxHeight: CGFloat) {
        self.maxHeight = maxHeight

        // Build the text view + its container with width tracking enabled so it
        // wraps to the scroll view's content width (full-width leading wrap).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        self.textView = tv

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        configureTextView(text: text)
        configureScrollView()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: maxHeight)
        // Non-required so it never propagates an over-tall demand up into the
        // host's fittingSize (plan R1 — the card content, not the block, drives
        // the card width; the cap is satisfied at high priority).
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The current resolved (clamped) height of the scroll view.
    var resolvedHeight: CGFloat { heightConstraint.constant }

    /// Whether the embedded text view is read-only (no IME). Tests assert
    /// `isEditable == false`.
    var isTextEditable: Bool { textView.isEditable }

    /// Whether the embedded text view is selectable (⌘C works). Tests assert
    /// `isSelectable == true`.
    var isTextSelectable: Bool { textView.isSelectable }

    /// The used (typeset) height of the text at the current wrap width — the
    /// pre-clamp value the resolved height is `min(_, maxHeight)` of.
    var usedTextHeight: CGFloat { measuredUsedHeight() }

    // MARK: - Configuration

    private func configureTextView(text: String) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: Self.textFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.isEditable = false  // read-only ⇒ no IME marked text
        textView.isSelectable = true  // ⌘C / drag-select still work
        textView.isRichText = false
        textView.drawsBackground = false
        textView.alignment = .left  // leading-aligned
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func configureScrollView() {
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // SwiftUI `showsIndicators: true` (all four monospace callers) ⇒ a
        // persistent track, not the autohiding overlay scroller. `.legacy` +
        // `autohidesScrollers = false` keeps the vertical indicator visible at
        // rest when the content overflows.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
    }

    // MARK: - Layout — clamp to min(usedHeight, cap) at the settled width

    override func layout() {
        super.layout()
        clampHeightIfNeeded()
    }

    /// Re-clamp the scroll view height to `min(usedTextHeight, maxHeight)`,
    /// recomputing the used height at the settled wrap width. Only re-measures
    /// when the width actually changed (the §4.4-7 re-clamp on pane resize).
    ///
    /// The guard keys on `scrollView.contentSize.width` — the SAME value
    /// `measuredUsedHeight()` typesets against — not the block's own
    /// `bounds.width`. They are not equal (the content width is inset by the
    /// scroller), and if the content width settles a tick AFTER `bounds.width`
    /// is already non-zero, keying on `bounds.width` would latch the guard and
    /// measure the used height at a stale/zero container width forever (the
    /// macOS "source-phase read needs settled geometry" hazard). Matches
    /// `PermissionBoundedDiffView.clampHeightIfNeeded`.
    private func clampHeightIfNeeded() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if width == lastMeasuredWidth { return }
        lastMeasuredWidth = width
        let used = measuredUsedHeight()
        heightConstraint.constant = min(used, maxHeight)
    }

    /// The typeset height of the text at the current wrap width, read from the
    /// layout manager's `usedRect` on a primed text container. Mirrors the
    /// DiffNSView height-cap discipline: measure at the settled width, never
    /// from a stale pre-layout intrinsic read.
    private func measuredUsedHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return 0 }
        // The container width must track the scroll view's content width before
        // we read the used rect, or wrapping (and therefore the height) is
        // measured at the wrong width.
        let contentWidth = scrollView.contentSize.width
        if contentWidth > 0 {
            container.containerSize = NSSize(
                width: contentWidth, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
    }
}
