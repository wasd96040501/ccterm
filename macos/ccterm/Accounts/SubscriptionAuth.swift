import AgentSDK
import Foundation

/// The CLI's claude.ai login, as ``SubscriptionService`` drives it. Each call
/// says how the CLI is launched; nothing is kept between them.
nonisolated protocol SubscriptionAuth: Sendable {
    /// The account signed in now; `nil` when none is.
    func current(_ configuration: CLIConfiguration) async throws -> Subscription?
    /// Signs in through the browser. Yields the sign-in page's URL once it is
    /// known, and finishes when the login is saved.
    func signIn(_ configuration: CLIConfiguration) -> AsyncThrowingStream<URL, Error>
    func signOut(_ configuration: CLIConfiguration) async throws
}

/// ``SubscriptionAuth`` over `claude auth`.
nonisolated struct CLISubscriptionAuth: SubscriptionAuth {
    func current(_ configuration: CLIConfiguration) async throws -> Subscription? {
        let status = try await Auth.status(configuration: configuration)
        guard status.isLoggedIn, status.authMethod == "claude.ai", let email = status.email else { return nil }
        return Subscription(
            email: email, organization: status.organizationName, plan: status.subscriptionType,
            method: status.authMethod)
    }

    func signIn(_ configuration: CLIConfiguration) -> AsyncThrowingStream<URL, Error> {
        Auth.login(configuration: configuration)
    }

    func signOut(_ configuration: CLIConfiguration) async throws {
        try await Auth.logout(configuration: configuration)
    }
}
