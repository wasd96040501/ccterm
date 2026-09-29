import Foundation

@MainActor
protocol SettingsSplitViewControllerDelegate: AnyObject {
    /// A pane is shown — the first as the content loads, then one picked in
    /// the sidebar or reached by back or forward.
    func settingsSplitViewController(_ split: SettingsSplitViewController, didShow pane: SettingsPane)
}
