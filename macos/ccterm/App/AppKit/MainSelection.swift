import Foundation

/// What the sidebar currently has selected. Replaces the prior "stringly
/// typed" `selectedSessionId: String?` whose values were either a real
/// session UUID or one of the `SidebarSentinel.*` placeholder strings
/// (`__new_session__`, `__archive__`, …).
///
/// The string flavor leaked into every consumer: each had to remember
/// to compare against a sentinel before using the value as a session id,
/// and a forgotten check meant code happily called
/// `prepareDraftSession("__archive__")` and rendered chat chrome on top
/// of the Archive page. The enum makes "is this a real session or a tab"
/// a type-level question the compiler enforces at every switch.
///
/// `Equatable` so `withObservationTracking` change detection on the
/// holding `MainSelectionModel` works the same way it did with the
/// prior `String?` field.
enum MainSelection: Equatable {
    /// Nothing selected. The sidebar can land here via
    /// `outlineView.deselectAll(_:)` (e.g. clicking a folder header,
    /// which is non-selectable). Detail pane shows nothing.
    case none
    /// "New Session" tab. Detail pane shows the compose configurator.
    case newSession
    /// A real session row in the sidebar history list. Detail pane
    /// shows the transcript + chat input bar.
    case session(String)
    /// The "Archive" tab. Detail pane shows `ArchiveView` only —
    /// no input bar, no compose card.
    case archive
    #if DEBUG
    /// One of the DEBUG-only demo tabs. Detail pane shows the demo's
    /// own VC, no input bar.
    case demo(DemoKind)
    #endif
}

#if DEBUG
/// Stable identity for each DEBUG demo tab. The raw string is what
/// shows up in logs / fixtures; the enum itself drives the selection
/// switch in `ChatSessionViewController.sideBranchKind(for:)`.
enum DemoKind: String, CaseIterable, Equatable {
    case transcript
    case transcriptStress
    case transcriptPerf
    case permissionCards
    case permissionSession
}
#endif
