import Foundation

extension Tools {
    /// Runs a subagent. Its own messages carry this call's id as
    /// `parentToolUseID`.
    public enum Agent: ToolDefinition {
        public static let name = "Agent"
        public static let aliases = ["Task"]

        public struct Input: Sendable, Equatable, Decodable {
            public var description: String
            public var prompt: String
            public var subagentType: String?
            public var model: String?
            public var runInBackground: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                description = c.lenient(String.self, "description") ?? ""
                prompt = try c.required(String.self, "prompt")
                subagentType = c.lenient(String.self, "subagent_type")
                model = c.lenient(String.self, "model")
                runInBackground = c.lenientBool("run_in_background") ?? false
            }
        }

        public enum Output: Sendable, Equatable, Decodable {
            /// The subagent ran to completion in the foreground.
            case completed(Completed)
            /// The subagent was started in the background; its end arrives as
            /// a ``SystemMessage/taskNotification(_:)``.
            case launched(agentID: String, outputFile: String)
            /// A kind this SDK does not model.
            case other(JSONValue)

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                switch c.lenient(String.self, "status") {
                case "completed":
                    self = .completed(try Completed(from: decoder))
                case "async_launched":
                    self = .launched(
                        agentID: c.lenient(String.self, "agentId") ?? "",
                        outputFile: c.lenient(String.self, "outputFile") ?? "")
                default:
                    self = .other(decoder.rawValue())
                }
            }
        }

        public struct Completed: Sendable, Equatable, Decodable {
            public var agentID: String
            /// The subagent's final report.
            public var text: String
            public var totalToolUseCount: Int
            public var totalDurationMS: Int
            public var totalTokens: Int

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                agentID = c.lenient(String.self, "agentId") ?? ""
                text =
                    (c.lenient([JSONValue].self, "content") ?? []).compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n")
                totalToolUseCount = c.lenientInt("totalToolUseCount") ?? 0
                totalDurationMS = c.lenientInt("totalDurationMs") ?? 0
                totalTokens = c.lenientInt("totalTokens") ?? 0
            }
        }
    }
}
