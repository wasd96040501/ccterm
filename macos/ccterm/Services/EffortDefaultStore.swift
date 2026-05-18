import AgentSDK
import Foundation
import Observation

/// Per-model effort memory, persisted across launches in `UserDefaults`.
///
/// CLI sends back the catalog of supported effort levels per model
/// (`ModelInfo.supportedEffortLevels`) but never tells us which one is
/// "default" — that's a UI concern. Two layers:
///
///   1. First-time defaults (`firstTimeDefault(for:)`) for the values
///      we know about: `default` (Opus 4.7) → `xhigh`, `sonnet` → `high`.
///      Other values fall through to `high`, matching ccmaster's
///      `getDefaultEffortLevelForOption` final fallback.
///   2. After the user picks an effort, `remember(_:for:)` stores it under
///      the model's `value`. The next time that model is the active one,
///      `effort(for:)` returns the remembered choice instead of the
///      first-time default.
///
/// Both layers are clamped to the model's declared
/// `supportedEffortLevels` — a stored value from a previous CLI release
/// can't make the picker surface an unsupported level.
@MainActor
final class EffortDefaultStore {
    static let shared = EffortDefaultStore()

    private let defaults: UserDefaults
    private static let keyPrefix = "effortFor:"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Effort to surface when the user opens the picker for `model`.
    /// Returns nil when the model itself declares no effort support —
    /// the popover hides the section in that case.
    func effort(for model: ModelInfo) -> Effort? {
        guard model.supportsEffort == true else { return nil }
        let supported: [Effort] = (model.supportedEffortLevels ?? [])
            .compactMap(Effort.init(rawValue:))
        let candidate = remembered(forValue: model.value) ?? Self.firstTimeDefault(for: model.value)
        if !supported.isEmpty, !supported.contains(candidate) {
            return supported.first
        }
        return candidate
    }

    /// Persist the user's last picked effort for this model.
    func remember(_ effort: Effort, for modelValue: String) {
        defaults.set(effort.rawValue, forKey: Self.keyPrefix + modelValue)
    }

    /// First-time seed used until the user picks one explicitly.
    /// Public so tests can pin the table.
    static func firstTimeDefault(for modelValue: String) -> Effort {
        switch modelValue {
        case "default": return .xhigh
        case "sonnet": return .high
        default: return .high
        }
    }

    private func remembered(forValue value: String) -> Effort? {
        guard let raw = defaults.string(forKey: Self.keyPrefix + value) else { return nil }
        return Effort(rawValue: raw)
    }
}
