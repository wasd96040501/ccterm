import Foundation

/// What the Claude Code section reports. It saves nothing itself; the next
/// state shows what came of it.
@MainActor
public protocol LaunchSectionViewControllerDelegate: AnyObject {
    /// A keystroke in a field: its whole text now.
    func launchSection(
        _ section: LaunchSectionViewController, didEdit field: LaunchSectionViewController.Field, text: String)
    /// Return in a field, or leaving it: its text, to save if it passes.
    func launchSection(
        _ section: LaunchSectionViewController, didCommit field: LaunchSectionViewController.Field, text: String)
    /// The Allow Bypass Permissions checkbox, clicked.
    func launchSection(_ section: LaunchSectionViewController, didSetAllowsBypassPermissions allows: Bool)
}
