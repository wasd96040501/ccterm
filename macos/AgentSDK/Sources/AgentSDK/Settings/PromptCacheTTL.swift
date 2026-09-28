import Foundation

/// How long prompt-cache entries live (``SettingsKey/promptCacheTTL``).
/// Longer entries cost more to write and stay warm across longer pauses.
public enum PromptCacheTTL: String, SettingsValue, CaseIterable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}
