import Cocoa

/// Completion row for a slash command advertised by the CLI in its
/// `initialize` response. Wraps `SlashCommand` (from `SessionTypes`) so
/// the completion list can render it next to file / directory items.
///
/// `name` is stored without the leading `/`; `displayText` adds it back
/// so the rendered row reads `/<name>`. `rank` is the fzf-style sort
/// position; lower is better.
struct SlashCommandCompletionItem: CompletionItem {
    let name: String
    let description: String?
    let rank: Int

    var displayText: String { "/\(name)" }
    var displayDetail: String? { description }
    var displayIcon: NSImage? {
        NSImage(systemSymbolName: "terminal", accessibilityDescription: "Command")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
}

/// Pure helper that filters the session's slash command list by a query
/// (case-insensitive substring) and returns ranked completion items.
/// Sync and cheap — slash command lists are small (~20 entries) so we
/// skip fzf here and avoid forking a subprocess on every keystroke.
enum SlashCommandCompleter {
    static func filter(query: String, commands: [SlashCommand], limit: Int = 20) -> [SlashCommandCompletionItem] {
        let trimmedQuery = query.lowercased()
        let filtered: [SlashCommand]
        if trimmedQuery.isEmpty {
            filtered = commands
        } else {
            filtered = commands.filter { $0.name.lowercased().contains(trimmedQuery) }
        }
        return filtered.prefix(limit).enumerated().map { idx, cmd in
            SlashCommandCompletionItem(name: cmd.name, description: cmd.description, rank: idx)
        }
    }
}
