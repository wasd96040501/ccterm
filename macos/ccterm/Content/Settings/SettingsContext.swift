import Foundation

/// What the Settings window's panes read and change — the stores and
/// services the composition root built, handed on unchanged.
@MainActor
struct SettingsContext {
    let accounts: AccountStore
    let launch: LaunchStore
    let launchCheck: LaunchCheckService
    let subscription: SubscriptionService
}
