import Foundation

/// What the Settings window's panes read and change, built once by the
/// composition root.
@MainActor
struct SettingsContext {
    let accounts: AccountStore
    let subscription: SubscriptionService
    let launch: LaunchSettings
}
