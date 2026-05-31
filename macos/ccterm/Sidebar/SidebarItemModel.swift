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
        /// History entry inside a folder. `isDraft` is a snapshot of the
        /// record's `.draft` status taken when the tree is built, so the cell
        /// can render the "not yet sent" marker without a per-row lookup
        /// (durable across restart, where the row isn't a cached `Session`).
        case history(sessionId: String, fallbackTitle: String, isDraft: Bool)
    }

    let kind: Kind
    /// `MainSelection` this row represents when selected. `nil` for
    /// folders (folders are non-selectable; click toggles expand/collapse).
    let selection: MainSelection?
    /// Children — non-empty only for folder nodes.
    var children: [SidebarItemNode]

    init(kind: Kind, selection: MainSelection?, children: [SidebarItemNode] = []) {
        self.kind = kind
        self.selection = selection
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

    var selection: MainSelection {
        switch self {
        case .newSession: return .newSession
        case .archive: return .archive
        #if DEBUG
        case .transcriptDemo: return .demo(.transcript)
        case .transcriptStress: return .demo(.transcriptStress)
        case .transcriptPerf: return .demo(.transcriptPerf)
        case .permissionCardsDemo: return .demo(.permissionCards)
        case .permissionSessionDemo: return .demo(.permissionSession)
        #endif
        }
    }
}
