import AppKit

/// Shared layout constants for sidebar rows. Row HEIGHTS are left to
/// `NSOutlineView`'s source-list defaults — we only own the horizontal
/// rhythm (16pt icon column + 6pt gap + flexible title) and the
/// row's leading/trailing inset, so heterogeneous rows align icon-to-
/// icon and text-to-text.
enum SidebarLayout {
    /// 16pt square slot every row's leading icon occupies. History rows
    /// reserve the same slot via `SidebarStatusIndicatorView` so the
    /// title aligns with the folder header above.
    static let iconSlotWidth: CGFloat = 16
    /// Gap between icon column and title.
    static let iconTextSpacing: CGFloat = 6
    /// Leading inset before the icon column.
    static let leadingInset: CGFloat = 4
    /// Trailing inset after the title (or chevron, for folder rows).
    static let trailingInset: CGFloat = 8

    static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let iconFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let chevronFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
}
