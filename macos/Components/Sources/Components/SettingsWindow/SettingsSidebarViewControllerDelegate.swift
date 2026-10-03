import Foundation

@MainActor
protocol SettingsSidebarViewControllerDelegate: AnyObject {
    /// The person picked a pane, by clicking or with the arrow keys: its
    /// index.
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect pane: Int)
}
