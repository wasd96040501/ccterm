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
    /// `outlineView(_:heightOfRowByItem:)`. Numbers reproduce the prior
    /// SwiftUI sidebar's *rendered* row pitch (≈ 32pt across all rows
    /// on macOS Sonoma — SwiftUI's `.listStyle(.sidebar)` overrides
    /// `listRowInsets` with its own minimum cell padding, so even the
    /// 1pt top/bottom inset the old code asked for on history rows
    /// came out at ~32pt in practice).
    static let fixedRowHeight: CGFloat = 32
    static let folderRowHeight: CGFloat = 36
    static let historyRowHeight: CGFloat = 30

    /// 14pt — matches what SwiftUI's `.listStyle(.sidebar)` renders rows
    /// at on macOS Sonoma. `NSFont.systemFont(ofSize: NSFont.systemFontSize)`
    /// (13pt) looks visibly smaller next to the SwiftUI version.
    static let titleFont = NSFont.systemFont(ofSize: 14)
    static let iconFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let chevronFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    /// Pasteboard type used by folder-row drag-and-drop. Folder names
    /// (project leaf names) are short strings, so the payload is just
    /// the name written as a string.
    static let folderDragType = NSPasteboard.PasteboardType("dev.ccterm.sidebar.folder")
}
