import AgentSDK
import Foundation

/// What a New tab starts on: the model, effort, mode and Fast Mode last
/// chosen in a New tab (design 08 *Defaults*), kept in the user's defaults.
/// Before any choice, the CLI's own — `Default (recommended)` on the
/// subscription, the model's default effort, the catalog's
/// `current_permission_mode` — which is why `settings(catalog:)` asks the
/// catalog. *Default* follows the CLI's setting rather than pinning a model.
///
/// A choice in a New tab is saved as it is made, not at Send; a session tab's
/// choices are the session's and don't touch it.
@MainActor
final class NewSessionDefaults {
    private static let key = "newSessionSettings"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The settings a New tab opens with: the last chosen, else the CLI's own
    /// from the subscription's catalog; `nil` while no account is known to
    /// say. A saved model whose account is gone (Settings removed the
    /// provider) is the subscription's *Default* again.
    func settings(catalog: ModelCatalog) -> SessionSettings? {
        let fallback = catalog.subscription ?? catalog.accounts.first
        if let data = defaults.data(forKey: Self.key),
            var saved = try? JSONDecoder().decode(SessionSettings.self, from: data)
        {
            if let fallback, catalog.account(saved.model.account) == nil {
                saved.model = .default(on: fallback.id)
            }
            return saved
        }
        guard let fallback else { return nil }
        return SessionSettings(
            model: .default(on: fallback.id), effort: nil, permissionMode: fallback.defaultPermissionMode ?? .default,
            fastMode: false)
    }

    /// Saves `settings` as the next New tab's.
    func save(_ settings: SessionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
