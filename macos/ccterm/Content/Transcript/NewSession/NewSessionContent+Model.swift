import DisplayModels
import Foundation

extension NewSessionContent {
    /// What the New view shows of `model`: the branch list stays here, asked
    /// for by the view through `NewSessionMenu`.
    init(_ model: NewSessionModel) {
        self.init(
            folderTitle: model.folderTitle, folderPath: model.folderPath,
            recentFolders: model.recentFolders.map {
                Folder(url: $0.url, title: $0.title, path: $0.path, isChosen: $0.isChosen)
            },
            branchRow: BranchRow(model.branchRow), explanation: model.explanation)
    }
}

extension NewSessionContent.BranchRow {
    init(_ row: NewSessionModel.BranchRow) {
        switch row {
        case .repository(let branchTitle, let usesWorktree, _):
            self = .repository(branchTitle: branchTitle, usesWorktree: usesWorktree)
        case .notARepository(let words): self = .notARepository(words)
        case .loading: self = .loading
        }
    }
}
