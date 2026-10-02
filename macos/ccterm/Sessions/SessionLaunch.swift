import Foundation

/// Everything a New tab's Send launches with: where Claude works and on what
/// settings. A value — the New tab's draft becomes one at Send and hands it
/// to `SessionStore.start(_:prompt:)`.
nonisolated struct SessionLaunch: Sendable, Equatable {
    /// The folder chosen in the New view: the session's `cwd`, or the
    /// repository a worktree is made from.
    var folder: URL
    var checkout: Checkout
    var settings: SessionSettings
}
