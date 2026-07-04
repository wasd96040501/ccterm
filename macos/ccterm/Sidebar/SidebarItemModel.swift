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
        /// Fixed top-of-sidebar tab (New Session, Archive).
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
///
/// DEBUG demo entries (Transcript Demo / Transcript Stress /
/// Permission Cards Demo / …) were removed as part of the AppKit-
/// skeleton refactor: every demo VC is SwiftUI-heavy and cannot be
/// mounted by the new detail router. They will be reintroduced
/// case-by-case as their bodies are ported to AppKit.
enum FixedKind: CaseIterable {
    case newSession
    case archive

    /// English source string for the row label. Both entries are
    /// user-visible, so both are localized.
    var title: String {
        switch self {
        case .newSession: return String(localized: "New Session")
        case .archive: return String(localized: "Archive")
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: return "square.and.pencil"
        case .archive: return "archivebox"
        }
    }

    var selection: MainSelection {
        switch self {
        case .newSession: return .newSession
        case .archive: return .archive
        }
    }
}
