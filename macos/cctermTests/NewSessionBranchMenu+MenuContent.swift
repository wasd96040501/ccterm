import Components
import DisplayModels

extension NewSessionBranchMenu {
    /// The panel the New view opens for this menu — a copy of its `package`
    /// mapping for the snapshot tests that render the panel alone; it leaves
    /// with them.
    var menuContent: MenuContent {
        MenuContent(
            rows: rows.map { row in
                switch row {
                case .header(let words):
                    .header(.title(words))
                case .item(let item):
                    .item(
                        MenuContent.Item(
                            id: item.id, title: item.title, subtitle: item.subtitle, isChecked: item.isChecked,
                            isEnabled: item.isEnabled, toolTip: item.toolTip))
                case .note(let words):
                    .item(MenuContent.Item(id: words, title: words, isEnabled: false))
                }
            },
            filter: MenuContent.Filter(placeholder: "Filter", text: query))
    }
}
