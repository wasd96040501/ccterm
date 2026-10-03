import AppKit

/// The design's four corner radii (design/transcript 08-live.md, *One shape
/// language*; `--r-tag` … `--r-card` in preview-live.css). Every shape a live
/// session draws takes one of them, with `cornerCurve = .continuous` and no
/// scaling. Circles (the +, the action button) and capsules stay what they are.
public enum CornerRadius {
    /// The command token, tooltips.
    public static let tag: CGFloat = 5
    /// Chips, tabs, the filter field, a question's option.
    public static let control: CGFloat = 7
    /// A row inside a menu or a list: the control's less 2.
    public static let row: CGFloat = control - 2
    /// Menus, the model panel, the slash list.
    public static let popover: CGFloat = 12
    /// The composer, the alert, cards.
    public static let card: CGFloat = 18
}
