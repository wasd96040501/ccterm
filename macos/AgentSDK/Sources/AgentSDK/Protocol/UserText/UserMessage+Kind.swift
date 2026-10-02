import Foundation

extension UserMessage {
    /// What a user message is — one `switch` over every kind the CLI sends
    /// or records.
    ///
    /// The CLI speaks to the model as the user for more than the user: it
    /// relays other agents, reports background tasks, echoes local commands.
    /// Most of that is marked only by markup in the text; ``kind`` reads it,
    /// so a consumer never parses a message's text. A message in one of
    /// these forms that doesn't read as that form — a missing field, a tag
    /// the form doesn't have — is a ``prompt``, shown as written.
    public enum Kind: Sendable, Equatable {
        /// Text to show as written, with any images, in ``UserMessage/content``:
        /// what the user typed, or a message whose form didn't read.
        case prompt
        /// A slash command the user ran in the CLI rather than sent to the
        /// model: `/model` with arguments `opus`. A skill run this way is
        /// one too (`/skill-creator:skill-creator`).
        case slashCommand(name: String, arguments: String)
        /// A shell command the user ran from the CLI's prompt with `!`,
        /// without the `!`.
        case shellCommand(String)
        /// What the command before it printed.
        case commandOutput(standardOutput: String, standardError: String)
        case toolResult(ToolResultBlock)
        case taskNotification(TaskReport)
        /// A message another party sent into the conversation, without the
        /// frame the CLI puts around it.
        case message(from: Sender, text: String)
        /// The user stopped the response — while a tool was being used, or
        /// while the model was writing.
        case interruption(duringToolUse: Bool)
        /// What a compaction left in place of the conversation before it; the
        /// summary is in ``UserMessage/content``.
        case compactionSummary
        /// Text the CLI added for the model: reminders, skill bodies,
        /// scheduled prompts, notes on attached images.
        case synthetic
        /// A turn the CLI started with its own words
        /// (`origin.kind: "auto-continuation"`): a usage limit that reset, a
        /// plan approved in the browser, a goal set with `/goal`.
        case autoContinuation(text: String)
    }

    /// Who sent a ``Kind/message(from:text:)``.
    public enum Sender: Sendable, Equatable {
        /// A subagent of this session, handing back its report.
        case agent(id: String)
        /// Another Claude Code session: where it listens, and the name and
        /// mode it gave, when it gave them.
        case session(address: String, name: String?, mode: String?)
        /// The coordinator of the team this session works in.
        case coordinator
        /// A plugin's prompt: `duringTurn` when it came while the model worked
        /// (*…sent a message while you were working:*) rather than starting
        /// a turn in the user's place.
        case plugin(name: String, duringTurn: Bool)
    }

    public var kind: Kind { Kind(self) }

    /// The note the CLI files ahead of a local command's messages, telling
    /// the model to disregard them. It is written to the session's file but
    /// never sent on the stream.
    var isLocalCommandCaveat: Bool {
        guard content.count == 1, let text = content[0].text else { return false }
        return text[...].taggedElements?.map(\.name) == ["local-command-caveat"]
    }
}

extension UserMessage.Kind {
    /// What `message` is, read from its fields and the markup in its text.
    init(_ message: UserMessage) {
        self = Self.reading(message)
    }

    private static func reading(_ message: UserMessage) -> Self {
        if let toolResult = message.toolResult { return .toolResult(toolResult) }
        if message.isCompactSummary { return .compactionSummary }
        guard message.content.count == 1, let text = message.content[0].text?[...] else {
            return message.isSynthetic ? .synthetic : .prompt
        }
        switch message.origin {
        case "task-notification":
            return text.topLevelElements.first { $0.name == "task-notification" }.flatMap(TaskReport.init)
                .map(Self.taskNotification) ?? .prompt
        case "peer", "coordinator", "plugin":
            return relayedMessage(text) ?? .prompt
        case "auto-continuation":
            // TODO(fill A): .autoContinuation(text:) — and the mid-turn plugin header + its note.
            return .synthetic
        default:
            break
        }
        if message.isSynthetic { return .synthetic }
        if let elements = text.taggedElements { return kind(of: elements) ?? .prompt }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "[Request interrupted by user]": return .interruption(duringToolUse: false)
        case "[Request interrupted by user for tool use]": return .interruption(duringToolUse: true)
        default: return .prompt
        }
    }

    // MARK: - Forms

    /// A message whose whole text is elements: a local command, its output,
    /// or one relayed or notifying element. No form repeats an element.
    private static func kind(of elements: [TaggedElement]) -> Self? {
        let names = Set(elements.map(\.name))
        guard names.count == elements.count else { return nil }
        func text(_ name: String) -> String? { elements.first { $0.name == name }?.text }
        if names.isSubset(of: ["command-name", "command-message", "command-args"]), let name = text("command-name") {
            return .slashCommand(name: name, arguments: text("command-args") ?? "")
        }
        if names == ["bash-input"], let command = text("bash-input") {
            return .shellCommand(command)
        }
        if names.isSubset(of: ["local-command-stdout", "local-command-stderr", "bash-stdout", "bash-stderr"]) {
            return .commandOutput(
                standardOutput: text("local-command-stdout") ?? text("bash-stdout") ?? "",
                standardError: text("local-command-stderr") ?? text("bash-stderr") ?? "")
        }
        guard elements.count == 1 else { return nil }
        return TaskReport(elements[0]).map(Self.taskNotification) ?? message(elements[0])
    }

    /// A message the CLI relays under a header naming its sender —
    /// `The coordinator sent a message while you were working:` — and, for
    /// some senders, followed by a note to the model.
    private static func relayedMessage(_ text: Substring) -> Self? {
        guard let newline = text.firstIndex(of: "\n"), let sender = sender(inHeader: text[..<newline]) else {
            return nil
        }
        let body = text[text.index(after: newline)...]
        if sender == "Another Claude session" {
            return body.drop(while: \.isWhitespace).leadingElement().flatMap { message($0.element) }
        }
        if sender == "The coordinator" {
            return .message(from: .coordinator, text: body.removingSuffix(coordinatorNote))
        }
        if sender.hasPrefix("The "), sender.hasSuffix(" plugin") {
            let name = String(sender.dropFirst("The ".count).dropLast(" plugin".count))
            return .message(from: .plugin(name: name, duringTurn: false), text: body.removingSuffix(pluginNote))
        }
        return nil
    }

    /// `<sender>` in `<sender> sent a message:` or `… while you were working:`.
    private static func sender(inHeader header: Substring) -> Substring? {
        for ending in [" sent a message:", " sent a message while you were working:"] where header.hasSuffix(ending) {
            return header.dropLast(ending.count)
        }
        return nil
    }

    private static let coordinatorNote = "Address this before completing your current task."
    private static let pluginNote =
        "This is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above."

    /// An element carrying another party's message.
    private static func message(_ element: TaggedElement) -> Self? {
        switch element.name {
        case "agent-message":
            guard let id = element.attributes["from"] else { return nil }
            return .message(from: .agent(id: id), text: report(in: element.body))
        case "cross-session-message":
            guard let address = element.attributes["from"] else { return nil }
            let sender = UserMessage.Sender.session(
                address: address, name: element.attributes["from-name"], mode: element.attributes["from-mode"])
            return .message(from: sender, text: element.text)
        default:
            return nil
        }
    }

    /// A subagent's report without the frame the CLI hands it back in: a line
    /// `[Subagent hand-back] … The report follows:`, then every line of the
    /// report indented by two spaces, so the frame is only ever at column
    /// zero. Notes the CLI puts above the frame — that the safety classifier
    /// didn't review the work — stay, as a paragraph ahead of the report. A
    /// body without the frame is the report as is.
    private static func report(in body: Substring) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let frame = lines.firstIndex(where: { $0.hasPrefix("[Subagent hand-back]") }) else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let notes = lines[..<frame].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let report = lines[(frame + 1)...].map { $0.hasPrefix("  ") ? $0.dropFirst(2) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? report : "\(notes)\n\n\(report)"
    }
}

extension Substring {
    /// This text trimmed, without `suffix` if it ends with it.
    fileprivate func removingSuffix(_ suffix: String) -> String {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(suffix) else { return text }
        return text.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
