import AppKit
import Components

extension SettingsSplitViewController.Pane {
    /// `pane` as the window shows it: its row, and its controller over what
    /// `context` holds.
    @MainActor
    init(_ pane: SettingsPane, context: SettingsContext) {
        let glyph: NSImage =
            switch pane {
            case .general: .settingsGear
            case .accounts: .settingsPerson
            }
        let controller: NSViewController =
            switch pane {
            case .general:
                GeneralSettingsViewController(launch: context.launch, launchCheck: context.launchCheck)
            case .accounts:
                AccountsSettingsViewController(
                    accounts: context.accounts, launch: context.launch, launchCheck: context.launchCheck,
                    subscription: context.subscription)
            }
        self.init(title: pane.title, glyph: glyph, viewController: controller)
    }
}
