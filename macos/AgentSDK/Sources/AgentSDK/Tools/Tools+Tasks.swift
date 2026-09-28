import Foundation

extension Tools {
    /// A task-list entry's state.
    public enum TaskStatus: String, Sendable, Decodable {
        case pending
        case inProgress = "in_progress"
        case completed
        case deleted
    }

    /// Adds an entry to the session's task list.
    public enum TaskCreate: ToolDefinition {
        public static let name = "TaskCreate"

        public struct Input: Sendable, Equatable, Decodable {
            public var subject: String
            public var description: String
            /// Present-tense label shown while the task runs.
            public var activeForm: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                subject = try c.required(String.self, "subject")
                description = c.lenient(String.self, "description") ?? ""
                activeForm = c.lenient(String.self, "activeForm")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            /// The id later ``TaskUpdate`` calls refer to.
            public var taskID: String
            public var subject: String

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                let task = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "task")
                taskID = try task.required(String.self, "id")
                subject = task.lenient(String.self, "subject") ?? ""
            }
        }
    }

    /// Changes an entry of the session's task list.
    public enum TaskUpdate: ToolDefinition {
        public static let name = "TaskUpdate"

        public struct Input: Sendable, Equatable, Decodable {
            public var taskID: String
            public var status: TaskStatus?
            public var subject: String?
            public var description: String?
            public var activeForm: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                taskID = try c.required(String.self, "taskId")
                status = c.lenient(TaskStatus.self, "status")
                subject = c.lenient(String.self, "subject")
                description = c.lenient(String.self, "description")
                activeForm = c.lenient(String.self, "activeForm")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            /// `false` when the update was rejected; see ``error``.
            public var success: Bool
            public var taskID: String
            public var updatedFields: [String]
            public var error: String?
            /// The status after the update, when it changed.
            public var newStatus: TaskStatus?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                success = c.lenientBool("success") ?? false
                taskID = c.lenient(String.self, "taskId") ?? ""
                updatedFields = c.lenient([String].self, "updatedFields") ?? []
                error = c.lenient(String.self, "error")
                let change = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "statusChange")
                newStatus = change?.lenient(TaskStatus.self, "to")
            }
        }
    }

    /// Replaces the whole todo list (older CLIs; newer ones use
    /// ``TaskCreate`` and ``TaskUpdate``).
    public enum TodoWrite: ToolDefinition {
        public static let name = "TodoWrite"
        public typealias Output = JSONValue

        public struct Input: Sendable, Equatable, Decodable {
            public var todos: [Todo]

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                todos = try c.required([Todo].self, "todos")
            }
        }

        public struct Todo: Sendable, Equatable, Decodable {
            public var content: String
            public var status: TaskStatus
            public var activeForm: String

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                content = try c.required(String.self, "content")
                status = c.lenient(TaskStatus.self, "status") ?? .pending
                activeForm = c.lenient(String.self, "activeForm") ?? content
            }
        }
    }

    /// Stops a background task.
    public enum TaskStop: ToolDefinition {
        public static let name = "TaskStop"
        public static let aliases = ["KillShell", "KillBash"]
        public typealias Output = JSONValue

        public struct Input: Sendable, Equatable, Decodable {
            public var taskID: String

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                taskID = try c.required(String.self, "task_id", "shell_id")
            }
        }
    }
}
