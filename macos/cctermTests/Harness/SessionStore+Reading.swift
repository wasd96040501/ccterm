import AgentSDK
import Combine
import Foundation

@testable import ccterm

extension SessionStore {
    /// A store that only reads — every session at rest, through `read` —
    /// as a tab under test needs it. Starting a session from it fails: it has
    /// no launch.
    static func reading(
        _ read: @escaping @Sendable (URL) async throws -> Transcript = { try Transcript(contentsOf: $0) }
    ) -> SessionStore {
        SessionStore(
            configurations: Empty().eraseToAnyPublisher(), directories: Empty().eraseToAnyPublisher(), read: read)
    }
}
