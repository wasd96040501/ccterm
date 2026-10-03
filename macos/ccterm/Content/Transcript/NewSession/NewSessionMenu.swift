import Components
import Foundation

/// The New view's branch pop-up as the one menu (`MenuContent`, design 08 *The
/// New view*): a panel with a filter field over *Local*, *Remote* and, for a
/// typed `#N`, *Pull Request*. Each item's id is the `NewSessionDraft.Branch`
/// it stands for. (The folder's menu is the view's own: it lists what it is
/// shown.)
@MainActor
enum NewSessionMenu {
    static func branchContent(of list: NewSessionModel.BranchList, query: String) -> MenuContent {
        let rows: [MenuContent.Row] = BranchPickerModel(list).rows(matching: query).map { row in
            switch row {
            case .header(let words):
                return .header(.title(words))
            case .branch(let item):
                return .item(
                    MenuContent.Item(
                        id: NewSessionDraft.Branch.named(item.name), title: item.name, subtitle: item.subtitle,
                        isChecked: item.isChosen, isEnabled: item.isEnabled, toolTip: item.name))
            case .pullRequest(let number, let subtitle, let isChosen):
                return .item(
                    MenuContent.Item(
                        id: NewSessionDraft.Branch.pullRequest(number), title: "#\(number)", subtitle: subtitle,
                        isChecked: isChosen))
            case .empty(let words):
                return .item(MenuContent.Item(id: words, title: words, isEnabled: false))
            }
        }
        return MenuContent(
            rows: rows, filter: MenuContent.Filter(placeholder: String(localized: "Filter"), text: query))
    }
}
