import AppKit
import Observation

// MARK: - Folder / probe glue + draft setters

extension NewSessionConfiguratorViewController {

    /// Folder selection entry point used by BOTH the recents-row click AND the
    /// `NSOpenPanel` OK (plan §4.6-2). Writes the draft as a PAIR:
    /// `setCwd(path)` THEN `setOriginPath(path)` — dropping the pairing silently
    /// breaks `submitSessionInput`'s `markLaunched` + worktree pre-fill (MAJOR).
    /// Pass `nil` to clear (a removed current folder).
    func selectFolder(_ path: String?) {
        if let path {
            session.draft?.setCwd(path)
            session.draft?.setOriginPath(path)
        } else {
            // Clearing the picked folder (remove-current-from-recents). The
            // SwiftUI binding dropped nil writes silently; the AppKit port models
            // the clear as a first-class draft capability (plan §4.6-5).
            session.draft?.clearCwd()
            session.draft?.setOriginPath(nil)
        }
        applyFolderChange(resetOverride: true)
        refreshRightColumn()
    }

    /// The `.task(id: folderPath)` analogue (plan §4.6-3, R10), run imperatively
    /// on every folder change: (1) `probe.refresh` synchronous; (2)
    /// `applyProbeBindings` synchronous; (3) `await probe.loadHeavy`; (4)
    /// post-await stale-branch reconcile.
    func applyFolderChange(resetOverride: Bool) {
        let path = folderPath
        probe.refresh(folderPath: path)
        applyProbeBindings(resetOverride: resetOverride)
        refreshMetaRow()

        heavyProbeTask?.cancel()
        heavyProbeTask = Task { [weak self] in
            guard let self else { return }
            await self.probe.loadHeavy(folderPath: path)
            guard !Task.isCancelled else { return }
            // Post-loadHeavy stale-branch reconcile (verbatim, :196-200): if
            // sourceBranch set, branches non-empty, and !branches.contains → fall
            // back to currentBranch.
            if let sb = self.session.sourceBranch, !self.probe.branches.isEmpty,
                !self.probe.branches.contains(sb)
            {
                self.session.draft?.setSourceBranch(self.probe.currentBranch)
            }
            self.refreshMetaRow()
        }
    }

    /// `applyProbeBindings(resetOverride:)` ported VERBATIM
    /// (`NewSessionConfigurator.swift:709-740`).
    func applyProbeBindings(resetOverride: Bool) {
        guard let path = folderPath else {
            session.draft?.setWorktree(false)
            session.draft?.setSourceBranch(nil)
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            recents.remove(path)
            session.draft?.clearCwd()
            session.draft?.setOriginPath(nil)
            session.draft?.setWorktree(false)
            session.draft?.setSourceBranch(nil)
            return
        }
        if probe.isGitRepo {
            if resetOverride || session.sourceBranch == nil {
                session.draft?.setSourceBranch(probe.currentBranch)
            }
            if probe.currentBranch == nil {
                session.draft?.setWorktree(false)
            } else {
                session.draft?.setWorktree(recents.useWorktree(for: path) ?? false)
            }
        } else {
            session.draft?.setWorktree(false)
            session.draft?.setSourceBranch(nil)
        }
    }

    // MARK: - Folder picker / context-menu actions

    @objc func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder for the new session")
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.recents.add(url.path)
            self.selectFolder(url.path)
        }
    }

    /// Reveal in Finder (`revealInFinder`, :686-689).
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Remove from recents (`removeFromRecents`, :691-696): drop the entry, and
    /// if it is the current folder clear it to nil.
    func removeFromRecents(_ path: String) {
        recents.remove(path)
        if folderPath == path {
            selectFolder(nil)
        }
    }

    // MARK: - Worktree menu (D7: NSButton + NSMenu, closest visual match)

    @objc func showWorktreeMenu() {
        let menu = NSMenu()
        let local = NSMenuItem(
            title: String(localized: "Local"), action: #selector(selectLocal), keyEquivalent: "")
        local.target = self
        local.state = session.isWorktree ? .off : .on
        let worktree = NSMenuItem(
            title: String(localized: "New Worktree"), action: #selector(selectWorktree),
            keyEquivalent: "")
        worktree.target = self
        worktree.state = session.isWorktree ? .on : .off
        // Reserve the leading checkmark gutter on BOTH items so the unselected
        // row's label doesn't shift left when its checkmark is absent — this is
        // exactly the misalignment the SwiftUI inline `Picker` was chosen to
        // avoid (`NewSessionConfigurator.swift:498-510`). NSMenu collapses the
        // state-image column for an `.off` item with no `offStateImage`; giving
        // both items a transparent off-state glyph the size of the checkmark
        // keeps the column width fixed across selection states (D7).
        let gutter = Self.menuStateGutterImage
        local.offStateImage = gutter
        worktree.offStateImage = gutter
        menu.addItem(local)
        menu.addItem(worktree)
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: worktreeButton.bounds.height), in: worktreeButton)
    }

    /// A transparent image matched to the menu checkmark's size, used as the
    /// `offStateImage` so the leading state-image gutter stays reserved on the
    /// unselected worktree item (D7 — labels stay vertically aligned).
    private static let menuStateGutterImage: NSImage = {
        // The system checkmark in a menu is ~12pt; reserve the same column.
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    @objc func selectLocal() { setWorktree(false) }
    @objc func selectWorktree() { setWorktree(true) }

    /// Worktree write (plan §4.6 / D7): Local→false / New Worktree→true.
    func setWorktree(_ isWorktree: Bool) {
        session.draft?.setWorktree(isWorktree)
        refreshMetaRow()
    }

    // MARK: - Branch picker

    @objc func showBranchPicker() {
        // Re-entry guard: a second click while a popover is already open (or
        // re-opened before the prior fully closed) would orphan the previous
        // popover — its only strong reference (`branchPopover`) is overwritten
        // without `performClose`. Close + nil any existing one first (the
        // SwiftUI original bound one `@State` bool to one `.popover`, so the
        // re-trigger was idempotent — `NewSessionConfigurator.swift:554`).
        if let existing = branchPopover {
            existing.performClose(nil)
            branchPopover = nil
        }

        // Capture the firstResponder + deterministically end any IME composition
        // in the embedded bar before the .transient popover steals key-window
        // (plan §4.2-1 / §4.6-8, R13); restore it on popoverDidClose.
        savedBranchResponder = view.window?.firstResponder
        let barTextView = inputBarController.barView.textView
        if barTextView.hasMarkedText() {
            barTextView.inputContext?.discardMarkedText()
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        // Capture the popover BY VALUE in the onSelect closure so Confirm /
        // double-click always closes ITS OWN popover, never a stale
        // `self.branchPopover` that a later reassignment may have replaced.
        let picker = BranchPickerViewController(
            branches: probe.branches,
            currentBranch: probe.currentBranch,
            remoteMainBranch: probe.remoteMainBranch,
            currentBranchStatus: probe.currentBranchStatus,
            onSelect: { [weak self, weak pop] selected in
                self?.setSourceBranch(selected)
                pop?.performClose(nil)
            })
        pop.contentViewController = picker
        branchPopover = pop
        pop.show(relativeTo: branchButton.bounds, of: branchButton, preferredEdge: .maxY)
    }

    /// Source branch write (plan §4.6, :194-197).
    func setSourceBranch(_ branch: String?) {
        session.draft?.setSourceBranch(branch)
        refreshMetaRow()
    }

    // MARK: - Right-column refresh

    /// Re-render the hero + subtitle + meta row + recent-sessions list from the
    /// current draft + probe state.
    func refreshRightColumn() {
        refreshHero()
        refreshMetaRow()
        reloadRecentSessions()
    }

    func refreshHero() {
        if let name = pickedFolderName {
            titleProjectLabel.stringValue = name
            titleProjectLabel.isHidden = false
        } else {
            titleProjectLabel.stringValue = ""
            titleProjectLabel.isHidden = true
        }
        if let path = folderPath {
            subtitleLabel.stringValue = abbreviatedPath(path)
        } else {
            subtitleLabel.stringValue = String(localized: "Pick a project on the left to begin.")
        }
    }

    func refreshMetaRow() {
        let visible = branchVisible
        metaRow.isHidden = !visible
        // Collapse the meta row's vertical slot when hidden by re-anchoring the
        // divider to the subtitle (a hidden plain NSView still holds its frame,
        // so a static metaRow-anchored divider would leave a dead gap — matching
        // the SwiftUI `if branchVisible { metaRow }` structural removal).
        if visible {
            dividerTopFromSubtitle?.isActive = false
            dividerTopFromMeta?.isActive = true
        } else {
            dividerTopFromMeta?.isActive = false
            dividerTopFromSubtitle?.isActive = true
        }
        // Worktree pill.
        worktreeButton.configure(
            symbolName: session.isWorktree ? "folder.badge.plus" : "folder",
            title: session.isWorktree
                ? String(localized: "New Worktree") : String(localized: "Local"))
        // Branch pill.
        branchButton.configure(symbolName: "arrow.triangle.branch", title: displayBranch)
    }
}

// MARK: - Reactive list refresh (self-re-arming withObservationTracking)

extension NewSessionConfiguratorViewController {

    /// Self-re-arming observation of `recents.entries` → `reloadRecents()`
    /// (the `Transcript2SheetPresenter` pattern, plan §4.6-4, R11). Without it a
    /// `+`-added folder never appears.
    func startRecentsObservation() {
        recentsObservationActive = true
        observeRecents()
    }

    private func observeRecents() {
        withObservationTracking {
            _ = recents.entries
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.recentsObservationActive else { return }
                self.reloadRecents()
                self.observeRecents()
            }
        }
    }

    func startRecordsObservation() {
        recordsObservationActive = true
        observeRecords()
    }

    private func observeRecords() {
        withObservationTracking {
            _ = sessionManager.records
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.recordsObservationActive else { return }
                self.reloadRecentSessions()
                self.observeRecords()
            }
        }
    }

    /// Re-read `recents.entries` (lazily — first read defers the TCC prompt) and
    /// reload the recents table; reflect the empty-vs-populated state.
    func reloadRecents() {
        let previous = recentEntries
        recentEntries = recents.entries
        let isEmpty = recentEntries.isEmpty
        emptyRecentsContainer.isHidden = !isEmpty
        recentsScrollView.isHidden = isEmpty
        recentsBottomScrim.isHidden = isEmpty
        recentsTableView.reloadData()
        // Prepend (add/markLaunched insert at 0): scroll the new first row to
        // visible (plan §4.6-4). Detect a genuine front-insert.
        if let first = recentEntries.first, previous.first?.path != first.path,
            !recentEntries.isEmpty
        {
            recentsTableView.scrollRowToVisible(0)
        }
        // Restore selection to the current folder (folderPathSelection guard,
        // :334-341 — a list rebuild must never nil folderPath; the selection is
        // set-only, driven by folderPath, not the reverse).
        syncRecentsSelection()
    }

    private func syncRecentsSelection() {
        guard let folder = folderPath,
            let idx = recentEntries.firstIndex(where: { $0.path == folder })
        else {
            recentsTableView.deselectAll(nil)
            return
        }
        recentsTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    }

    /// Reload the "Recent Sessions" list from `recentSessionsForFolder`.
    func reloadRecentSessions() {
        recentSessionRecords = recentSessionsForFolder
        let isEmpty = recentSessionRecords.isEmpty
        recentSessionsScrollView.isHidden = isEmpty
        recentSessionsEmptyLabel.isHidden = !isEmpty
        if isEmpty {
            recentSessionsEmptyLabel.stringValue =
                folderPath == nil
                ? String(localized: "Pick a project to see its history.")
                : String(localized: "No recent sessions for this project.")
        }
        recentSessionsTableView.reloadData()
    }
}

// MARK: - Recents context menu

extension NewSessionConfiguratorViewController {

    func makeRecentsContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let reveal = NSMenuItem(
            title: String(localized: "Reveal in Finder"), action: #selector(revealClickedRecent),
            keyEquivalent: "")
        reveal.target = self
        let remove = NSMenuItem(
            title: String(localized: "Remove from Recents"), action: #selector(removeClickedRecent),
            keyEquivalent: "")
        remove.target = self
        menu.addItem(reveal)
        menu.addItem(remove)
        return menu
    }

    private func clickedRecentPath() -> String? {
        let row = recentsTableView.clickedRow
        guard row >= 0, row < recentEntries.count else { return nil }
        return recentEntries[row].path
    }

    @objc private func revealClickedRecent() {
        guard let path = clickedRecentPath() else { return }
        revealInFinder(path)
    }

    @objc private func removeClickedRecent() {
        guard let path = clickedRecentPath() else { return }
        removeFromRecents(path)
    }
}

extension NewSessionConfiguratorViewController: NSMenuDelegate {}

// MARK: - Branch popover delegate (firstResponder restore)

extension NewSessionConfiguratorViewController: NSPopoverDelegate {

    func popoverDidClose(_ notification: Notification) {
        branchPopover = nil
        // Restore the firstResponder the popover stole on open (plan §4.2-1 /
        // §4.6-8, R13), guarded on the window still being attached and the saved
        // responder still living in it.
        defer { savedBranchResponder = nil }
        if let window = view.window, let saved = savedBranchResponder,
            window.firstResponder !== saved
        {
            window.makeFirstResponder(saved)
        }
    }
}

// MARK: - Table data sources / delegate

extension NewSessionConfiguratorViewController {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === recentsTableView { return recentEntries.count }
        if tableView === recentSessionsTableView { return recentSessionRecords.count }
        return 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    )
        -> NSView?
    {
        if tableView === recentsTableView {
            guard row < recentEntries.count else { return nil }
            let entry = recentEntries[row]
            let cell =
                (tableView.makeView(withIdentifier: RecentProjectRowView.identifier, owner: self)
                    as? RecentProjectRowView) ?? RecentProjectRowView()
            cell.identifier = RecentProjectRowView.identifier
            cell.configure(name: entry.name, abbreviatedPath: abbreviatedPath(entry.path))
            return cell
        }
        if tableView === recentSessionsTableView {
            guard row < recentSessionRecords.count else { return nil }
            let record = recentSessionRecords[row]
            let cell =
                (tableView.makeView(withIdentifier: ResumeRowView.identifier, owner: self)
                    as? ResumeRowView) ?? ResumeRowView()
            cell.identifier = ResumeRowView.identifier
            let title = record.title.isEmpty ? String(localized: "Untitled") : record.title
            cell.configure(title: title, relativeTime: Self.compactRelative(from: record.lastActiveAt))
            return cell
        }
        return nil
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        // Recent-sessions list is button-like (no selection highlight).
        tableView !== recentSessionsTableView
    }

    @objc func recentRowClicked() {
        let row = recentsTableView.clickedRow
        guard row >= 0, row < recentEntries.count else { return }
        selectFolder(recentEntries[row].path)
    }

    @objc func recentSessionRowClicked() {
        let row = recentSessionsTableView.clickedRow
        guard row >= 0, row < recentSessionRecords.count else { return }
        onResumeSession(recentSessionRecords[row].sessionId)
    }
}
