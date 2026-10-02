import AgentSDK
import Combine
import Foundation

extension TranscriptTab {
    /// What the feature's tabs read and talk to — the window's read-only
    /// dependency manifest for them, built once at the composition root and
    /// passed through unchanged. Each controller reads only the members it
    /// uses: a document only `sessions`; a session tab all of it.
    @MainActor
    struct Context {
        /// The one door to every session, at rest or live.
        let sessions: SessionStore
        /// What each account's CLI offers, for the composer's menus. Delivers
        /// on the main actor.
        let catalog: AnyPublisher<ModelCatalog, Never>
        /// General's launch settings (Allow Bypass Permissions). Delivers on
        /// the main actor.
        let preferences: AnyPublisher<LaunchPreferences, Never>
        /// A New tab's starting model, effort, mode and Fast Mode.
        let defaults: NewSessionDefaults
        /// A folder's branches, for the New view's branch row.
        let branches: BranchService
        /// The sidebar's projects, most recent first — the New view's folder
        /// menu (*Recent*, eight at most) and a New tab's default folder.
        /// Delivers on the main actor.
        let recentFolders: AnyPublisher<[URL], Never>
    }
}
