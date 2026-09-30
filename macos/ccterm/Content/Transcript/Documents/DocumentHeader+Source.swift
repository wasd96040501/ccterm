import Foundation

/// A file document's header (03-file.md "The frame"): the path as Xcode's
/// jump bar, relative to the session's directory, and the stat — `+12 −3`,
/// `New · 55 lines`, `Lines 40–120 of 880`.
nonisolated extension DocumentHeader {
    /// `content` is `.change`, `.newFile` or `.read`.
    static func source(_ content: DocumentContent, workingDirectory: String?) -> DocumentHeader {
        let calls: [ToolCall]
        let stat: StyledText
        switch content {
        case .change(let changed):
            calls = changed
            let lines = SourceLines.change(changed)
            stat =
                lines.firstChange == nil
                ? StyledText() : StyledText.diffStat(added: lines.added, removed: lines.removed)
        case .newFile(let call):
            calls = [call]
            let count = SourceLines.newFile(call).lines.count
            stat = StyledText(String(localized: "New · \(count) lines"))
        case .read(let call):
            calls = [call]
            stat = Self.readStat(SourceLines.read(call).slice)
        default:
            return markdown(content)
        }
        let path = calls.first?.filePath ?? ""
        let name = (path as NSString).lastPathComponent
        return DocumentHeader(
            tile: Tile(calls: calls),
            crumbs: crumbs(of: path, workingDirectory: workingDirectory), stat: stat, title: name)
    }

    /// `Lines 40–120 of 880`.
    static func readStat(_ slice: SourceLines.Slice?) -> StyledText {
        guard let slice else { return StyledText() }
        return StyledText(
            slice.total > 0
                ? String(localized: "Lines \(slice.first)–\(slice.last) of \(slice.total)")
                : String(localized: "Lines \(slice.first)–\(slice.last)"))
    }

    /// The path outermost first: the session's directory by name, then what
    /// lies under it; a path outside it starts at the home folder's `~` or the
    /// root.
    static func crumbs(of path: String, workingDirectory: String?) -> [String] {
        guard !path.isEmpty else { return [] }
        func parts(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
        if let root = workingDirectory, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                let name = parts(root).last
                return (name.map { [$0] } ?? []) + parts(String(path.dropFirst(prefix.count)))
            }
        }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return ["~"] + parts(String(path.dropFirst(home.count))) }
        return parts(path)
    }
}
