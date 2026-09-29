import Foundation

/// The command document's header (02-command.md "Layout"): the kind's tile in
/// the call's state, the description as the title — cut to 32 characters for
/// the tab — and *Command* when there is none; a `!` command is *You ran*.
/// The status line and the rest of the page are `CommandSummary`'s.
nonisolated extension DocumentHeader {
    /// The longest a tab's title is.
    private static let tabTitleLength = 32

    static func command(_ call: ToolCall) -> DocumentHeader {
        let heading = CommandSummary(call).heading
        return DocumentHeader(
            tile: WorkLineWriter(workingDirectory: nil).line(for: [call], standalone: true).tile, crumbs: [heading],
            title: cut(heading))
    }

    static func shellCommand(_ command: LocalCommand) -> DocumentHeader {
        let title = CommandSummary(command).heading
        return DocumentHeader(tile: Tile(glyph: .tool(.command), state: .done), crumbs: [title], title: title)
    }

    private static func cut(_ text: String) -> String {
        let line = WorkLineWriter.firstLine(text)
        return line.count > tabTitleLength ? String(line.prefix(tabTitleLength - 1)) + "…" : line
    }
}
