import Foundation

/// What the New view's branch menu lists for what is typed in its filter,
/// worded: *Local*, *Remote* and, for a typed `#N`, *Pull Request*, each over
/// its branches, or the line that says nothing matches. The app builds it
/// from the folder's branches; the view draws it in a popover with the filter
/// over it, and reports a chosen item by its `id`.
public struct NewSessionBranchMenu: Equatable {
    public var rows: [Row]
    /// What the filter holds.
    public var query: String
    /// Said in the list's middle when `rows` is empty.
    public var emptyText: String?

    public init(rows: [Row], query: String, emptyText: String? = nil) {
        self.rows = rows
        self.query = query
        self.emptyText = emptyText
    }

    public enum Row: Equatable {
        /// A group's title.
        case header(String)
        case item(Item)
    }

    /// A branch or a pull request to start from.
    public struct Item: Equatable {
        /// What the view reports when it is chosen.
        public var id: AnyHashable
        public var title: String
        /// Where it is checked out, or the pull request's title.
        public var subtitle: String?
        /// Whether it is the draft's branch.
        public var isChecked: Bool
        public var isEnabled: Bool
        public var toolTip: String?

        public init(
            id: AnyHashable, title: String, subtitle: String? = nil, isChecked: Bool = false,
            isEnabled: Bool = true, toolTip: String? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.isChecked = isChecked
            self.isEnabled = isEnabled
            self.toolTip = toolTip
        }
    }
}
