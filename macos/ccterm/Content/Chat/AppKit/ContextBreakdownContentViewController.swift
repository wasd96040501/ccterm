import AgentSDK
import AppKit
import Observation

/// AppKit replacement for `ContextRingButton.ContextPopoverContent` (migration
/// plan §4.2, §4.2-8). Renders the context breakdown (when `session.contextUsage`
/// is present) or a fetching placeholder, then the always-visible summary
/// section. Fires `requestContextUsage()` ONCE per open from `viewWillAppear`
/// (matching SwiftUI `.onAppear`), guarded by a per-open `didRequest` flag.
///
/// A re-armed `withObservationTracking` scope over `{contextUsage,
/// isFetchingContextUsage}` reconciles breakdown-vs-fetching-vs-summary while the
/// popover is open; torn down on `stopObserving()` (called from the picker's
/// `popoverDidBecomeHidden`).
@MainActor
final class ContextBreakdownContentViewController: NSViewController {

    static let popoverWidth: CGFloat = 360

    private let session: Session
    private var didRequest = false
    private var observationActive = false

    private let rootStack = NSStackView()
    private let summaryRing = ProgressRingLayer(percent: 0, size: 22)
    private let usageLineLabel = NSTextField(labelWithString: "")
    private let percentLineLabel = NSTextField(labelWithString: "")

    init(session: Session) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        // Pin the reused summaryRing's 22×22 size ONCE. `addSummary()` runs on
        // every reconcile() (per observe() onChange while the popover is open),
        // so re-activating these two self-referential constraints there would
        // stack duplicate identical constraints on the same long-lived view
        // (constraint churn / slow leak). The width/height are appearance- and
        // session-independent, so init is the right home.
        summaryRing.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            summaryRing.widthAnchor.constraint(equalToConstant: 22),
            summaryRing.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)

        // outerPadding 6 (ContextRingButton popover .padding(PopoverList.outerPadding)).
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: PopoverListMetrics.outerPadding),
            rootStack.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -PopoverListMetrics.outerPadding),
            rootStack.topAnchor.constraint(
                equalTo: root.topAnchor, constant: PopoverListMetrics.outerPadding),
            rootStack.bottomAnchor.constraint(
                equalTo: root.bottomAnchor, constant: -PopoverListMetrics.outerPadding),
            root.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
        ])

        view = root
        reconcile()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Once-per-open request (§4.2-8 — matches SwiftUI `.onAppear`).
        requestIfNeeded()
        startObserving()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopObserving()
    }

    private func requestIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        session.requestContextUsage()
    }

    // MARK: - Observation (per-open scope, re-armed; §4.2-8)

    private func startObserving() {
        observationActive = true
        observe()
    }

    func stopObserving() {
        observationActive = false
    }

    private func observe() {
        withObservationTracking {
            _ = session.contextUsage
            _ = session.isFetchingContextUsage
            _ = session.contextUsedTokens
            _ = session.contextWindowTokens
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.observationActive else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    // MARK: - Reconcile (breakdown vs fetching vs summary)

    private func reconcile() {
        rootStack.arrangedSubviews.forEach {
            rootStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if let usage = session.contextUsage {
            addBreakdown(usage)
            addDivider()
        } else if session.isFetchingContextUsage {
            addFetchingPlaceholder()
            addDivider()
        }
        addSummary()

        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let height = rootStack.fittingSize.height + 2 * PopoverListMetrics.outerPadding
        preferredContentSize = NSSize(width: Self.popoverWidth, height: max(height, 1))
    }

    // MARK: - Breakdown (header + bar + rows + expandable groups)

    private func addBreakdown(_ usage: ContextUsage) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header: "Context window" (size 13 medium) + summary (size 11 secondary).
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        let title = NSTextField(labelWithString: String(localized: "Context window"))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        let used = ContextTokenFormat.format(usage.totalTokens)
        let max = ContextTokenFormat.format(usage.rawMaxTokens)
        let summary = NSTextField(labelWithString: "\(used) / \(max) (\(usage.percentage)%)")
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(summary)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Bar track (Phase-0 ContextBarView).
        let bar = ContextBarView(usage: usage)
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bar)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.heightAnchor.constraint(equalToConstant: ContextBarView.barHeight),
        ])

        // Category rows.
        let ordered = ContextBarLayout.ordered(usage)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for (idx, cat) in ordered.enumerated() {
            let rank = ContextBarLayout.rankInActive(ordered: ordered, at: idx)
            let row = makeCategoryRow(cat, rankInActive: rank, rawMaxTokens: usage.rawMaxTokens)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(rows)
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Expandable groups: Memory files / MCP tools / Custom agents.
        if !usage.memoryFiles.isEmpty {
            stack.addArrangedSubview(
                ExpandableGroupView(
                    label: String(localized: "Memory files"),
                    totalTokens: usage.memoryFiles.reduce(0) { $0 + $1.tokens },
                    count: usage.memoryFiles.count,
                    rows: usage.memoryFiles.map { ($0.path, $0.tokens) },
                    onToggle: { [weak self] in self?.reflowAfterGroupToggle() }))
        }
        if !usage.mcpTools.isEmpty {
            stack.addArrangedSubview(
                ExpandableGroupView(
                    label: String(localized: "MCP tools"),
                    totalTokens: usage.mcpTools.reduce(0) { $0 + $1.tokens },
                    count: usage.mcpTools.count,
                    rows: usage.mcpTools.map { ("\($0.serverName) · \($0.name)", $0.tokens) },
                    onToggle: { [weak self] in self?.reflowAfterGroupToggle() }))
        }
        if !usage.agents.isEmpty {
            stack.addArrangedSubview(
                ExpandableGroupView(
                    label: String(localized: "Custom agents"),
                    totalTokens: usage.agents.reduce(0) { $0 + $1.tokens },
                    count: usage.agents.count,
                    rows: usage.agents.map { ($0.agentType, $0.tokens) },
                    onToggle: { [weak self] in self?.reflowAfterGroupToggle() }))
        }

        // padding horizontal 12 / top 2 (ContextBreakdownView.body).
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        rootStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private func reflowAfterGroupToggle() {
        view.layoutSubtreeIfNeeded()
        let height = rootStack.fittingSize.height + 2 * PopoverListMetrics.outerPadding
        preferredContentSize = NSSize(width: Self.popoverWidth, height: max(height, 1))
    }

    private func makeCategoryRow(
        _ cat: ContextUsage.Category, rankInActive: Int, rawMaxTokens: Int
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.translatesAutoresizingMaskIntoConstraints = false
        let kind = ContextBarLayout.segmentKind(for: cat, rankInActive: rankInActive)
        swatch.layer?.backgroundColor = ContextBarView.color(for: kind).cgColor
        swatch.layer?.cornerRadius = 2
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 8),
            swatch.heightAnchor.constraint(equalToConstant: 8),
        ])

        let name = NSTextField(labelWithString: cat.name)
        name.font = .systemFont(ofSize: 12)
        name.textColor = cat.isDeferred ? .secondaryLabelColor : .labelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tokens = NSTextField(labelWithString: ContextTokenFormat.format(cat.tokens))
        tokens.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tokens.textColor = .secondaryLabelColor

        let pctText: String
        if rawMaxTokens > 0 {
            pctText = String(format: "%.1f%%", Double(cat.tokens) / Double(rawMaxTokens) * 100)
        } else {
            pctText = "0%"
        }
        let pct = NSTextField(labelWithString: pctText)
        pct.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pct.textColor = .secondaryLabelColor
        pct.alignment = .right
        pct.translatesAutoresizingMaskIntoConstraints = false
        pct.widthAnchor.constraint(equalToConstant: 44).isActive = true

        row.addArrangedSubview(swatch)
        row.addArrangedSubview(name)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(tokens)
        row.addArrangedSubview(pct)
        return row
    }

    // MARK: - Fetching placeholder

    private func addFetchingPlaceholder() {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: String(localized: "Loading context breakdown…"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        row.addArrangedSubview(spinner)
        row.addArrangedSubview(label)

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
        ])
        rootStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    // MARK: - Divider (h12/v8)

    private func addDivider() {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            wrapper.topAnchor.constraint(equalTo: line.topAnchor, constant: -8),
            wrapper.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: 8),
        ])
        rootStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    // MARK: - Summary (always visible)

    private func addSummary() {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        summaryRing.translatesAutoresizingMaskIntoConstraints = false
        summaryRing.percent = currentPercent

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        usageLineLabel.stringValue =
            "\(ContextTokenFormat.format(session.contextUsedTokens)) / "
            + "\(ContextTokenFormat.format(session.contextWindowTokens))"
        usageLineLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        usageLineLabel.textColor = .labelColor
        percentLineLabel.stringValue = String(
            format: String(localized: "%lld%% used"), Int(currentPercent.rounded()))
        percentLineLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLineLabel.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(usageLineLabel)
        textStack.addArrangedSubview(percentLineLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(summaryRing)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(spacer)

        // padding h (PopoverList.horizontalInset + 2) / top 2 / bottom 6.
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        let h = PopoverListMetrics.horizontalInset + 2
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: h),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -h),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6),
        ])
        rootStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private var currentPercent: Double {
        let total = Double(session.contextWindowTokens)
        guard total > 0 else { return 0 }
        return min(max(Double(session.contextUsedTokens) / total * 100, 0), 100)
    }
}

/// Expandable Memory-files / MCP-tools / Custom-agents group (chevron header +
/// inner rows), mirroring `ContextRingButton.ExpandableGroup`. Chevron size 9.
final class ExpandableGroupView: NSView {

    private let onToggle: () -> Void
    private var isOpen = false
    private let chevron = NSImageView()
    private let innerStack = NSStackView()
    private let rows: [(String, Int)]

    init(label: String, totalTokens: Int, count: Int, rows: [(String, Int)], onToggle: @escaping () -> Void) {
        self.rows = rows
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let headerButton = ExpandableHeaderRow(onClick: { [weak self] in self?.toggle() })
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = Self.chevronImage(open: false)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .labelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tokensField = NSTextField(labelWithString: ContextTokenFormat.format(totalTokens))
        tokensField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tokensField.textColor = .secondaryLabelColor

        let countField = NSTextField(labelWithString: "\(count)")
        countField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        header.addArrangedSubview(chevron)
        header.addArrangedSubview(labelField)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(tokensField)
        header.addArrangedSubview(countField)
        headerButton.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerButton.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor),
        ])
        outer.addArrangedSubview(headerButton)
        headerButton.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 2
        innerStack.isHidden = true
        outer.addArrangedSubview(innerStack)
        innerStack.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        buildInnerRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    private func buildInnerRows() {
        for (name, tokens) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let indent = NSView()
            indent.translatesAutoresizingMaskIntoConstraints = false
            indent.widthAnchor.constraint(equalToConstant: 10).isActive = true
            let nameField = NSTextField(labelWithString: name)
            nameField.font = .systemFont(ofSize: 11)
            nameField.textColor = .secondaryLabelColor
            nameField.lineBreakMode = .byTruncatingMiddle
            nameField.maximumNumberOfLines = 1
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let tokensField = NSTextField(labelWithString: ContextTokenFormat.format(tokens))
            tokensField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tokensField.textColor = .secondaryLabelColor
            let trailing = NSView()
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.widthAnchor.constraint(equalToConstant: 44).isActive = true
            row.addArrangedSubview(indent)
            row.addArrangedSubview(nameField)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(tokensField)
            row.addArrangedSubview(trailing)
            innerStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }
    }

    private func toggle() {
        isOpen.toggle()
        chevron.image = Self.chevronImage(open: isOpen)
        innerStack.isHidden = !isOpen
        onToggle()
    }

    private static func chevronImage(open: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        return NSImage(
            systemSymbolName: open ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

/// Clickable header row for an expandable group (whole-row click toggles).
final class ExpandableHeaderRow: NSView {
    private let onClick: () -> Void
    /// Stateful press tracking (NOT a `nextEvent` pump) so the runloop keeps
    /// draining dispatch / Observation / CoreAnimation work between drag events.
    private var isPressInside = false
    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    nonisolated deinit {}
    override func mouseDown(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard isPressInside else { return }
        isPressInside = false
        onClick()
    }
}
