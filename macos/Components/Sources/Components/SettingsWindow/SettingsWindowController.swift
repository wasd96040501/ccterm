import AppKit

/// The Settings window: 880 × 680 and not resizable, a sidebar of panes
/// beside the shown one, and a toolbar with back and forward and the pane's
/// title, as System Settings and Xcode's Settings have.
///
/// Never restored at launch (`isRestorable = false`), so the OS cannot bring
/// it back on its own; its owner creates it when it is first asked for.
public final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let splitController: SettingsSplitViewController

    /// The content size, fixed.
    static let contentSize = NSSize(width: 880, height: 680)

    /// `initial`: the index of the pane shown first.
    public init(panes: [SettingsSplitViewController.Pane], initial: Int) {
        splitController = SettingsSplitViewController(panes: panes, initial: initial)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        shouldCascadeWindows = false
        // Before the content loads: loading shows the first pane, which
        // reports its title.
        splitController.delegate = self
        window.contentViewController = splitController
        window.setContentSize(Self.contentSize)
        window.center()
        installToolbar()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "ccterm.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    /// With nothing focused the chain ends at the window and this controller;
    /// hand menu actions on to the content, which hands them to its pane.
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        splitController.supplementalTarget(forAction: action, sender: sender)
            ?? super.supplementalTarget(forAction: action, sender: sender)
    }

    /// The window's title is the pane's; the toolbar shows it past back and
    /// forward.
    private func show(_ pane: SettingsSplitViewController.Pane) {
        window?.title = pane.title
    }

    // MARK: - NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .settingsNavigation, .flexibleSpace]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        itemIdentifier == .settingsNavigation ? navigationItem() : nil
    }

    /// Back and forward as one control, as the main window's: a momentary
    /// segmented group whose segments aim at the split controller, which
    /// validates them against its history.
    private func navigationItem() -> NSToolbarItem {
        let back = String(localized: "Back", bundle: .module)
        let forward = String(localized: "Forward", bundle: .module)
        let group = NSToolbarItemGroup(
            itemIdentifier: .settingsNavigation,
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward),
            ].compactMap { $0 },
            selectionMode: .momentary, labels: [back, forward], target: splitController, action: nil)
        for (subitem, action) in zip(
            group.subitems,
            [
                #selector(SettingsSplitViewController.goBack(_:)),
                #selector(SettingsSplitViewController.goForward(_:)),
            ])
        {
            subitem.target = splitController
            subitem.action = action
        }
        group.isNavigational = true
        return group
    }
}

extension SettingsWindowController: SettingsSplitViewControllerDelegate {
    func settingsSplitViewController(
        _ split: SettingsSplitViewController, didShow pane: SettingsSplitViewController.Pane
    ) {
        show(pane)
    }
}

extension NSToolbarItem.Identifier {
    fileprivate static let settingsNavigation = NSToolbarItem.Identifier("ccterm.settings.navigation")
}
