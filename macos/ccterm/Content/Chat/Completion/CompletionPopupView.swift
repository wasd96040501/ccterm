import AppKit

/// AppKit replacement for `CompletionListView` (migration plan §4.3): an
/// in-bar `NSScrollView` + a flipped document `NSStackView` of lean
/// `CompletionRowView`s. NOT an `NSPanel` (so first-responder stays on the
/// text view) and NOT an `NSTableView` (≤10 visible rows never virtualize, so
/// no competing selection model / header-pseudo-row headache).
///
/// Driven IMPERATIVELY by `InputBarController` via `reconcile(state:)` — it is
/// NOT a `@Bindable` observer. `selectedIndex` / nav are imperative; the
/// controller observes only `items` arrival (the async provider callback) and
/// calls `reconcile` after every consumed nav/confirm key. The header and the
/// empty/loading/no-directory placeholders render as FIXED views, NOT rows, so
/// `numberOfRows == items.count` and `selectedIndex` maps 1:1 to a row
/// (§4.3-2, the load-bearing invariant gated by `CompletionPopupReconcileTests`).
///
/// SIZING (R1): `intrinsicContentSize` is `.zero` so the inner content can
/// never leak a height up and pump the bar host; the popup's height is a
/// `@required` constraint the controller (or `reconcile`) sets from
/// `CompletionListLayout.listHeight(...)`. The bar re-sums and invalidates
/// explicitly.
final class CompletionPopupView: NSView {

    // MARK: - Subviews

    /// Header row (`folder.badge.questionmark` + headerText), shown only in
    /// branches B1/B4-with-header. A FIXED view above the scroll, not a row.
    private let headerView = HeaderRowView()
    /// The empty/loading/no-directory placeholder, a FIXED view (not a row)
    /// shown when `items.isEmpty` and no header (branches B2/B3).
    private let emptyView = EmptyRowView()
    private let scrollView = NSScrollView()
    /// Flipped so rows lay out top-down. The items stack ONLY — header/empty
    /// live outside it so `numberOfRows == items.count`.
    private let rowStack = FlippedStackView()

    // MARK: - Height

    /// The `@required` height constraint set per `reconcile` from
    /// `CompletionListLayout.listHeight(...)`. The inner content never drives
    /// `intrinsicContentSize` (R1).
    private var heightConstraint: NSLayoutConstraint!

    /// The scroll's top inset constraint. `verticalInset` when no header;
    /// `verticalInset + rowHeight` when a header is present (so the rows sit
    /// below the header band). Adjusted per `reconcile`.
    private var scrollTopConstraint: NSLayoutConstraint!

    /// The last `listHeight` computed in `reconcile`, exposed so the
    /// controller can sum it into the bar's `extraPillContentHeight`.
    private(set) var currentListHeight: CGFloat = 0

    // MARK: - Reconcile state (read by tests)

    /// The currently arranged command rows — exactly `items.count` of them
    /// (header/empty are fixed views, not rows).
    ///
    /// TEST-OBSERVATION GETTER (read-only): `private(set)`, so tests can read
    /// the arranged-row count + per-row highlight but cannot mutate the stack.
    /// It surfaces the load-bearing `numberOfRows == items.count` invariant
    /// (`CompletionPopupReconcileTests`); the row stack itself stays private.
    /// No production code reads this — do NOT add a production reader purely to
    /// justify it (matches the documented test-observation-getter precedent for
    /// `BarSurfaceView`).
    private(set) var rowViews: [CompletionRowView] = []

    /// Fired when a row is clicked (set-then-confirm, §4.3). The controller
    /// sets `completion.selectedIndex = index` then confirms.
    var onRowClicked: ((Int) -> Void)?

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        assemble()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    private func assemble() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero

        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.alignment = .leading
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rowStack
        addSubview(scrollView)

        // Header pinned to the top; empty placeholder just under the header;
        // the scroll fills below.
        headerView.topAnchor.constraint(equalTo: topAnchor, constant: CompletionListLayout.verticalInset).isActive =
            true
        headerView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        headerView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true

        emptyView.topAnchor.constraint(equalTo: topAnchor, constant: CompletionListLayout.verticalInset).isActive = true
        emptyView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        emptyView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true

        // The scroll holds the command rows. It is inset by `verticalInset` at
        // top and bottom so the reserved `2 * verticalInset` (which `listHeight`
        // adds) FRAMES the row block symmetrically — matching the SwiftUI
        // first-row `.padding(.top, verticalInset)` + last-row
        // `.padding(.bottom, verticalInset)` (CompletionListView.swift:141-142).
        // When a header is present the scroll's top drops below it by
        // `rowHeight` (the header's own height), set per `reconcile`.
        scrollTopConstraint = scrollView.topAnchor.constraint(
            equalTo: topAnchor, constant: CompletionListLayout.verticalInset)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollTopConstraint,
            scrollView.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -CompletionListLayout.verticalInset),
            rowStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
    }

    // MARK: - Sizing (R1 — never leak a height up)

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Reconcile (imperative, driven by the controller)

    /// Rebuild the row stack + header/empty from the live `CompletionState`
    /// and recompute the `@required` height. Called on `items` arrival, on
    /// every consumed nav/confirm key, and on show/hide. WRAPPED by the caller
    /// (or here) in a disabled `CATransaction` so the resize is instant
    /// (matching the SwiftUI `.animation(nil)`, §4.3).
    func reconcile(state: CompletionState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.allowsImplicitAnimation = false

        let headerText = state.headerText
        let items = state.items
        let selectedIndex = state.selectedIndex

        // Header (fixed view, NOT a row).
        if let headerText {
            headerView.configure(text: headerText)
            headerView.isHidden = false
        } else {
            headerView.isHidden = true
        }

        // Items vs empty placeholder.
        if items.isEmpty {
            // No rows. The empty placeholder shows ONLY when there is no
            // header (branches B2/B3); a header + empty is header-only (B1).
            rebuildRows([], selectedIndex: selectedIndex)
            scrollView.isHidden = true
            if headerText == nil {
                emptyView.configure(isLoading: state.isLoading, reason: state.emptyReason)
                emptyView.isHidden = false
            } else {
                emptyView.isHidden = true
            }
        } else {
            emptyView.isHidden = true
            scrollView.isHidden = false
            rebuildRows(items, selectedIndex: selectedIndex)
        }

        // Height = listHeight(...) (§4.3-5).
        let headerPresent = headerText != nil
        let count = CompletionListLayout.displayCount(
            headerPresent: headerPresent, itemCount: items.count, isLoading: state.isLoading)
        let hasDetail =
            CompletionListLayout.selectedDetail(
                items: items, selectedIndex: selectedIndex) != nil
        let listHeight = CompletionListLayout.listHeight(
            headerPresent: headerPresent, displayCount: count, hasSelectedDetail: hasDetail)
        currentListHeight = listHeight
        heightConstraint.constant = listHeight

        // When a header is shown the row block drops below it; otherwise the
        // rows sit `verticalInset` below the top (the symmetric framing the
        // SwiftUI first-row top padding gave). The reserved bottom inset is the
        // matching last-row `verticalInset`, fixed in `assemble`.
        scrollTopConstraint.constant =
            headerPresent
            ? CompletionListLayout.verticalInset + CompletionListLayout.rowHeight
            : CompletionListLayout.verticalInset

        // Flush the just-set constraints (height + scroll top) so the clip view
        // resizes BEFORE `scrollSelectedToVisible` reads its geometry. Safe to
        // run inline here — `reconcile` is already inside a disabled
        // `CATransaction`, so no implicit animation rides this layout pass.
        layoutSubtreeIfNeeded()

        // Scroll the selected row to center (the only place SwiftUI animated;
        // only matters when count > maxVisibleItems). Done synchronously here.
        scrollSelectedToVisible(selectedIndex: selectedIndex)

        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    private func rebuildRows(_ items: [any CompletionItem], selectedIndex: Int) {
        for view in rowViews { view.removeFromSuperview() }
        rowViews.removeAll(keepingCapacity: true)

        guard !items.isEmpty else { return }

        for (index, item) in items.enumerated() {
            let row = CompletionRowView(
                item: item,
                index: index,
                isSelected: index == selectedIndex,
                isFirst: index == 0,
                isLast: index == items.count - 1)
            row.onClick = { [weak self] idx in self?.onRowClicked?(idx) }
            rowStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor).isActive = true
            rowViews.append(row)
        }
    }

    private func scrollSelectedToVisible(selectedIndex: Int) {
        guard selectedIndex >= 0, selectedIndex < rowViews.count else { return }
        let row = rowViews[selectedIndex]
        // `reconcile` already ran `layoutSubtreeIfNeeded()` on `self` after
        // writing the height + scroll-top constraints, so the clip view is at
        // its FINAL size here (no stale read). Center the row in that clip.
        let clipHeight = scrollView.contentView.bounds.height
        let rowFrame = row.frame
        let targetMidY = rowFrame.midY
        var origin = targetMidY - clipHeight / 2
        let maxOrigin = max(0, rowStack.frame.height - clipHeight)
        origin = min(max(0, origin), maxOrigin)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Header row (verbatim from CompletionListView.swift:25-39)

    private final class HeaderRowView: NSView {
        private let iconView = NSImageView()
        private let textField = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            iconView.image = NSImage(
                systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            textField.font = .systemFont(ofSize: 13)
            textField.textColor = .secondaryLabelColor
            textField.maximumNumberOfLines = 1
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textField)

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: CompletionListLayout.rowHeight),
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                // HStack spacing 8 between icon and text.
                textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        nonisolated deinit {}

        func configure(text: String) { textField.stringValue = text }
    }

    // MARK: - Empty row (verbatim from CompletionListView.swift:78-110)

    private final class EmptyRowView: NSView {
        private let spinner = NSProgressIndicator()
        private let iconView = NSImageView()
        private let textField = NSTextField(labelWithString: "")
        private var spinnerLeading: NSLayoutConstraint!
        private var iconLeading: NSLayoutConstraint!
        private var textLeadingToSpinner: NSLayoutConstraint!
        private var textLeadingToIcon: NSLayoutConstraint!
        private var textLeadingToEdge: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)

            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            iconView.image = NSImage(
                systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)

            textField.font = .systemFont(ofSize: 13)
            textField.textColor = .secondaryLabelColor
            textField.maximumNumberOfLines = 1
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textField)

            spinnerLeading = spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13)
            iconLeading = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13)
            // HStack spacing 8 between leading glyph/spinner and the text.
            textLeadingToSpinner = textField.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8)
            textLeadingToIcon = textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8)
            textLeadingToEdge = textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13)

            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: CompletionListLayout.rowHeight),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                textField.centerYAnchor.constraint(equalTo: centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        nonisolated deinit {}

        /// Render the empty state matching `CompletionListView.emptyRow`
        /// (lines 78-110):
        ///   - `.loading`               → spinner + "Loading…"
        ///   - `.noMatches` + isLoading → spinner + "Loading…"
        ///   - `.noMatches`             → "No matches"
        ///   - `.noDirectory`           → glyph + "Please select a working directory first"
        func configure(isLoading: Bool, reason: CompletionState.EmptyReason) {
            // Reset.
            spinnerLeading.isActive = false
            iconLeading.isActive = false
            textLeadingToSpinner.isActive = false
            textLeadingToIcon.isActive = false
            textLeadingToEdge.isActive = false

            let showSpinner: Bool
            let showIcon: Bool
            let text: String

            switch reason {
            case .loading:
                showSpinner = true
                showIcon = false
                text = String(localized: "Loading…")
            case .noMatches:
                if isLoading {
                    showSpinner = true
                    showIcon = false
                    text = String(localized: "Loading…")
                } else {
                    showSpinner = false
                    showIcon = false
                    text = String(localized: "No matches")
                }
            case .noDirectory:
                showSpinner = false
                showIcon = true
                text = String(localized: "Please select a working directory first")
            }

            spinner.isHidden = !showSpinner
            iconView.isHidden = !showIcon
            textField.stringValue = text

            if showSpinner {
                spinnerLeading.isActive = true
                textLeadingToSpinner.isActive = true
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
                if showIcon {
                    iconLeading.isActive = true
                    textLeadingToIcon.isActive = true
                } else {
                    textLeadingToEdge.isActive = true
                }
            }
        }

        /// Stop the spinner when the popup hides (NSProgressIndicator lifecycle,
        /// §4.3 risks — a spinning indicator left running leaks CPU).
        func stopSpinner() { spinner.stopAnimation(nil) }
    }

    // MARK: - Hide/show

    /// Stop the spinner so a hidden popup doesn't leave it spinning.
    func prepareForHide() {
        emptyView.stopSpinner()
    }

    // MARK: - Flipped stack (top-down row order)

    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
        nonisolated deinit {}
    }
}
