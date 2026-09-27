import AppKit
import TranscriptKit
import TranscriptWorkspace

/// The demo's window: an editor area — two editors at most, each with tabs, each
/// tab a transcript of its own — with the tool palette floating over it.
///
/// **The one place that knows what a command means.** The menu's commands and the
/// palette's controls all arrive here and are aimed at the active editor, which
/// the area reports as the reader moves between editors. Nothing below this
/// knows a palette exists, and the palette knows no editor.
@MainActor
final class DemoWindowController: NSWindowController {

    private let area = EditorAreaViewController()
    private let palette = ToolPaletteView()

    /// For tab titles only: "Transcript 3" is the third one opened.
    private var openedEditors = 0

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TranscriptKit"
        // Narrow on purpose: reflow, column collapse and min-content wrapping are
        // all things you have to squeeze an editor to see.
        window.contentMinSize = NSSize(width: 520, height: 320)
        super.init(window: window)

        area.delegate = self
        window.contentViewController = WorkspaceRootViewController(area: area, palette: palette)
        wirePalette()

        area.activeGroup.addTabViewItem(makeTab())
        area.activeGroup.addTabViewItem(makeTab())
        area.activeGroup.selectedTabViewItemIndex = 0
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    private var activeEditor: TranscriptEditorViewController? {
        area.activeViewController as? TranscriptEditorViewController
    }

    private func makeTab() -> NSTabViewItem {
        openedEditors += 1
        let editor = TranscriptEditorViewController(title: "Transcript \(openedEditors)")
        editor.onStatusChange = { [weak self, weak editor] in
            guard let self, editor === self.activeEditor else { return }
            self.refreshPalette()
        }
        let item = NSTabViewItem(viewController: editor)
        item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        return item
    }

    // MARK: - Commands

    @objc func newTab(_ sender: Any?) {
        area.activeGroup.addTabViewItem(makeTab())
    }

    @objc func closeTab(_ sender: Any?) {
        let group = area.activeGroup
        guard group.tabViewItems.indices.contains(group.selectedTabViewItemIndex) else { return }
        group.removeTabViewItem(group.tabViewItems[group.selectedTabViewItemIndex])
    }

    @objc func togglePinnedTab(_ sender: Any?) {
        let group = area.activeGroup
        let index = group.selectedTabViewItemIndex
        guard index >= 0 else { return }
        group.setTabPinned(!group.isTabPinned(at: index), at: index)
        refreshPalette()
    }

    /// Named for Xcode's menu item rather than `selectNextTab(_:)`, which is the
    /// window's own — for window tabs — and would be answered by the window before
    /// the chain ever reached here.
    @objc func showNextTab(_ sender: Any?) { stepTab(by: 1) }
    @objc func showPreviousTab(_ sender: Any?) { stepTab(by: -1) }

    private func stepTab(by step: Int) {
        let group = area.activeGroup
        let count = group.tabViewItems.count
        guard count > 1 else { return }
        group.selectedTabViewItemIndex = (group.selectedTabViewItemIndex + step + count) % count
    }

    @objc func addEditorOnRight(_ sender: Any?) {
        area.addGroup(with: makeTab())
    }

    @objc func closeEditor(_ sender: Any?) {
        area.removeGroup(area.activeGroup)
    }

    @objc func toggleTools(_ sender: Any?) {
        palette.isCollapsed.toggle()
    }

    /// The Find menu, aimed at the active editor. Targeted here rather than sent
    /// down the responder chain, because the chain starts at the first responder —
    /// and while the find field is being typed in that is a field editor, an
    /// `NSTextView`, which answers `performTextFinderAction(_:)` itself and would
    /// swallow ⌘G.
    @objc func performFindAction(_ sender: Any?) {
        activeEditor?.performTextFinderAction(sender)
    }

    // MARK: - The palette

    private func wirePalette() {
        palette.onNewTab = { [weak self] in self?.newTab(nil) }
        palette.onCloseTab = { [weak self] in self?.closeTab(nil) }
        palette.onTogglePin = { [weak self] in self?.togglePinnedTab(nil) }
        palette.onAddEditor = { [weak self] in self?.addEditorOnRight(nil) }
        palette.onCloseEditor = { [weak self] in self?.closeEditor(nil) }
        palette.onScrollToRow = { [weak self] row, position in
            self?.activeEditor?.transcript.scrollToRow(at: row, scrollPosition: position)
        }
        palette.onPrepend = { [weak self] in self?.activeEditor?.host.prepend(5) }
        palette.onAppend = { [weak self] in self?.activeEditor?.host.append() }
        palette.onRemoveTop = { [weak self] in self?.activeEditor?.host.removeTop(3) }
        palette.onGrowFirst = { [weak self] in self?.activeEditor?.host.growFirstRow() }
        palette.onRemeasureFirst = { [weak self] in self?.activeEditor?.host.remeasureFirstRow() }
        palette.onBatch = { [weak self] in self?.activeEditor?.host.prependAndRemoveInOneBatch() }
        palette.onStream = { [weak self] in self?.activeEditor?.host.toggleStreaming(row: $0) }
        palette.onColdLoad = { [weak self] rows, prepared in
            self?.activeEditor?.host.coldLoad(rows: rows, prepared: prepared)
        }
        palette.onCancelColdLoad = { [weak self] in self?.activeEditor?.host.cancelColdLoad() }
        palette.onMaxContentWidth = { [weak self] in self?.activeEditor?.transcript.maxContentWidth = $0 }
    }

    private func refreshPalette() {
        let group = area.activeGroup
        let editor = activeEditor
        palette.configure(
            with: ToolPaletteView.Status(
                title: editor?.title ?? "",
                rows: editor?.rowCount ?? 0,
                isStreaming: editor?.isStreaming ?? false,
                coldLoad: editor?.coldLoadStatus ?? "",
                maxContentWidth: editor?.transcript.maxContentWidth ?? 720,
                isPinned: group.selectedTabViewItemIndex >= 0
                    && group.isTabPinned(at: group.selectedTabViewItemIndex),
                canAddEditor: area.groups.count < 2,
                hasEditor: editor != nil))
    }
}

extension DemoWindowController: EditorAreaViewControllerDelegate {

    func editorArea(
        _ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?
    ) {
        refreshPalette()
    }

    func editorArea(
        _ editorArea: EditorAreaViewController, willClose viewController: NSViewController
    ) {
        (viewController as? TranscriptEditorViewController)?.prepareForClose()
    }
}

extension DemoWindowController: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performFindAction(_:)):
            return activeEditor?.validateFindItem(menuItem) ?? false
        case #selector(closeTab(_:)), #selector(togglePinnedTab(_:)):
            return activeEditor != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return area.activeGroup.tabViewItems.count > 1
        case #selector(addEditorOnRight(_:)):
            return area.groups.count < 2
        case #selector(toggleTools(_:)):
            menuItem.title = palette.isCollapsed ? "Show Tools" : "Hide Tools"
            return true
        default:
            return true
        }
    }
}

/// The window's content: the editor area, with the palette floating over its
/// bottom centre.
///
/// A container of its own because the palette cannot be a subview of the area:
/// an `NSSplitView` adds each new editor as its last subview, which would put the
/// second editor over the palette.
@MainActor
private final class WorkspaceRootViewController: NSViewController {

    private let area: EditorAreaViewController
    private let palette: ToolPaletteView

    init(area: EditorAreaViewController, palette: ToolPaletteView) {
        self.area = area
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(area)
        for subview in [area.view, palette] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            area.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            area.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            area.view.topAnchor.constraint(equalTo: view.topAnchor),
            area.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            palette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            palette.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            palette.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ])
    }
}
