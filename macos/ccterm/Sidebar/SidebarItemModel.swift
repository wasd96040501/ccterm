import Foundation

/// Heterogeneous nodes the sidebar's `NSOutlineView` walks. Reference
/// type so `NSOutlineView`'s identity-based row reuse (it keys on
/// `===`) stays stable across `reloadData()` calls.
///
/// Two-level hierarchy:
/// - Root contains fixed nodes (top tabs) and folder nodes (grouped
///   project history).
/// - Folder nodes contain history nodes; fixed and history nodes have
///   no children.
final class SidebarItemNode {
    enum Kind {
        /// Fixed top-of-sidebar tab (New Session, Archive, DEBUG demos).
        case fixed(FixedKind)
        /// A folder header — grouping parent that contains history rows.
        case folder(name: String)
        /// History entry inside a folder.
        case history(sessionId: String, fallbackTitle: String)
    }

    let kind: Kind
    /// Selection tag for fixed items / history rows. `nil` for folders
    /// (folders are non-selectable; click toggles expand/collapse).
    let selectionTag: String?
    /// Children — non-empty only for folder nodes.
    var children: [SidebarItemNode]

    init(kind: Kind, selectionTag: String?, children: [SidebarItemNode] = []) {
        self.kind = kind
        self.selectionTag = selectionTag
        self.children = children
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var folderName: String? {
        if case .folder(let name) = kind { return name }
        return nil
    }
}

/// Each fixed top item identifies itself with a stable kind so the
/// row's icon + title + tag fall out of the same case.
enum FixedKind: CaseIterable {
    case newSession
    case archive
    #if DEBUG
    case transcriptDemo
    case transcriptStress
    case transcriptPerf
    case permissionCardsDemo
    case permissionSessionDemo
    #endif

    /// English source string for the row label. SwiftUI literals are
    /// wrapped in `String(localized:)` so the catalog lookup runs at
    /// the view layer. Non-DEBUG strings are localized; DEBUG-only
    /// demo names stay as English literals.
    var title: String {
        switch self {
        case .newSession: return String(localized: "New Session")
        case .archive: return String(localized: "Archive")
        #if DEBUG
        case .transcriptDemo: return "Transcript Demo"
        case .transcriptStress: return "Transcript Stress"
        case .transcriptPerf: return "Transcript Perf"
        case .permissionCardsDemo: return "Permission Cards Demo"
        case .permissionSessionDemo: return "Permission Session Demo"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: return "square.and.pencil"
        case .archive: return "archivebox"
        #if DEBUG
        case .transcriptDemo: return "doc.text.image"
        case .transcriptStress: return "speedometer"
        case .transcriptPerf: return "waveform.path.ecg"
        case .permissionCardsDemo: return "hand.raised.fill"
        case .permissionSessionDemo: return "hand.raised.app.fill"
        #endif
        }
    }

    var selectionTag: String {
        switch self {
        case .newSession: return SidebarSentinel.newSession
        case .archive: return SidebarSentinel.archive
        #if DEBUG
        case .transcriptDemo: return SidebarSentinel.transcriptDemo
        case .transcriptStress: return SidebarSentinel.transcriptStress
        case .transcriptPerf: return SidebarSentinel.transcriptPerf
        case .permissionCardsDemo: return SidebarSentinel.permissionCardsDemo
        case .permissionSessionDemo: return SidebarSentinel.permissionSessionDemo
        #endif
        }
    }
}
