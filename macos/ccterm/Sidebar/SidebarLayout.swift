import AppKit

/// Shared layout constants for sidebar rows. Heterogeneous rows share
/// the icon column geometry (16pt slot + 6pt gap) and the leading /
/// trailing insets so icons align icon-to-icon and titles align
/// text-to-text across the entire list.
///
/// `leadingInset` matches the source-list selection background's left
/// inset on macOS 14 — pushing the icon out to the inset means a
/// selected row's highlight fully encloses the icon rather than
/// letting it peek out past the rounded selection rect.
enum SidebarLayout {
    /// 16pt square slot every row's leading icon occupies.
    static let iconSlotWidth: CGFloat = 16
    /// Gap between icon column and title.
    static let iconTextSpacing: CGFloat = 6
    /// Leading inset before the icon column. Matches the source-list
    /// selection background's left inset on macOS 14 so the icon sits
    /// inside the highlight rather than spilling out the leading edge.
    static let leadingInset: CGFloat = 10
    /// Trailing inset after the title (or chevron, for folder rows).
    /// Mirrors `leadingInset` so the highlight is symmetric.
    static let trailingInset: CGFloat = 10

    /// Per-type row heights. Source-list style resets `rowHeight` after
    /// `style = .sourceList` is assigned, so we override per-row via
    /// `outlineView(_:heightOfRowByItem:)`. Numbers are picked to match
    /// the prior SwiftUI sidebar's visual rhythm:
    /// - fixed rows: comfortable click target, slight breathing room.
    /// - folder header: extra top padding for section separation.
    /// - history row: compact so projects with many sessions still scan.
    static let fixedRowHeight: CGFloat = 26
    static let folderRowHeight: CGFloat = 32
    static let historyRowHeight: CGFloat = 22

    static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let iconFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let chevronFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    /// Pasteboard type used by folder-row drag-and-drop. Folder names
    /// (project leaf names) are short strings, so the payload is just
    /// the name written as a string.
    static let folderDragType = NSPasteboard.PasteboardType("dev.ccterm.sidebar.folder")
}
