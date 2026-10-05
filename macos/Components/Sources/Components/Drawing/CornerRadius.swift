import AppKit

/// The design's four corner radii (design/transcript 08-live.md, *One shape
/// language*; `--r-tag` … `--r-card` in preview-live.css). Every shape a live
/// session draws takes one of them, with `cornerCurve = .continuous` and no
/// scaling. Circles (the +, the action button) and capsules stay what they
/// are; the composer's corners follow its action button (`ComposerView`).
public enum CornerRadius {
    /// The command token, tooltips.
    public static let tag: CGFloat = 5
    /// Chips, tabs, the filter field, a question's option.
    public static let control: CGFloat = 7
    /// A row inside a list: the control's less 2.
    public static let row: CGFloat = control - 2
    /// The slash list, banners.
    public static let popover: CGFloat = 12
    /// The system popover every menu opens in, as AppKit draws it on macOS 26
    /// (measured): what a menu's rows and its filter are concentric with.
    public static let systemPopover: CGFloat = 20
    /// A menu row's fill, 10 in from the popover's edge: the popover's less 10.
    public static let menuRow: CGFloat = systemPopover - 10
    /// The alert, cards.
    public static let card: CGFloat = 18
}
