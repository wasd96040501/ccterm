import AppKit

/// AppKit replacement for `BoundedHeightScrollView { DiffView(...) }` as used by
/// the diff-family permission card bodies — `PermissionShellCardBody.swift:34-43`,
/// `PermissionFileWriteCardBody.swift:45-55`, `PermissionSedEditCardBody.swift:34-42`.
///
/// Embeds the already-AppKit `DiffNSView` DIRECTLY (UNWRAP — the SwiftUI
/// `DiffView` / `DiffViewBridge` are dropped), in a height-capped vertical
/// `NSScrollView`. Constants lifted verbatim:
/// - diff chrome flags: `showsLangBadge = false`, `showsCopyIcon = false`
///   (`PermissionShellCardBody.swift:41-42`, etc.)
/// - height cap = 240pt for all three diff-family bodies
///   (`PermissionShellCardBody.commandMaxHeight`,
///   `PermissionFileWriteCardBody.diffMaxHeight`,
///   `PermissionSedEditCardBody.diffMaxHeight`)
/// - scroll indicators hidden (`BoundedHeightScrollView.swift:30`
///   `showsIndicators: false`)
/// - inner content leading-aligned, full width (`BoundedHeightScrollView.swift:32`)
///
/// **Bounded-height behavior (plan §4.4-7).** Reproduces
/// `min(content.idealHeight, maxHeight)`: after the enclosing card is
/// constraint-laid-out (`layoutSubtreeIfNeeded`), read
/// `DiffNSView.height(at: settledWidth)` (`DiffView.swift:228-230` →
/// `DiffLayout.totalHeight`) and clamp the scroll view height to
/// `min(that, cap)`; re-clamp on width change (user-paced pane resize).
/// `DiffNSView.intrinsicContentSize` returns `noIntrinsicMetric` until its
/// width-keyed cache is primed at the current `bounds.width`
/// (`DiffView.swift:241-250`) — so we measure via `height(at:)` (which primes
/// the cache at the requested width), never via a pre-layout intrinsic read.
///
/// **Highlight Task (plan §4.4-6, ported from `DiffView.runHighlight`,
/// `DiffView.swift:51-72`).** This view OWNS the `highlightBatch` Task: on
/// construct it kicks `Task { let map = await engine.highlightBatch(payload);
/// if !Task.isCancelled { diffView.update(lineMap: map) } }`, reproducing the
/// post-await `if Task.isCancelled { return }` guard and capturing `diffView`
/// weakly. `engine` reaches it by property (`DetailContext.syntaxEngine`), NOT
/// `@Environment`. The Task is cancelled on teardown
/// (`removeFromSuperview` / explicit `stop()`) — the card dismiss is
/// opacity-only (D5) and the view may be visible-but-dismissing, so cancellation
/// is tied to removal, not deinit timing.
///
/// The embedded `DiffNSView` keeps its OWN selection / copy-button / `.pointingHand`
/// cursor rect (`DiffView.swift:365-370`) — this host MUST NOT suppress
/// descendant cursor rects (plan §4.4-2: only the full-pane card layer view is
/// cursor-rect-free).
final class PermissionBoundedDiffView: NSView {

    // MARK: - Constants (verbatim from the diff-family bodies)

    /// Height cap for all three diff-family bodies (240pt).
    static let defaultMaxHeight: CGFloat = 240

    // MARK: - Public

    let maxHeight: CGFloat
    let diff: DiffBlock

    /// The syntax engine (from `DetailContext.syntaxEngine`). Passed by
    /// property, not `@Environment`.
    weak var engine: SyntaxHighlightEngine?

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    let diffView = DiffNSView()

    private var heightConstraint: NSLayoutConstraint!
    private var diffWidthConstraint: NSLayoutConstraint!
    private var lastMeasuredWidth: CGFloat = -1

    // MARK: - Highlight Task

    private var highlightTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - diff: the already-resolved `DiffBlock` (FileWrite / SedEdit do their
    ///     synchronous FS read at build time in the body builder — this view
    ///     never reads the filesystem, plan §4.4-5).
    ///   - engine: the syntax engine for the highlight pass (may be nil — then
    ///     the diff renders un-highlighted, matching `DiffView.runHighlight`'s
    ///     `guard let engine`).
    ///   - maxHeight: per-caller cap (240pt for all diff-family callers).
    init(diff: DiffBlock, engine: SyntaxHighlightEngine?, maxHeight: CGFloat = defaultMaxHeight) {
        self.diff = diff
        self.engine = engine
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        configureScrollView()

        diffView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = diffView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: maxHeight)
        // Non-required so an over-tall demand never leaks into the host's
        // fittingSize (plan R1); the cap is satisfied at high priority.
        heightConstraint.priority = .defaultHigh

        // Pin the diff document to the scroll's content width so it wraps /
        // typesets at the settled width; its height comes from `height(at:)`.
        diffWidthConstraint = diffView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
            diffView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            diffView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            diffWidthConstraint,
        ])

        // Render the diff once, un-highlighted (highlight arrives via the Task).
        diffView.update(
            diff: diff, lineMap: nil, showsLangBadge: false, showsCopyIcon: false)

        startHighlight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`. The highlight
    /// Task is cancelled deterministically in `stop()` / `removeFromSuperview`,
    /// not here (deinit timing is unreliable while a card is mid-dismiss, D5).
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The current resolved (clamped) height of the scroll view —
    /// `min(diffView.height(at: settledWidth), maxHeight)`.
    var resolvedHeight: CGFloat { heightConstraint.constant }

    /// Whether the highlight Task is still alive (un-cancelled). Tests assert it
    /// is cancelled after teardown.
    var isHighlightTaskRunning: Bool { highlightTask != nil && highlightTask?.isCancelled == false }

    /// Set `true` once the highlight Task has run its non-cancelled writeback
    /// (re-rendered `diffView` with the resolved `lineMap` and re-clamped). The
    /// observable signal the writeback path actually completed — distinct from
    /// "the un-highlighted diff laid out", which happens synchronously in
    /// `layout()` before any highlight arrives. Cancellation short-circuits
    /// before this flips, so a torn-down view never reports a writeback.
    private(set) var highlightDidWriteBack = false

    // MARK: - Configuration

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay  // native overlay scrollers
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
    }

    // MARK: - Layout — clamp to min(height(at: settledWidth), cap)

    override func layout() {
        super.layout()
        clampHeightIfNeeded()
    }

    /// Re-clamp the scroll view height to `min(diffView.height(at: width), cap)`
    /// at the settled content width. Only re-measures when the width actually
    /// changed (the §4.4-7 re-clamp on pane resize).
    private func clampHeightIfNeeded() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if width == lastMeasuredWidth { return }
        lastMeasuredWidth = width
        // `height(at:)` primes DiffNSView's width-keyed layout cache at `width`
        // and returns DiffLayout.totalHeight — the value we clamp.
        let natural = diffView.height(at: width)
        heightConstraint.constant = min(natural, maxHeight)
    }

    // MARK: - Highlight Task (ported verbatim from DiffView.runHighlight)

    private func startHighlight() {
        guard let engine else { return }
        let diff = self.diff
        highlightTask = Task { @MainActor [weak self, weak engine] in
            guard let engine else { return }
            let lang = LanguageDetection.language(for: diff.filePath)
            var seen = Set<String>()
            var unique: [String] = []
            for line in diff.lines where !line.isEmpty {
                if seen.insert(line).inserted { unique.append(line) }
            }
            guard !unique.isEmpty else { return }
            let payload = unique.map { ($0, lang) }
            let results = await engine.highlightBatch(payload)
            // The already-issued `highlightBatch` runs to completion on the
            // actor; drop the writeback on cancellation so a stale highlight
            // can't overtake a torn-down view (DiffView.swift:66).
            if Task.isCancelled { return }
            guard let self else { return }
            var map: [String: [SyntaxToken]] = [:]
            for (content, tokens) in zip(unique, results) {
                map[content] = tokens
            }
            self.diffView.update(
                diff: diff, lineMap: map, showsLangBadge: false, showsCopyIcon: false)
            // The highlighted layout may differ in height; re-clamp.
            self.lastMeasuredWidth = -1
            self.needsLayout = true
            self.highlightDidWriteBack = true
        }
    }

    /// Cancel the highlight Task. Called from the card's teardown
    /// (`prepareForRemoval`) and on `removeFromSuperview` so a stale
    /// `highlightBatch` writeback can't land on a dismissing view (plan §4.4-6
    /// Task-lifetime risk).
    func stop() {
        highlightTask?.cancel()
        highlightTask = nil
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
