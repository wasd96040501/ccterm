import AgentSDK
import Foundation

/// The CLI's claude.ai login, as ``SubscriptionService`` drives it.
nonisolated protocol SubscriptionAuth: Sendable {
    /// The account signed in now; `nil` when none is.
    func current() async throws -> Subscription?
    /// Signs in through the browser. Yields the sign-in page's URL once it is
    /// known, and finishes when the login is saved.
    func signIn() -> AsyncThrowingStream<URL, Error>
    func signOut() async throws
}

/// ``SubscriptionAuth`` over `claude auth`, started with the launch command
/// set in General — the CLI whose login sessions will use.
nonisolated struct CLISubscriptionAuth: SubscriptionAuth {
    let launch: LaunchSettings

    func current() async throws -> Subscription? {
        let status = try await Auth.status(configuration: configuration)
        guard status.isLoggedIn, status.authMethod == "claude.ai", let email = status.email else { return nil }
        return Subscription(
            email: email, organization: status.organizationName, plan: status.subscriptionType,
            method: status.authMethod)
    }

    func signIn() -> AsyncThrowingStream<URL, Error> {
        Auth.login(configuration: configuration)
    }

    func signOut() async throws {
        try await Auth.logout(configuration: configuration)
    }

    private var configuration: AuthConfiguration {
        AuthConfiguration(customCommand: launch.command(for: nil))
    }
}
