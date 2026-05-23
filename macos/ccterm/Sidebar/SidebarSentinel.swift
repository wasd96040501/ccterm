import Foundation

/// Sentinel selection values used by the sidebar. Real session ids are
/// UUIDs, so the double-underscore prefix is reserved for these tabs.
///
/// Lives outside the view layer so `MainSelectionModel`,
/// `MainWindowController`, and `TranscriptDetailViewController` can
/// reach the constants without depending on the sidebar implementation.
enum SidebarSentinel {
    static let newSession = "__new_session__"
    static let archive = "__archive__"
    #if DEBUG
    static let transcriptDemo = "__transcript_demo__"
    static let transcriptStress = "__transcript_stress__"
    static let transcriptPerf = "__transcript_perf__"
    static let permissionCardsDemo = "__permission_cards_demo__"
    static let permissionSessionDemo = "__permission_session_demo__"
    #endif

    /// Every sentinel tag, in selection order. Used by the
    /// `MainWindowController` to discriminate "real history session"
    /// from "tab pane".
    static let all: Set<String> = {
        var tags: Set<String> = [newSession, archive]
        #if DEBUG
        tags.formUnion([
            transcriptDemo, transcriptStress, transcriptPerf,
            permissionCardsDemo, permissionSessionDemo,
        ])
        #endif
        return tags
    }()
}
