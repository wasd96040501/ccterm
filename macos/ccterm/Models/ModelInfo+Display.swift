import AgentSDK
import Foundation

extension ModelInfo {
    /// Concise display string for the model picker. The CLI returns
    /// human labels like `"Opus 4.7 (1M context)"` and `"Default
    /// (recommended)"`; this trims the marketing noise so rows match
    /// Claude.app's tighter typography.
    ///
    /// Strategy is purely transformational on `displayName` — no
    /// hardcoded model list — so a future model release that uses a
    /// new naming scheme falls back unchanged instead of vanishing
    /// from the picker:
    ///
    /// 1. Replace `" (1M context)"` with the compact `" 1M"` suffix.
    /// 2. Drop `" (recommended)"` and any other `" (…)"` chunk.
    /// 3. If the trimmed result is a bare family name
    ///    (`Sonnet` / `Haiku` / `Opus`) and `value` decomposes as
    ///    `claude-<family>-<v1>-<v2>[-…]`, append `<v1>.<v2>` so
    ///    `Sonnet` reads as `Sonnet 4.6`.
    /// 4. Empty / unchanged result → fall back to the raw
    ///    `displayName` so a CLI update can't blank the row.
    var conciseDisplayName: String {
        var name = displayName.replacingOccurrences(of: " (1M context)", with: " 1M")
        name = Self.stripParens(name).trimmingCharacters(in: .whitespaces)

        let families: Set<String> = ["Sonnet", "Haiku", "Opus"]
        if families.contains(name), let version = Self.parseFamilyVersion(value) {
            name = "\(name) \(version)"
        }

        return name.isEmpty ? displayName : name
    }

    /// Remove every `" (…)"` segment. Picks up `(recommended)`,
    /// `(beta)`, `(preview)`, etc. without enumerating them. The 1M
    /// substitution runs first because its replacement should survive.
    /// Regex failure (shouldn't happen) leaves the input untouched.
    private static func stripParens(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s*\([^)]*\)"#) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(
            in: s, range: range, withTemplate: "")
    }

    /// `claude-sonnet-4-6` → `"4.6"`. Returns nil for any value that
    /// doesn't follow the `claude-<family>-<digit>-<digit>` shape; the
    /// caller leaves the bare family name in place rather than guess.
    private static func parseFamilyVersion(_ value: String) -> String? {
        let parts = value.split(separator: "-")
        guard parts.count >= 4, parts[0] == "claude" else { return nil }
        guard Int(parts[2]) != nil, Int(parts[3]) != nil else { return nil }
        return "\(parts[2]).\(parts[3])"
    }
}
