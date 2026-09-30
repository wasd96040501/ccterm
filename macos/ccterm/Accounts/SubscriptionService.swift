import AgentSDK
import Combine
import Foundation

/// The CLI's claude.ai login, kept current: reads it, signs in through the
/// browser, signs out. Publishes where that stands. The login belongs to the
/// CLI as it is launched, so it is read again whenever the launch changes.
@MainActor
final class SubscriptionService {
    enum State: Equatable {
        /// Not read yet.
        case unknown
        case signedOut
        /// Waiting for the person to approve in the browser; the page's URL
        /// once the CLI has printed it.
        case signingIn(URL?)
        case signedIn(Subscription)
    }

    @Published private(set) var state: State = .unknown

    private let auth: SubscriptionAuth
    /// How the CLI is launched now.
    private var configuration = CLIConfiguration()
    private var configurationsSubscription: AnyCancellable?
    private var signInTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?

    /// `configurations`: how the CLI is launched, now and each time it
    /// changes; must deliver on the main actor. Each distinct one starts a new
    /// read of the login.
    init(auth: SubscriptionAuth, configurations: AnyPublisher<CLIConfiguration, Never>) {
        self.auth = auth
        configurationsSubscription = configurations.removeDuplicates().sink { [weak self] configuration in
            MainActor.assumeIsolated { self?.launchDidChange(to: configuration) }
        }
    }

    /// Reads the login again.
    func refresh() async {
        readTask?.cancel()
        let task = Task { await read() }
        readTask = task
        await task.value
    }

    /// Starts signing in; the state stays ``State/signingIn(_:)`` until the
    /// browser flow ends or ``cancelSignIn()``.
    func signIn() {
        guard !isSigningIn else { return }
        state = .signingIn(nil)
        let configuration = configuration
        signInTask = Task { [weak self, auth] in
            do {
                for try await url in auth.signIn(configuration) {
                    self?.state = .signingIn(url)
                }
            } catch is CancellationError {
                return
            } catch {
                appLog(.warning, "SubscriptionService", "sign-in failed — \(error.localizedDescription)")
            }
            guard let self, !Task.isCancelled else { return }
            signInTask = nil
            state = .unknown
            await refresh()
        }
    }

    /// Stops waiting for the browser; the login stays as it was.
    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        guard isSigningIn else { return }
        state = .unknown
        Task { await refresh() }
    }

    func signOut() async throws {
        try await auth.signOut(configuration)
        state = .signedOut
    }

    /// The launch changed: what was read no longer describes it.
    private func launchDidChange(to next: CLIConfiguration) {
        configuration = next
        signInTask?.cancel()
        signInTask = nil
        if state != .unknown { state = .unknown }
        readTask?.cancel()
        readTask = Task { await read() }
    }

    /// Reads the login for the launch as it is now; an answer for a launch
    /// that has since changed is dropped.
    private func read() async {
        let launched = configuration
        do {
            let subscription = try await auth.current(launched)
            guard !Task.isCancelled, launched == configuration, !isSigningIn else { return }
            state = subscription.map(State.signedIn) ?? .signedOut
        } catch is CancellationError {
            return
        } catch {
            appLog(.warning, "SubscriptionService", "status failed — \(error.localizedDescription)")
            guard !Task.isCancelled, launched == configuration else { return }
            if state == .unknown { state = .signedOut }
        }
    }

    private var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }
}
