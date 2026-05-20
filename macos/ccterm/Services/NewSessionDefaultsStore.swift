import AgentSDK
import Foundation

/// User-level memory for a fresh "New Session" card's model + permission
/// mode, persisted across launches in `UserDefaults`.
///
/// Per-model effort is handled by [[EffortDefaultStore]] (keyed by model
/// value). Model and permission mode are global — the user picks them
/// once, and the next New Session starts from those values regardless of
/// which project / sessionId comes up.
///
/// Writes only fire while the session is still a `.draft`; the pickers
/// gate on `session.draft != nil` before calling `setModel` /
/// `setPermissionMode` here. Reads only fire when constructing /
/// surfacing a fresh draft (picker backfill paths) — `.active` sessions
/// keep restoring from their `SessionRecord`.
@MainActor
final class NewSessionDefaultsStore {
    static let shared = NewSessionDefaultsStore()

    private let defaults: UserDefaults
    private static let modelKey = "newSession.lastModel"
    private static let permissionModeKey = "newSession.lastPermissionMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var model: String? {
        defaults.string(forKey: Self.modelKey)
    }

    func setModel(_ value: String) {
        defaults.set(value, forKey: Self.modelKey)
    }

    var permissionMode: PermissionMode? {
        guard let raw = defaults.string(forKey: Self.permissionModeKey) else { return nil }
        return PermissionMode(rawValue: raw)
    }

    func setPermissionMode(_ mode: PermissionMode) {
        defaults.set(mode.rawValue, forKey: Self.permissionModeKey)
    }
}
