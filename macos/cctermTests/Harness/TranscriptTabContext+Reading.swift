import AgentSDK
import Combine
import Foundation

@testable import ccterm

extension TranscriptTab.Context {
    /// A context whose sessions only read (`SessionStore.reading`), with an
    /// empty catalog, General's defaults, no recent folders and its own
    /// throwaway defaults suite — what a tab under test needs.
    @MainActor static func reading(_ sessions: SessionStore? = nil) -> TranscriptTab.Context {
        TranscriptTab.Context(
            sessions: sessions ?? .reading(),
            catalog: Just(ModelCatalog()).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences()).eraseToAnyPublisher(),
            defaults: NewSessionDefaults(defaults: UserDefaults(suiteName: "ccterm-tests-\(UUID().uuidString)")!),
            branches: BranchService(),
            recentFolders: Just([]).eraseToAnyPublisher())
    }
}
