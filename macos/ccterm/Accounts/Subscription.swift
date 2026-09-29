import Foundation

/// The claude.ai account the CLI is signed in with.
nonisolated struct Subscription: Equatable, Sendable {
    var email: String
    var organization: String?
    /// The plan as the CLI names it — `"max"`, `"pro"`, …
    var plan: String?
    /// How the login was made — `"claude.ai"`, …
    var method: String?

    /// The plan as the product names it — “Max”.
    var planName: String? {
        plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}
