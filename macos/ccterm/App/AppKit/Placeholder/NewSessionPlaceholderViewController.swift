import AppKit

/// Placeholder mounted for `MainSelection.newSession` (and, in this
/// refactor, for draft sessions too — they share the placeholder until the
/// `DraftSessionLandingViewController` / `ComposeSessionViewController`
/// migration lands in a follow-up PR).
///
/// Subclass of `PlaceholderViewController` so `DetailFlowCoordinator` can
/// pattern-match on VC type and give each mount its own name in stack
/// traces / logs.
@MainActor
final class NewSessionPlaceholderViewController: PlaceholderViewController {
    init() {
        super.init(
            message: String(localized: "New Session not yet migrated from SwiftUI"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
