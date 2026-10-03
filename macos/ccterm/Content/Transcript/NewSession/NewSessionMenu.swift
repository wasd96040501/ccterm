import AppKit

/// The New view's two pop-ups as the one menu (`MenuContent`, design 08 *The
/// New view*): the folder's — *Recent*, each folder with its glyph and its
/// path at the trailing edge, then *Choose Folder… ⌘O* past a hairline — and
/// the branch's, a panel with a filter field over *Local*, *Remote* and, for a
/// typed `#N`, *Pull Request*.
@MainActor
enum NewSessionMenu {
    /// What a chosen item stands for.
    enum Choice: Hashable {
        case folder(URL)
        case chooseFolder
        case branch(NewSessionDraft.Branch)
    }

    static func folderContent(of model: NewSessionModel) -> MenuContent {
        var rows: [MenuContent.Row] = []
        if !model.recentFolders.isEmpty {
            rows.append(.header(.title(String(localized: "Recent"))))
            // The sheet's folder (10.4 × 9.2 of the row's 16), as SF Symbols draws it.
            let glyph = NSImage.symbol("folder", pointSize: 11)
            for folder in model.recentFolders {
                rows.append(
                    .item(
                        MenuContent.Item(
                            id: Choice.folder(folder.url), title: folder.title, glyph: glyph,
                            isChecked: folder.isChosen, trailing: .key(folder.path), toolTip: folder.path)))
            }
            rows.append(.separator)
        }
        rows.append(
            .item(
                MenuContent.Item(
                    id: Choice.chooseFolder, title: String(localized: "Choose Folder…"), trailing: .key("⌘O"))))
        return MenuContent(rows: rows)
    }

    static func branchContent(of list: NewSessionModel.BranchList, query: String) -> MenuContent {
        let rows: [MenuContent.Row] = BranchPickerModel(list).rows(matching: query).map { row in
            switch row {
            case .header(let words):
                return .header(.title(words))
            case .branch(let item):
                return .item(
                    MenuContent.Item(
                        id: Choice.branch(.named(item.name)), title: item.name, subtitle: item.subtitle,
                        isChecked: item.isChosen, isEnabled: item.isEnabled, toolTip: item.name))
            case .pullRequest(let number, let subtitle, let isChosen):
                return .item(
                    MenuContent.Item(
                        id: Choice.branch(.pullRequest(number)), title: "#\(number)", subtitle: subtitle,
                        isChecked: isChosen))
            case .empty(let words):
                return .item(MenuContent.Item(id: words, title: words, isEnabled: false))
            }
        }
        return MenuContent(
            rows: rows, filter: MenuContent.Filter(placeholder: String(localized: "Filter"), text: query))
    }
}
