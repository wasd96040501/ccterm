import Foundation

extension Tools {
    /// Creates or overwrites a file.
    public enum Write: ToolDefinition {
        public static let name = "Write"

        public struct Input: Sendable, Equatable, Decodable {
            public var filePath: String
            public var content: String

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filePath = try c.required(String.self, "file_path")
                content = c.lenient(String.self, "content") ?? ""
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            /// `true` when the file did not exist before.
            public var isNewFile: Bool
            public var filePath: String
            public var content: String
            /// Empty for a new file.
            public var structuredPatch: [DiffHunk]
            /// `nil` for a new file, and in transcripts when it was large.
            public var originalFile: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                isNewFile = c.lenient(String.self, "type") == "create"
                filePath = c.lenient(String.self, "filePath") ?? ""
                content = c.lenient(String.self, "content") ?? ""
                structuredPatch = c.lenientArray(DiffHunk.self, "structuredPatch") ?? []
                originalFile = c.lenient(String.self, "originalFile")
            }
        }
    }
}
