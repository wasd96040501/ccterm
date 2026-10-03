import AppKit

/// What a `MenuPanelViewController` shows: the design's one menu (`.lv-menu`,
/// `menuHTML` in preview-live.js), which every pop-up of the composer and the
/// New view is — Model, Effort, Mode, the folder and the branch. Rows top to
/// bottom; what goes under the scroll (Fast Mode) is `footer`.
public struct MenuContent {
    /// A section's head (`.mh`).
    public enum Header {
        /// 11-pt semibold tertiary words over the items, with a key hint at the
        /// trailing edge (⇧⇥).
        case title(String, hint: String? = nil)
        /// An account (`.mh.acct`): its mark, name and detail, and a note on a
        /// line under (*Restarts the session*). It sticks to the scroll's top
        /// while its items pass under it.
        case account(mark: NSImage, name: String, detail: String, note: String?)
    }

    /// What sits at an item's trailing edge (`.mi .k`).
    public enum Trailing {
        case none
        /// 12-pt tertiary words: a key equivalent (⌘O) or a folder's path.
        case key(String)
        /// A 14-pt glyph in tertiary (↻).
        case glyph(NSImage)
        /// A small switch: the row is a setting, not a choice (Fast Mode).
        case toggle(isOn: Bool)
    }

    /// A row that can be chosen (`.mi`).
    public struct Item {
        /// Handed back when the item is chosen.
        public var id: AnyHashable
        public var title: String
        /// 11-pt, under the title; for a disabled item, the reason.
        public var subtitle: String?
        /// A 16-pt glyph in the glyph column, secondary ink.
        public var glyph: NSImage?
        public var isChecked = false
        public var isEnabled = true
        /// Bypass Permissions: title and glyph in red.
        public var isDanger = false
        /// *N More Models*: accent words; choosing it keeps the menu open.
        public var isMore = false
        public var trailing = Trailing.none
        public var toolTip: String?

        public init(
            id: AnyHashable, title: String, subtitle: String? = nil, glyph: NSImage? = nil,
            isChecked: Bool = false, isEnabled: Bool = true, isDanger: Bool = false, isMore: Bool = false,
            trailing: Trailing = .none, toolTip: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.glyph = glyph
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.isDanger = isDanger
            self.isMore = isMore
            self.trailing = trailing
            self.toolTip = toolTip
        }

        /// Choosing it leaves the menu open: a switch, or a fold that expands.
        public var keepsMenuOpen: Bool {
            if isMore { return true }
            if case .toggle = trailing { return true }
            return false
        }
    }

    public enum Row {
        case header(Header)
        case item(Item)
        /// A hairline (`.msep`).
        case separator
    }

    /// The filter field over the list (`.mfilter`), and what it holds.
    public struct Filter {
        public var placeholder: String
        public var text: String

        public init(placeholder: String, text: String) {
            self.placeholder = placeholder
            self.text = text
        }
    }

    public var rows: [Row]
    /// Under the scroll, past a hairline (`.mfoot`), always in view.
    public var footer: [Row] = []
    public var filter: Filter?
    /// A panel (`.lv-menu.panel`) is 300 pt wide and its list scrolls past
    /// 360 pt; a menu is as wide as its widest row, 240 to 340.
    public var isPanel = false

    public init(rows: [Row], footer: [Row] = [], filter: Filter? = nil, isPanel: Bool = false) {
        self.rows = rows
        self.footer = footer
        self.filter = filter
        self.isPanel = isPanel || filter != nil || !footer.isEmpty
    }

    /// Whether any item has a glyph: then every item keeps the glyph column,
    /// so all words start together (`.mi` vs `.mi.nog`).
    public var hasGlyphColumn: Bool {
        (rows + footer).contains { if case .item(let item) = $0 { item.glyph != nil } else { false } }
    }
}
