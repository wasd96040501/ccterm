import Foundation

/// The branch popover's rows for what is typed in its filter (design 08 *The
/// New view*): *Local* and *Remote* sections of the branches that match, and
/// a *Pull Request* item when `#N` is typed. Pure, so the filter and ↩ are
/// tested without AppKit.
nonisolated struct BranchPickerModel: Equatable, Sendable {
    let list: NewSessionModel.BranchList

    /// One row of the list.
    enum Row: Equatable, Sendable {
        case header(String)
        case branch(NewSessionModel.BranchItem)
        /// *Pull Request · #N — Checks out in a new worktree*.
        case pullRequest(number: Int, subtitle: String, isChosen: Bool)
        /// Nothing matches.
        case empty(String)

        /// What choosing the row reports; `nil` for a header, a greyed row or
        /// the empty note.
        var choice: NewSessionDraft.Branch? {
            switch self {
            case .branch(let item): item.isEnabled ? .named(item.name) : nil
            case .pullRequest(let number, _, _): .pullRequest(number)
            case .header, .empty: nil
            }
        }
    }

    init(_ list: NewSessionModel.BranchList) {
        self.list = list
    }

    /// The rows for `query`: branches whose name contains it (case-insensitive,
    /// a leading `#` ignored), and — for a typed `#N` or `N` — the pull request.
    func rows(matching query: String) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let needle = query.hasPrefix("#") ? String(query.dropFirst()) : query
        func matches(_ item: NewSessionModel.BranchItem) -> Bool {
            needle.isEmpty || item.name.localizedCaseInsensitiveContains(needle)
        }

        var rows: [Row] = []
        let local = list.local.filter(matches)
        let remote = list.remote.filter(matches)
        if !local.isEmpty { rows += [.header(String(localized: "Local"))] + local.map(Row.branch) }
        if !remote.isEmpty { rows += [.header(String(localized: "Remote"))] + remote.map(Row.branch) }
        if let number = Self.pullRequestNumber(in: query) {
            rows += [
                .header(String(localized: "Pull Request")),
                .pullRequest(
                    number: number, subtitle: String(localized: "Checks out in a new worktree"),
                    isChosen: list.chosenPullRequest == number),
            ]
        }
        if rows.isEmpty { rows = [.empty(String(localized: "No Matching Branches"))] }
        return rows
    }

    /// What ↩ takes: the first row that can be chosen.
    func firstChoice(matching query: String) -> NewSessionDraft.Branch? {
        rows(matching: query).lazy.compactMap(\.choice).first
    }

    /// `327` from `#327` or `327`.
    private static func pullRequestNumber(in query: String) -> Int? {
        let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        guard let number = Int(digits), number > 0 else { return nil }
        return number
    }
}
