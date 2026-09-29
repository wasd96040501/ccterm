import Foundation

/// The part of an ``Account`` that is kept in the keychain: the provider's
/// credential, and the environment variables — people paste keys for other
/// services into them.
nonisolated struct AccountSecrets: Codable, Equatable, Sendable {
    /// The token or API key; empty for the subscription.
    var credential = ""
    var environment: [EnvironmentVariable] = []
}
