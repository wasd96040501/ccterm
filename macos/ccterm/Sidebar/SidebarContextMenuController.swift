import AppKit

/// Owns the sidebar's right-click context menu end to end: the menu's
/// construction, its `NSMenuDelegate` per-click update, and the three menu
/// actions (Archive, "Open in", Copy Session File Path).
///
/// Extracted out of `SidebarViewController` so the VC keeps only the
/// outline-view concerns (data source / delegate, drag-and-drop, selection,
/// and the three `withObservationTracking` loops). None of the menu logic
/// touches the VC's private state — Archive routes through
/// `context.sessionManager` / `context.model`, and the VC's records / selection
/// observation loops respond to those writes and rebuild the tree. So the
/// controller needs only the `SidebarContext` plus a few closures to read the
/// outline view's current row state:
///
/// - `nodeAtRow` — `outlineView.item(atRow:) as? SidebarItemNode`.
/// - `clickedRow` — `outlineView.clickedRow` (the right-clicked row; -1 when
///   the click missed a row).
/// - `selectedRow` — `outlineView.selectedRow` (the highlighted row; used as
///   the Archive / Copy fallback when there's no `clickedRow`).
///
/// **Retention:** AppKit does not retain an `NSMenu.delegate` or an
/// `NSMenuItem.target`. Both point at this controller, so the owning VC must
/// hold a strong reference to it — otherwise the controller deallocates and
/// the menu actions silently stop firing.
@MainActor
final class SidebarContextMenuController: NSObject, NSMenuDelegate {

    private let context: SidebarContext
    private let nodeAtRow: (Int) -> SidebarItemNode?
    private let clickedRow: () -> Int
    private let selectedRow: () -> Int

    /// The assembled context menu. Built once in `init`; the VC assigns this
    /// to `outlineView.menu`. The "Open in" submenu is rebuilt on every
    /// right-click in `menuNeedsUpdate`.
    let menu: NSMenu

    /// "Open in" context-menu item. Its submenu (the per-app list) is
    /// rebuilt on every right-click in `menuNeedsUpdate`, and the item
    /// itself is disabled (greyed) when the clicked session has no
    /// openable directory on disk.
    private let openInItem = NSMenuItem(
        title: String(localized: "Open in"), action: nil, keyEquivalent: "")

    /// "Copy Session File Path" context-menu item. Held as a field so
    /// `menuNeedsUpdate` can grey it out when the clicked session has no
    /// JSONL on disk yet (same enable/disable discipline as `openInItem`).
    private let copyPathItem = NSMenuItem(
        title: String(localized: "Copy Session File Path"),
        action: #selector(copySessionFilePath(_:)),
        keyEquivalent: "")

    init(
        context: SidebarContext,
        nodeAtRow: @escaping (Int) -> SidebarItemNode?,
        clickedRow: @escaping () -> Int,
        selectedRow: @escaping () -> Int
    ) {
        self.context = context
        self.nodeAtRow = nodeAtRow
        self.clickedRow = clickedRow
        self.selectedRow = selectedRow
        self.menu = NSMenu()
        super.init()
        buildMenu()
    }

    /// macOS 26 SDK regression workaround: a default class deinit on a
    /// `@MainActor` type hops through `swift_task_deinitOnExecutorImpl`,
    /// which aborts when released outside a Swift task (a synchronous XCTest
    /// body). `nonisolated` keeps dealloc inline on the releasing thread.
    /// See `MainSelectionModel.deinit` for the full diagnosis.
    nonisolated deinit {}

    // MARK: - Menu construction

    private func buildMenu() {
        menu.delegate = self
        // Manage enabled state ourselves — the default autoenable path
        // would route through `validateMenuItem`/responder chain and
        // override the greyed-out "Open in" state we set explicitly.
        menu.autoenablesItems = false

        let archive = NSMenuItem(
            title: String(localized: "Archive"),
            action: #selector(archiveSelectedRow(_:)),
            keyEquivalent: "")
        archive.target = self
        menu.addItem(archive)

        copyPathItem.target = self
        menu.addItem(copyPathItem)

        let openInSubmenu = NSMenu()
        openInSubmenu.autoenablesItems = false
        openInItem.submenu = openInSubmenu
        menu.addItem(openInItem)
    }

    // MARK: - Path resolution

    /// Resolve the directory to open for a history session: prefer
    /// `cwd`, fall back to `originPath`. Returns nil when neither is set
    /// or the resolved path no longer exists as a directory on disk —
    /// the caller greys out "Open in" in that case.
    private func openablePath(forSessionId sessionId: String) -> String? {
        guard let record = context.sessionManager.records.first(where: { $0.sessionId == sessionId })
        else { return nil }
        guard let candidate = record.cwd ?? record.originPath, !candidate.isEmpty else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
            isDir.boolValue
        else { return nil }
        return candidate
    }

    /// On-disk path of the session's history JSONL, resolved through the
    /// same `HistoryLoader.locate` the runtime uses (CLI live file →
    /// project-dir scan). Returns nil when no JSONL
    /// exists yet — the caller greys out "Copy Session File Path".
    private func jsonlPath(forSessionId sessionId: String) -> String? {
        let slug = context.sessionManager.records.first { $0.sessionId == sessionId }?.slug
        return HistoryLoader.locate(sessionId: sessionId, slug: slug)?.path
    }

    // MARK: - "Open in" submenu

    /// Rebuild the "Open in" submenu for the clicked session. Enabled
    /// only when there's a valid directory and at least one installed
    /// app; otherwise the parent item is left disabled and the submenu
    /// empty.
    private func rebuildOpenInSubmenu(forSessionId sessionId: String) {
        let submenu = openInItem.submenu ?? NSMenu()
        submenu.removeAllItems()

        let path = openablePath(forSessionId: sessionId)
        let targets = context.openInService.targets
        openInItem.isEnabled = path != nil && !targets.isEmpty

        guard let path, !targets.isEmpty else { return }
        for target in targets {
            let item = NSMenuItem(
                title: target.name, action: #selector(openInApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = target.icon
            item.representedObject = OpenInRequest(path: path, target: target)
            submenu.addItem(item)
        }
    }

    /// Captured at submenu-build time so the action handler has both the
    /// directory and the chosen app without re-reading `clickedRow`
    /// (which is no longer valid by the time the item fires).
    private struct OpenInRequest {
        let path: String
        let target: OpenInAppService.Target
    }

    @objc private func openInApp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenInRequest else { return }
        context.openInService.open(path: request.path, with: request.target)
    }

    // MARK: - Actions

    @objc private func archiveSelectedRow(_ sender: Any?) {
        let row = clickedRow() >= 0 ? clickedRow() : selectedRow()
        guard row >= 0, let node = nodeAtRow(row) else { return }
        guard case .history(let sessionId, _, _) = node.kind else { return }
        if context.model.selection == .session(sessionId) {
            context.model.select(.newSession)
        }
        context.sessionManager.archive(sessionId)
    }

    @objc private func copySessionFilePath(_ sender: Any?) {
        let row = clickedRow() >= 0 ? clickedRow() : selectedRow()
        guard row >= 0, let node = nodeAtRow(row) else { return }
        guard case .history(let sessionId, _, _) = node.kind else { return }
        guard let path = jsonlPath(forSessionId: sessionId) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = clickedRow()
        var historySessionId: String?
        if row >= 0,
            let node = nodeAtRow(row),
            case .history(let sessionId, _, _) = node.kind
        {
            historySessionId = sessionId
        }
        let allowed = historySessionId != nil
        for item in menu.items { item.isHidden = !allowed }
        if let historySessionId {
            copyPathItem.isEnabled = jsonlPath(forSessionId: historySessionId) != nil
            rebuildOpenInSubmenu(forSessionId: historySessionId)
        }
    }
}
