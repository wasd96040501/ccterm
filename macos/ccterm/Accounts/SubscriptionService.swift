import Combine
import Foundation

/// The CLI's claude.ai login, kept current: reads it, signs in through the
/// browser, signs out. Publishes where that stands.
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
    private var signInTask: Task<Void, Never>?

    init(auth: SubscriptionAuth) {
        self.auth = auth
    }

    /// Reads the login again.
    func refresh() async {
        do {
            let subscription = try await auth.current()
            guard !isSigningIn else { return }
            state = subscription.map(State.signedIn) ?? .signedOut
        } catch {
            appLog(.warning, "SubscriptionService", "status failed — \(error.localizedDescription)")
            if state == .unknown { state = .signedOut }
        }
    }

    /// Starts signing in; the state stays ``State/signingIn(_:)`` until the
    /// browser flow ends or ``cancelSignIn()``.
    func signIn() {
        guard !isSigningIn else { return }
        state = .signingIn(nil)
        signInTask = Task { [weak self, auth] in
            do {
                for try await url in auth.signIn() {
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
        try await auth.signOut()
        state = .signedOut
    }

    private var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }
}
