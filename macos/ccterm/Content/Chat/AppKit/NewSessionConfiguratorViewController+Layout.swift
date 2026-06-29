import AppKit
import Observation

// MARK: - View construction + layout

extension NewSessionConfiguratorViewController {

    override func loadView() {
        // Card root. `intrinsicContentSize = .zero` is published by the card
        // surface view; this controller's `view` IS the card (the surface +
        // columns), pinned by `ComposeContentView` centerX/centerY (plan R1).
        let card = GlassCardBackgroundView(cornerRadius: Self.cardCornerRadius)
        card.translatesAutoresizingMaskIntoConstraints = false

        let projects = buildProjectsColumn()
        let main = buildMainColumn()

        let columns = NSStackView(views: [projects, main])
        columns.orientation = .horizontal
        columns.spacing = 0
        columns.distribution = .fill
        columns.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(columns)

        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            columns.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
            projects.widthAnchor.constraint(equalToConstant: Self.projectsColumnWidth),
        ])

        // Embedded bar — z-overlaid bottom-anchored inside the MAIN column so an
        // open completion popup grows UPWARD over recents (plan §4.6, :411-420).
        // The configurator owns only the bar's POSITION. The bar + its chrome row
        // are stacked via `ComposeBarHostView` with the compose insets
        // (.horizontal 28 .bottom 18); unlike the chat resting bar, the compose
        // card applies NO inner width cap (the SwiftUI overlay had none).
        inputBarController.loadViewIfNeeded()
        addChild(inputBarController)
        let barHost = ComposeBarHostView(
            barView: inputBarController.barView,
            chromeRow: inputBarController.chromeRow,
            horizontalInset: 28,
            bottomInset: 18,
            barSpacing: 10)
        barHost.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(barHost)
        NSLayoutConstraint.activate([
            barHost.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            barHost.bottomAnchor.constraint(equalTo: main.bottomAnchor),
        ])

        view = card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Bind the embedded bar to the compose draft so its cwd-observation +
        // completion-prewarm re-arm against THIS draft session (plan §4.6-6,
        // the MAJOR fix): on a recents-row click the draft's cwd changes, and
        // the bar's `withObservationTracking` over `session.cwd` must be armed
        // for `submitEnabled`/prewarm to track it. Keyed on `newSessionKey` so
        // the persisted draft outlives the regenerating draftSessionId. Done
        // once here; folder changes flow through the bar's own observation
        // (no per-click rebind needed). Idempotent if the host also rebinds.
        inputBarController.rebind(
            sessionId: draftSessionId, draftKey: InputDraftStore.newSessionKey)
        // Arm the two self-re-arming list observations (recents.entries +
        // manager.records). Reading `entries` lazily on first populate preserves
        // the TCC-prompt deferral (plan §4.6-4, R11).
        startRecentsObservation()
        startRecordsObservation()
        reloadRecents()
        reloadRecentSessions()
        refreshRightColumn()
        // Drive the git probe for the seeded folder (the `.task(id:)` analogue).
        applyFolderChange(resetOverride: false)
    }

    /// Teardown hook — compose is NOT a `DetailRouterChild`, so its VC calls
    /// this from `viewWillDisappear` (plan §4.6-7, R16): cancel the heavy probe
    /// Task + close any open popover + drop the embedded bar.
    func teardown() {
        heavyProbeTask?.cancel()
        heavyProbeTask = nil
        branchPopover?.performClose(nil)
        branchPopover = nil
        savedBranchResponder = nil
        recentsObservationActive = false
        recordsObservationActive = false
        inputBarController.prepareForRemoval()
        // Symmetry with the `addChild` in `loadView` — detach the embedded bar
        // from the child-VC graph so it doesn't linger after teardown.
        inputBarController.removeFromParent()
    }

    // MARK: - Left column

    private func buildProjectsColumn() -> NSView {
        let column = TintedColumnView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Header: "Projects" eyebrow + `+` button.
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let eyebrow = Self.makeEyebrowLabel(String(localized: "Projects"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let plus = PlusHoverButton(size: Self.plusButtonSize)
        plus.onClick = { [weak self] in self?.presentFolderPicker() }
        plus.toolTip = String(localized: "Choose Folder…")
        header.addArrangedSubview(eyebrow)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(plus)
        column.addSubview(header)

        // Recents table.
        configureRecentsTable()
        recentsScrollView.translatesAutoresizingMaskIntoConstraints = false
        recentsScrollView.documentView = recentsTableView
        recentsScrollView.drawsBackground = false
        recentsScrollView.hasVerticalScroller = true
        recentsScrollView.scrollerStyle = .overlay
        recentsScrollView.autohidesScrollers = true
        recentsScrollView.hasHorizontalScroller = false
        recentsScrollView.contentInsets = NSEdgeInsetsZero
        recentsScrollView.scrollerInsets = NSEdgeInsetsZero
        column.addSubview(recentsScrollView)

        // Bottom-only fade scrim over the recents list (reuse the
        // TranscriptScrimView family, plan §4.6). bandHeight is set at init.
        recentsBottomScrim.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(recentsBottomScrim)

        // Empty state.
        buildEmptyRecents(into: column)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: column.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -16),

            recentsScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            recentsScrollView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            recentsScrollView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            recentsScrollView.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            recentsBottomScrim.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            recentsBottomScrim.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            recentsBottomScrim.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            recentsBottomScrim.heightAnchor.constraint(
                equalToConstant: Self.recentsBottomScrimHeight),

            emptyRecentsContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            emptyRecentsContainer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            emptyRecentsContainer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            emptyRecentsContainer.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        return column
    }

    private func configureRecentsTable() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        col.resizingMask = .autoresizingMask
        recentsTableView.addTableColumn(col)
        recentsTableView.headerView = nil
        recentsTableView.backgroundColor = .clear
        recentsTableView.style = .sourceList
        recentsTableView.rowHeight = 42
        recentsTableView.selectionHighlightStyle = .regular
        recentsTableView.dataSource = self
        recentsTableView.delegate = self
        recentsTableView.target = self
        recentsTableView.action = #selector(recentRowClicked)
        recentsTableView.menu = makeRecentsContextMenu()
    }

    private func buildEmptyRecents(into column: NSView) {
        emptyRecentsContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyRecentsContainer.isHidden = true
        column.addSubview(emptyRecentsContainer)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)

        let title = NSTextField(labelWithString: String(localized: "No recent projects"))
        title.font = NSFont.systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let hint = NSTextField(labelWithString: String(localized: "Tap + above to add one"))
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyRecentsContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyRecentsContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyRecentsContainer.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: emptyRecentsContainer.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: emptyRecentsContainer.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Right column

    private func buildMainColumn() -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Title row: sparkles icon + "Start Building" + project name.
        titleIcon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        titleIcon.contentTintColor = .controlAccentColor
        titleIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        titleIcon.translatesAutoresizingMaskIntoConstraints = false

        // `.title.weight(.semibold)` ≈ 22pt semibold (the title1 text style).
        let resolvedTitleFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        titleStaticLabel.font = resolvedTitleFont
        titleStaticLabel.textColor = .labelColor
        titleStaticLabel.translatesAutoresizingMaskIntoConstraints = false

        titleProjectLabel.font = resolvedTitleFont
        titleProjectLabel.textColor = .controlAccentColor
        titleProjectLabel.lineBreakMode = .byTruncatingTail
        titleProjectLabel.cell?.usesSingleLineMode = true
        titleProjectLabel.translatesAutoresizingMaskIntoConstraints = false
        titleProjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [titleIcon, titleStaticLabel, titleProjectLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(titleRow)

        // Subtitle.
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(subtitleLabel)

        // Meta row: worktree + branch pills.
        configureMetaPills()
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 4
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.addArrangedSubview(worktreeButton)
        metaRow.addArrangedSubview(branchButton)
        column.addSubview(metaRow)

        // Divider.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(divider)

        // Recent sessions eyebrow.
        let recentHeader = Self.makeEyebrowLabel(String(localized: "Recent Sessions"))
        recentHeader.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(recentHeader)

        // Recent sessions list.
        configureRecentSessionsTable()
        recentSessionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        recentSessionsScrollView.documentView = recentSessionsTableView
        recentSessionsScrollView.drawsBackground = false
        recentSessionsScrollView.hasVerticalScroller = true
        recentSessionsScrollView.scrollerStyle = .overlay
        recentSessionsScrollView.autohidesScrollers = true
        recentSessionsScrollView.contentInsets = NSEdgeInsetsZero
        recentSessionsScrollView.scrollerInsets = NSEdgeInsetsZero
        column.addSubview(recentSessionsScrollView)

        recentSessionsEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        recentSessionsEmptyLabel.textColor = .tertiaryLabelColor
        recentSessionsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(recentSessionsEmptyLabel)

        // Divider top: anchored to metaRow.bottom when the meta row is visible,
        // else to subtitle.bottom so the hidden row's slot collapses (see the
        // `dividerTop*` props + `refreshMetaRow`). Created here; toggled in
        // `refreshMetaRow` (initially meta-from constraint active).
        let fromMeta = divider.topAnchor.constraint(equalTo: metaRow.bottomAnchor, constant: 18)
        let fromSubtitle = divider.topAnchor.constraint(
            equalTo: subtitleLabel.bottomAnchor, constant: 18)
        dividerTopFromMeta = fromMeta
        dividerTopFromSubtitle = fromSubtitle

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: column.topAnchor, constant: 26),
            titleRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 28),
            titleRow.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor, constant: -28),

            subtitleLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 28),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor, constant: -28),

            // metaRow .leading (28-6=22), .top 10.
            metaRow.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            metaRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 28 - 6),

            fromMeta,
            divider.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 28),
            divider.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -28),

            recentHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            recentHeader.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 28),
            recentHeader.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -28),

            recentSessionsScrollView.topAnchor.constraint(
                equalTo: recentHeader.bottomAnchor, constant: 6),
            recentSessionsScrollView.leadingAnchor.constraint(
                equalTo: column.leadingAnchor, constant: 28),
            recentSessionsScrollView.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -28),
            recentSessionsScrollView.bottomAnchor.constraint(
                equalTo: column.bottomAnchor, constant: -Self.inputBarReservedHeight),

            recentSessionsEmptyLabel.topAnchor.constraint(
                equalTo: recentHeader.bottomAnchor, constant: 10),
            recentSessionsEmptyLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor, constant: 28),
            recentSessionsEmptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor, constant: -28),
        ])
        return column
    }

    private func configureMetaPills() {
        worktreeButton.onClick = { [weak self] in self?.showWorktreeMenu() }
        branchButton.onClick = { [weak self] in self?.showBranchPicker() }
    }

    private func configureRecentSessionsTable() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        col.resizingMask = .autoresizingMask
        recentSessionsTableView.addTableColumn(col)
        recentSessionsTableView.headerView = nil
        recentSessionsTableView.backgroundColor = .clear
        recentSessionsTableView.style = .plain
        recentSessionsTableView.rowHeight = 30
        recentSessionsTableView.intercellSpacing = NSSize(width: 0, height: 0)
        recentSessionsTableView.selectionHighlightStyle = .none
        recentSessionsTableView.dataSource = self
        recentSessionsTableView.delegate = self
        recentSessionsTableView.target = self
        recentSessionsTableView.action = #selector(recentSessionRowClicked)
    }

    private static func makeEyebrowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.textColor = .secondaryLabelColor
        // size 11 semibold uppercase tracking 0.6 (:229-232,592-598).
        label.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        return label
    }
}
