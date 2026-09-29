import Foundation

/// The command document's header (02-command.md "Layout"): the kind's tile,
/// the description as the title — cut to 32 characters for the tab — and
/// *Command* when there is none; a `!` command is *You ran*.
nonisolated extension DocumentHeader {
    static func command(_ call: ToolCall) -> DocumentHeader {
        let title = String(localized: "Command")
        return DocumentHeader(tile: Tile(glyph: .tool(.command), state: .done), crumbs: [title], title: title)
    }

    static func shellCommand(_ command: LocalCommand) -> DocumentHeader {
        let title = String(localized: "You ran")
        return DocumentHeader(tile: Tile(glyph: .tool(.command), state: .done), crumbs: [title], title: title)
    }
}
