import AppKit

/// What a `MenuPopover` shows (design 08 *Menus are popovers*): rows top to
/// bottom, the rows that stay under the list (Fast Mode), and for the branch
/// picker a search field over it.
public struct MenuContent {
    public enum Row {
        /// 11-pt semibold tertiary words over a group, and a key hint at the
        /// trailing edge (⇧⇥).
        case header(String, hint: String? = nil)
        /// An account's head: its mark, name and detail, and a note under it
        /// (*Restarts the session*).
        case account(mark: NSImage, name: String, detail: String, note: String?)
        case item(Item)
        case separator
    }

    /// A row that can be chosen.
    public struct Item {
        /// Handed back when it is chosen.
        public var id: AnyHashable
        public var title: String
        /// Under the title; for a disabled item, the reason.
        public var subtitle: String?
        /// In the glyph column, secondary ink.
        public var glyph: NSImage?
        public var isChecked: Bool
        public var isEnabled: Bool
        /// Bypass Permissions: title and glyph in red.
        public var isDanger: Bool
        public var trailing: Trailing
        public var toolTip: String?

        public init(
            id: AnyHashable, title: String, subtitle: String? = nil, glyph: NSImage? = nil,
            isChecked: Bool = false, isEnabled: Bool = true, isDanger: Bool = false, trailing: Trailing = .none,
            toolTip: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.glyph = glyph
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.isDanger = isDanger
            self.trailing = trailing
            self.toolTip = toolTip
        }

        /// A setting rather than a choice: choosing it leaves the menu open.
        public var isToggle: Bool {
            if case .toggle = trailing { true } else { false }
        }
    }

    /// What sits at an item's trailing edge.
    public enum Trailing {
        case none
        /// Tertiary words: a key equivalent (⌘O) or a folder's path.
        case key(String)
        /// A tertiary glyph (↻).
        case glyph(NSImage)
        /// A small switch: the item is a setting (Fast Mode).
        case toggle(isOn: Bool)
    }

    public var rows: [Row]
    /// Under the list, past a hairline, always in view.
    public var footer: [Item]
    /// The search field's placeholder; `nil`: no search field.
    public var searchPlaceholder: String?
    /// Said in the list's middle when `rows` is empty.
    public var emptyText: String?
    /// The least the popover is wide; its rows widen it to 1.618 times this,
    /// and its height stops there too.
    public var minWidth: CGFloat
    /// The list's height whatever it holds — for a menu whose rows change
    /// while it is open (a search), so the box doesn't; `nil`: as tall as
    /// its rows, scrolling past 1.618 times `minWidth`.
    public var listHeight: CGFloat?

    public init(
        rows: [Row], footer: [Item] = [], searchPlaceholder: String? = nil, emptyText: String? = nil,
        minWidth: CGFloat, listHeight: CGFloat? = nil
    ) {
        self.rows = rows
        self.footer = footer
        self.searchPlaceholder = searchPlaceholder
        self.emptyText = emptyText
        self.minWidth = minWidth
        self.listHeight = listHeight
    }

    /// Whether any item has a glyph: then every item keeps the glyph column,
    /// so all titles start together.
    var hasGlyphColumn: Bool {
        footer.contains { $0.glyph != nil }
            || rows.contains { if case .item(let item) = $0 { item.glyph != nil } else { false } }
    }
}
