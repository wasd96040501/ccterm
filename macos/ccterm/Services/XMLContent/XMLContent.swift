import Foundation
import AgentSDK

// MARK: - Local Command Caveat (A1)

public struct LocalCommandCaveatXML {
    public let caveat: String

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }
        guard let val = root.elements(forName: "local-command-caveat").first?.stringValue else { return nil }
        self.caveat = val
    }
}

// MARK: - Slash Command (A2)

public struct SlashCommandXML {
    public let commandName: String?
    public let commandMessage: String?
    public let commandArgs: String?

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }
        self.commandName = root.elements(forName: "command-name").first?.stringValue
        self.commandMessage = root.elements(forName: "command-message").first?.stringValue
        self.commandArgs = root.elements(forName: "command-args").first?.stringValue
    }
}

// MARK: - Local Command Output (A3)

public struct LocalCommandOutputXML {
    public let stdout: String?
    public let stderr: String?

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }
        self.stdout = root.elements(forName: "local-command-stdout").first?.stringValue
        self.stderr = root.elements(forName: "local-command-stderr").first?.stringValue
    }
}

// MARK: - Task Notification (B)

public struct TaskNotificationUsageXML {
    public let totalTokens: String?
    public let toolUses: String?
    public let durationMs: String?

    init?(element: XMLElement) {
        self.totalTokens = element.elements(forName: "total_tokens").first?.stringValue
        self.toolUses = element.elements(forName: "tool_uses").first?.stringValue
        self.durationMs = element.elements(forName: "duration_ms").first?.stringValue
    }
}

public struct WorktreeXML {
    public let path: String?
    public let branch: String?

    init?(element: XMLElement) {
        self.path = element.elements(forName: "worktreePath").first?.stringValue
        self.branch = element.elements(forName: "worktreeBranch").first?.stringValue
    }
}

public struct TaskNotificationXML {
    public let taskId: String
    public let toolUseId: String?
    public let outputFile: String?
    public let status: String
    public let summary: String
    public let result: String?
    public let usage: TaskNotificationUsageXML?
    public let worktree: WorktreeXML?

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }
        // Find the task-notification element, or use root if elements are direct children
        let el = root.elements(forName: "task-notification").first ?? root
        guard let taskId = el.elements(forName: "task-id").first?.stringValue,
              let status = el.elements(forName: "status").first?.stringValue,
              let summary = el.elements(forName: "summary").first?.stringValue else { return nil }
        self.taskId = taskId
        self.toolUseId = el.elements(forName: "tool-use-id").first?.stringValue
        self.outputFile = el.elements(forName: "output-file").first?.stringValue
        self.status = status
        self.summary = summary
        self.result = el.elements(forName: "result").first?.stringValue
        self.usage = el.elements(forName: "usage").first.flatMap { TaskNotificationUsageXML(element: $0) }
        self.worktree = el.elements(forName: "worktree").first.flatMap { WorktreeXML(element: $0) }
    }
}

// MARK: - Bash Input (C1)

public struct BashInputXML {
    public let input: String

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement(),
              let val = root.elements(forName: "bash-input").first?.stringValue else { return nil }
        self.input = val
    }
}

// MARK: - Bash Output (C2)

public struct BashOutputXML {
    public let stdout: String?
    public let stderr: String?

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }
        self.stdout = root.elements(forName: "bash-stdout").first?.stringValue
        self.stderr = root.elements(forName: "bash-stderr").first?.stringValue
    }
}

// MARK: - TaskOutput Result (D)

public struct TaskOutputXML {
    public let retrievalStatus: String
    public let taskId: String?
    public let taskType: String?
    public let status: String?
    public let exitCode: String?
    public let output: String?

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement(),
              let val = root.elements(forName: "retrieval_status").first?.stringValue else { return nil }
        self.retrievalStatus = val
        self.taskId = root.elements(forName: "task_id").first?.stringValue
        self.taskType = root.elements(forName: "task_type").first?.stringValue
        self.status = root.elements(forName: "status").first?.stringValue
        self.exitCode = root.elements(forName: "exit_code").first?.stringValue
        self.output = root.elements(forName: "output").first?.stringValue
    }
}

// MARK: - Persisted Output (E)

public struct PersistedOutputXML {
    public let content: String

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement(),
              let val = root.elements(forName: "persisted-output").first?.stringValue else { return nil }
        self.content = val
    }
}

// MARK: - System Reminder (F)

public struct SystemReminderXML {
    public let content: String

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement(),
              let val = root.elements(forName: "system-reminder").first?.stringValue else { return nil }
        self.content = val
    }
}

// MARK: - Tool Use Error (G)

public struct ToolUseErrorXML {
    public let error: String

    public init?(xmlString: String) {
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement(),
              let val = root.elements(forName: "tool_use_error").first?.stringValue else { return nil }
        self.error = val
    }
}

// MARK: - Top-Level Dispatch Enum

public enum XMLContent {
    case slashCommand(SlashCommandXML)
    case localCommandCaveat(LocalCommandCaveatXML)
    case localCommandOutput(LocalCommandOutputXML)
    case taskNotification(TaskNotificationXML)
    case bashInput(BashInputXML)
    case bashOutput(BashOutputXML)
    case taskOutput(TaskOutputXML)
    case persistedOutput(PersistedOutputXML)
    case systemReminder(SystemReminderXML)
    case toolUseError(ToolUseErrorXML)

    public init?(xmlString: String) {
        // Try parsing to detect which elements are present
        let wrapped = "<_r>\(xmlString)</_r>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: []),
              let root = doc.rootElement() else { return nil }

        let childNames = Set(root.children?.compactMap { $0.name } ?? [])

        // Dispatch based on detecting element names (same order as @XMLCase declarations)
        if childNames.contains("command-name") {
            guard let v = SlashCommandXML(xmlString: xmlString) else { return nil }
            self = .slashCommand(v)
        } else if childNames.contains("local-command-caveat") {
            guard let v = LocalCommandCaveatXML(xmlString: xmlString) else { return nil }
            self = .localCommandCaveat(v)
        } else if childNames.contains("local-command-stdout") || childNames.contains("local-command-stderr") {
            guard let v = LocalCommandOutputXML(xmlString: xmlString) else { return nil }
            self = .localCommandOutput(v)
        } else if childNames.contains("task-notification") {
            guard let v = TaskNotificationXML(xmlString: xmlString) else { return nil }
            self = .taskNotification(v)
        } else if childNames.contains("bash-input") {
            guard let v = BashInputXML(xmlString: xmlString) else { return nil }
            self = .bashInput(v)
        } else if childNames.contains("bash-stdout") {
            guard let v = BashOutputXML(xmlString: xmlString) else { return nil }
            self = .bashOutput(v)
        } else if childNames.contains("retrieval_status") {
            guard let v = TaskOutputXML(xmlString: xmlString) else { return nil }
            self = .taskOutput(v)
        } else if childNames.contains("persisted-output") {
            guard let v = PersistedOutputXML(xmlString: xmlString) else { return nil }
            self = .persistedOutput(v)
        } else if childNames.contains("system-reminder") {
            guard let v = SystemReminderXML(xmlString: xmlString) else { return nil }
            self = .systemReminder(v)
        } else if childNames.contains("tool_use_error") {
            guard let v = ToolUseErrorXML(xmlString: xmlString) else { return nil }
            self = .toolUseError(v)
        } else {
            return nil
        }
    }
}

// MARK: - Integration Extensions

extension Message2UserMessageContent {
    var xmlContent: XMLContent? {
        guard case .string(let s) = self else { return nil }
        return XMLContent(xmlString: s)
    }
}
