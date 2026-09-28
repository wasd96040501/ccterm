import Foundation

extension Tools {
    /// Asks to enter plan mode.
    public enum EnterPlanMode: ToolDefinition {
        public static let name = "EnterPlanMode"
        public typealias Input = JSONValue
        public typealias Output = JSONValue
    }

    /// Presents a plan and asks to leave plan mode. Approve it through its
    /// ``PermissionRequest``.
    public enum ExitPlanMode: ToolDefinition {
        public static let name = "ExitPlanMode"

        public struct Input: Sendable, Equatable, Decodable {
            /// The plan, in Markdown.
            public var plan: String?
            /// Where the CLI saved the plan.
            public var planFilePath: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                plan = c.lenient(String.self, "plan")
                planFilePath = c.lenient(String.self, "planFilePath")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var plan: String?
            public var filePath: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                plan = c.lenient(String.self, "plan")
                filePath = c.lenient(String.self, "filePath")
            }
        }
    }
}
