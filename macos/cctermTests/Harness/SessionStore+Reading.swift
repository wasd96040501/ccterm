import AgentSDK
import Combine
import Foundation

@testable import ccterm

extension SessionStore {
    /// A store that only reads — every session at rest, through `read` —
    /// as a tab under test needs it. Starting a session from it fails: it has
    /// no account to launch.
    static func reading(
        _ read: @escaping @Sendable (URL) async throws -> Transcript = { try Transcript(contentsOf: $0) }
    ) -> SessionStore {
        SessionStore(
            launch: { _ in throw AgentSDKError.launchFailed("a reading store has no launch") },
            directories: Empty().eraseToAnyPublisher(), catalog: Empty().eraseToAnyPublisher(),
            preferences: Empty().eraseToAnyPublisher(), branches: BranchService(), read: read)
    }
}
