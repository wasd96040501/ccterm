import AgentSDK
import Foundation

/// The two documents a session's own controls open — its log and its context —
/// as markdown. Neither has a row in the transcript.
nonisolated extension DocumentMarkdown {

    // MARK: - Log

    /// What the CLI wrote to stderr, as it wrote it in a monospaced block; a
    /// sentence when it wrote nothing.
    static func logBody(_ failure: SessionFailure) -> String {
        let text = failure.log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "*" + String(localized: "Claude wrote nothing to its log.") + "*" }
        return fenced(text)
    }

    // MARK: - Context

    /// What `/context` shows, as the CLI orders it: the total against the
    /// window, the categories that fill it, then what each itemized part costs.
    ///
    /// Tables, not the CLI's grid and list: the columns line up, the numbers
    /// sit right-aligned, and find, selection and copy work as in a reply.
    static func contextBody(_ usage: ContextUsage) -> [String] {
        var body = ["**" + contextTotal(usage) + "**"]
        if !usage.categories.isEmpty {
            let rows = usage.categories.map { category -> [String] in
                let name = category.isDeferred ? "\(category.name) · \(deferred)" : category.name
                return [cell(name), tokens(category.tokens), share(category.tokens, of: usage.maxTokens)]
            }
            body.append(
                table(
                    [String(localized: "Category"), String(localized: "Tokens"), String(localized: "Window")],
                    right: [1, 2], rows: rows))
        }
        if !usage.memoryFiles.isEmpty {
            body.append("**" + String(localized: "Memory Files") + "**")
            body.append(
                table(
                    [String(localized: "File"), String(localized: "Type"), String(localized: "Tokens")], right: [2],
                    rows: usage.memoryFiles.map { [code($0.path), cell($0.type ?? ""), tokens($0.tokens)] }))
        }
        if !usage.mcpTools.isEmpty {
            body.append("**" + String(localized: "MCP Tools") + "**")
            body.append(
                table(
                    [String(localized: "Tool"), String(localized: "Server"), String(localized: "Tokens")], right: [2],
                    rows: usage.mcpTools.map {
                        let name = $0.isLoaded == false ? "\($0.name) · \(deferred)" : $0.name
                        return [code(name), cell($0.serverName), tokens($0.tokens)]
                    }))
        }
        if !usage.agents.isEmpty {
            body.append("**" + String(localized: "Agents") + "**")
            body.append(
                table(
                    [String(localized: "Agent Type"), String(localized: "Source"), String(localized: "Tokens")],
                    right: [2],
                    rows: usage.agents.map { [cell($0.agentType), cell($0.source ?? ""), tokens($0.tokens)] }))
        }
        if let skills = usage.skills {
            body.append("**" + String(localized: "Skills") + "**")
            body.append(
                String(
                    localized:
                        "\(skills.includedSkills) of \(skills.totalSkills) skills · \(skills.tokens.formatted()) tokens"
                ))
        }
        if let commands = usage.slashCommands {
            body.append("**" + String(localized: "Slash Commands") + "**")
            body.append(
                String(
                    localized:
                        "\(commands.includedCommands) of \(commands.totalCommands) commands · \(commands.tokens.formatted()) tokens"
                ))
        }
        return body
    }

    /// *52,300 tokens of 200,000 (26%)*.
    static func contextTotal(_ usage: ContextUsage) -> String {
        let total = usage.totalTokens.formatted()
        let window = usage.maxTokens.formatted()
        return String(localized: "\(total) tokens of \(window) (\(usage.percentage)%)")
    }

    private static var deferred: String { String(localized: "deferred") }

    private static func tokens(_ count: Int) -> String { count.formatted() }

    /// A part's share of the window, to a tenth of a percent, as the CLI says
    /// it.
    private static func share(_ count: Int, of window: Int) -> String {
        guard window > 0 else { return "" }
        let percent = Double(count) / Double(window) * 100
        return percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    // MARK: - Table

    /// A markdown table: `right` are the columns that hold numbers.
    private static func table(_ header: [String], right: Set<Int>, rows: [[String]]) -> String {
        let divider = header.indices.map { right.contains($0) ? "---:" : "---" }
        return ([header, divider] + rows).map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
    }

    /// A cell's words: shown as they are, and unable to end the cell.
    private static func cell(_ text: String) -> String {
        escaped(text).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// A path or a name in code.
    private static func code(_ text: String) -> String {
        "`" + text.replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "|", with: "\\|") + "`"
    }
}
