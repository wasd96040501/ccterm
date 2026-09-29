import Foundation

/// One variable an account sets for the CLI. A disabled one is kept but not
/// set.
nonisolated struct EnvironmentVariable: Codable, Equatable, Sendable {
    var isEnabled = true
    var name: String
    var value: String

    /// A name as the shell would take it: upper case, spaces as underscores.
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(
            of: #"\s+"#, with: "_", options: .regularExpression)
    }

    /// Whether the value is likely a secret, by its name — shown masked.
    var isSecretLike: Bool {
        name.range(of: "KEY|TOKEN|SECRET|PASSWORD", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
