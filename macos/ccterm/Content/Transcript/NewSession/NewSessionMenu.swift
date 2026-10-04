import DisplayModels
import Foundation

/// The New view's branch menu (`NewSessionBranchMenu`, design 08 *The New
/// view*): *Local*, *Remote* and, for a typed `#N`, *Pull Request*. Each item's
/// id is the `NewSessionDraft.Branch` it stands for. (The folder's menu is the
/// view's own: it lists what it is shown.)
@MainActor
enum NewSessionMenu {
    static func branchMenu(of list: NewSessionModel.BranchList, query: String) -> NewSessionBranchMenu {
        let rows: [NewSessionBranchMenu.Row] = BranchPickerModel(list).rows(matching: query).map { row in
            switch row {
            case .header(let words):
                return .header(words)
            case .branch(let item):
                return .item(
                    NewSessionBranchMenu.Item(
                        id: NewSessionDraft.Branch.named(item.name), title: item.name, subtitle: item.subtitle,
                        isChecked: item.isChosen, isEnabled: item.isEnabled, toolTip: item.name))
            case .pullRequest(let number, let subtitle, let isChosen):
                return .item(
                    NewSessionBranchMenu.Item(
                        id: NewSessionDraft.Branch.pullRequest(number), title: "#\(number)", subtitle: subtitle,
                        isChecked: isChosen))
            case .empty(let words):
                return .note(words)
            }
        }
        return NewSessionBranchMenu(rows: rows, query: query)
    }
}
