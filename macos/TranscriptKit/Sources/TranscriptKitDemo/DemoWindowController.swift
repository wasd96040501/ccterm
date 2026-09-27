import AppKit
import TranscriptKit
import TranscriptWorkspace

/// The demo's window: an editor area — two editors at most, each with tabs, each
/// tab a transcript of its own — with the tool palette floating over it.
///
/// **The one place that knows what a command means.** The menu's items and the
/// palette's controls are the same nil-targeted actions, arriving here up the
/// responder chain and aimed at the active editor, which the area reports as the
/// reader moves between editors. `validateUserInterfaceItem(_:)` answers for both.
/// Nothing below this knows a palette exists, and the palette knows no editor.
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
        refreshPalette()
    }

    // MARK: - Transcript commands, for the active editor

    /// Scrolls to the row the palette is set to.
    @objc func scrollToRow(_ sender: ToolPaletteView) {
        let target = sender.scrollTarget
        activeEditor?.transcript.scrollToRow(at: target.row, scrollPosition: target.position)
    }

    @objc func prependRows(_ sender: Any?) { activeEditor?.host.prepend(5) }
    @objc func appendRow(_ sender: Any?) { activeEditor?.host.append() }
    @objc func removeTopRows(_ sender: Any?) { activeEditor?.host.removeTop(3) }
    @objc func growFirstRow(_ sender: Any?) { activeEditor?.host.growFirstRow() }
    @objc func remeasureFirstRow(_ sender: Any?) { activeEditor?.host.remeasureFirstRow() }
    @objc func batchMutation(_ sender: Any?) { activeEditor?.host.prependAndRemoveInOneBatch() }

    /// Streams into the palette's row, or stops the stream running.
    @objc func toggleStreaming(_ sender: ToolPaletteView) {
        activeEditor?.host.toggleStreaming(row: sender.streamRow)
    }

    @objc func coldLoadPrepared(_ sender: ToolPaletteView) {
        activeEditor?.host.coldLoad(rows: sender.coldLoadRowCount, prepared: true)
    }

    @objc func coldLoadSync(_ sender: ToolPaletteView) {
        activeEditor?.host.coldLoad(rows: sender.coldLoadRowCount, prepared: false)
    }

    @objc func cancelColdLoad(_ sender: Any?) { activeEditor?.host.cancelColdLoad() }

    @objc func changeMaxContentWidth(_ sender: ToolPaletteView) {
        activeEditor?.transcript.maxContentWidth = sender.maxContentWidth
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

    private func refreshPalette() {
        let group = area.activeGroup
        let editor = activeEditor
        palette.configure(
            with: ToolPaletteView.Status(
                isStreaming: editor?.isStreaming ?? false,
                coldLoad: editor?.coldLoadStatus ?? "",
                maxContentWidth: editor?.transcript.maxContentWidth ?? 720,
                isPinned: group.selectedTabViewItemIndex >= 0
                    && group.isTabPinned(at: group.selectedTabViewItemIndex)))
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

/// One validation for a command wherever it is issued from — a menu item or a
/// palette button — which is what makes them one command.
extension DemoWindowController: NSUserInterfaceValidations {

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(performFindAction(_:)):
            return activeEditor?.validateFindItem(item) ?? false
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return area.activeGroup.tabViewItems.count > 1
        case #selector(addEditorOnRight(_:)):
            return area.groups.count < 2
        case #selector(toggleTools(_:)):
            (item as? NSMenuItem)?.title = palette.isCollapsed ? "Show Tools" : "Hide Tools"
            return true
        case #selector(newTab(_:)), #selector(closeEditor(_:)):
            return true
        default:
            // Everything else acts on the active editor's tab.
            return activeEditor != nil
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
