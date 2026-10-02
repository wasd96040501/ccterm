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
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The settings a New tab opens with.
    func settings(catalog: ModelCatalog) -> SessionSettings? {
        // TODO(fill B): the saved settings, else the CLI's own from `catalog.subscription`.
        nil
    }

    /// Saves `settings` as the next New tab's.
    func save(_ settings: SessionSettings) {
        // TODO(fill B)
    }
}
