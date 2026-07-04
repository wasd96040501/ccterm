import AppKit

/// Placeholder mounted for `MainSelection.archive`. Subclass of
/// `PlaceholderViewController` so `DetailFlowCoordinator` can pattern-
/// match on VC type and give each mount its own name in stack traces /
/// logs. The real Archive view will replace this in a follow-up PR (see
/// `docs/refactor/appkit-skeleton.md` § Follow-up PRs).
@MainActor
final class ArchivePlaceholderViewController: PlaceholderViewController {
    init() {
        super.init(
            message: String(localized: "Archive not yet migrated from SwiftUI"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
