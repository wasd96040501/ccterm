import Foundation

extension Tools {
    /// Replaces text in a file.
    public enum Edit: ToolDefinition {
        public static let name = "Edit"

        public struct Input: Sendable, Equatable, Decodable {
            public var filePath: String
            public var oldString: String
            public var newString: String
            public var replaceAll: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filePath = try c.required(String.self, "file_path")
                oldString = c.lenient(String.self, "old_string") ?? ""
                newString = c.lenient(String.self, "new_string") ?? ""
                replaceAll = c.lenientBool("replace_all") ?? false
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var filePath: String
            public var oldString: String
            public var newString: String
            /// The file before the edit; `nil` in transcripts when it was
            /// large. Render from ``structuredPatch``.
            public var originalFile: String?
            public var structuredPatch: [DiffHunk]
            /// The user changed the proposed edit before accepting it.
            public var userModified: Bool
            public var replaceAll: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filePath = c.lenient(String.self, "filePath") ?? ""
                oldString = c.lenient(String.self, "oldString") ?? ""
                newString = c.lenient(String.self, "newString") ?? ""
                originalFile = c.lenient(String.self, "originalFile")
                structuredPatch = c.lenientArray(DiffHunk.self, "structuredPatch") ?? []
                userModified = c.lenientBool("userModified") ?? false
                replaceAll = c.lenientBool("replaceAll") ?? false
            }
        }
    }
}
