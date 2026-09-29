import AgentSDK
import Foundation

/// A transcript as its tab shows it: the entries in reading order, and what
/// each openable thing on the page opens beside.
///
/// A value, built off the main actor from a `Transcript`
/// (`TranscriptPageBuilder`), every line already worded — so drawing a row
/// never composes anything.
nonisolated struct TranscriptPage: Sendable, Equatable {
    let entries: [TranscriptEntry]

    /// Where each openable id lives: an entry, and for a run's item, which.
    private let locations: [String: Location]

    private struct Location: Sendable, Equatable {
        let entry: Int
        let item: Int?
    }

    init(entries: [TranscriptEntry]) {
        self.entries = entries
        var locations: [String: Location] = [:]
        for (index, entry) in entries.enumerated() {
            locations[entry.id] = Location(entry: index, item: nil)
            switch entry {
            case .run(let run):
                for (position, item) in run.items.enumerated() {
                    locations[item.id] = Location(entry: index, item: position)
                }
            case .news(let news):
                for (position, one) in news.news.enumerated() {
                    locations[one.id] = Location(entry: index, item: position)
                }
            default:
                break
            }
        }
        self.locations = locations
    }

    init(_ transcript: Transcript) {
        var builder = TranscriptPageBuilder(messages: transcript.messages, workingDirectory: transcript.metadata.cwd)
        self.init(entries: builder.build())
    }

    /// The entry that holds `id` — an entry's own id, a run's item, a piece
    /// of news.
    func entryIndex(containing id: String) -> Int? {
        locations[id]?.entry
    }

    /// Every run item in reading order: what ↑ and ↓ walk.
    var items: [RunItem] {
        entries.flatMap { entry -> [RunItem] in
            if case .run(let run) = entry { run.items } else { [] }
        }
    }

    /// What `id` opens beside the transcript, or `nil` for something that
    /// opens nothing.
    func document(for id: String) -> DocumentContent? {
        guard let location = locations[id] else { return nil }
        switch entries[location.entry] {
        case .run(let run):
            guard let position = location.item ?? (run.isSingle ? 0 : nil) else { return nil }
            return document(for: run.items[position])
        case .news(let news):
            guard let position = location.item ?? (news.isSingle ? 0 : nil) else { return nil }
            let one = news.news[position]
            if one.kind == .command, let origin = one.origin, let call = call(origin), call.kind == .command {
                return .command(call)
            }
            return .news(one)
        case .command(let command):
            switch command.command {
            case .shell: return .shellCommand(command)
            case .slash: return command.output.isEmpty && command.errorOutput.isEmpty ? nil : .commandOutput(command)
            }
        case .divider(let divider):
            return divider.summary.map { .compactionSummary($0) }
        default:
            return nil
        }
    }

    private func document(for item: RunItem) -> DocumentContent {
        let call = item.calls[0]
        switch call.kind {
        case .command: return .command(call)
        case .change: return .change(item.calls)
        case .create: return .newFile(call)
        case .read: return .read(call)
        case .search: return .search(call)
        case .web: return .web(call)
        case .agent: return .agent(call)
        case .tasks: return .taskList(taskList(through: call.id))
        case .schedule, .message, .other: return .other(call)
        }
    }

    /// The call with `id`, wherever it sits on the page.
    func call(_ id: String) -> ToolCall? {
        guard let location = locations[id] else { return nil }
        switch entries[location.entry] {
        case .run(let run):
            return run.items.lazy.flatMap(\.calls).first { $0.id == id }
        case .question(let question):
            return question.call
        case .plan(let plan):
            return plan.call
        default:
            return nil
        }
    }

    /// The task list as it stood after the call `id`: every tasks call up to
    /// it, replayed.
    func taskList(through id: String) -> [TaskListItem] {
        var order: [String] = []
        var tasks: [String: TaskListItem] = [:]
        for item in items where item.kind == .tasks {
            for call in item.calls {
                if let input = call.use.input(as: Tools.TodoWrite.self) {
                    order = input.todos.indices.map(String.init)
                    tasks = Dictionary(
                        uniqueKeysWithValues: input.todos.enumerated().map {
                            (String($0.offset), TaskListItem(subject: $0.element.content, status: $0.element.status))
                        })
                } else if let input = call.use.input(as: Tools.TaskCreate.self) {
                    let taskID: String
                    if case .success(let output)? = call.result?.toolOutcome(Tools.TaskCreate.self) {
                        taskID = output.taskID
                    } else {
                        taskID = call.id
                    }
                    order.append(taskID)
                    tasks[taskID] = TaskListItem(subject: input.subject, status: .pending)
                } else if let input = call.use.input(as: Tools.TaskUpdate.self), let task = tasks[input.taskID] {
                    if input.status == .deleted {
                        tasks[input.taskID] = nil
                        order.removeAll { $0 == input.taskID }
                    } else {
                        tasks[input.taskID] = TaskListItem(
                            subject: input.subject ?? task.subject, status: input.status ?? task.status)
                    }
                }
                if call.id == id { return order.compactMap { tasks[$0] } }
            }
        }
        return order.compactMap { tasks[$0] }
    }
}
