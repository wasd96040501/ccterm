import Foundation

/// What the sidebar currently has selected. Replaces the prior "stringly
/// typed" `selectedSessionId: String?` whose values were either a real
/// session UUID or one of the `SidebarSentinel.*` placeholder strings
/// (`__new_session__`, `__archive__`, …). The enum makes "is this a real
/// session or a tab" a type-level question the compiler enforces at every
/// switch.
///
/// `Equatable` so `SelectionStore.$selection` (Combine `@Published`)'s
/// change filter fires only on real transitions.
///
/// `.demo(_)` was previously a DEBUG-only case for the sidebar's Transcript
/// Demo / Permission Session Demo entries. All demo VCs are SwiftUI-heavy;
/// they are excluded from the routing table for the AppKit-skeleton
/// refactor and will be re-added case-by-case once their bodies are AppKit.
enum MainSelection: Equatable {
    /// Nothing selected. The sidebar can land here via
    /// `outlineView.deselectAll(_:)` (e.g. clicking a folder header,
    /// which is non-selectable). Detail pane shows the current
    /// placeholder / empty child.
    case none
    /// "New Session" tab. Detail pane shows the new-session placeholder
    /// (compose configurator still SwiftUI, migrated in a follow-up).
    case newSession
    /// A real session row in the sidebar history list. Detail pane
    /// shows the transcript.
    case session(String)
    /// The "Archive" tab. Detail pane shows the archive placeholder
    /// (real Archive view still SwiftUI, migrated in a follow-up).
    case archive
}
