import Foundation

extension Tools {
    /// Searches file contents with ripgrep.
    public enum Grep: ToolDefinition {
        public static let name = "Grep"

        public struct Input: Sendable, Equatable, Decodable {
            public var pattern: String
            public var path: String?
            /// File glob filter, e.g. `"*.swift"`.
            public var glob: String?
            /// File type filter, e.g. `"swift"`.
            public var type: String?
            /// `content`, `files_with_matches` (default), or `count`.
            public var outputMode: String?
            public var caseInsensitive: Bool
            public var multiline: Bool
            public var headLimit: Int?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                pattern = try c.required(String.self, "pattern")
                path = c.lenient(String.self, "path")
                glob = c.lenient(String.self, "glob")
                type = c.lenient(String.self, "type")
                outputMode = c.lenient(String.self, "output_mode")
                caseInsensitive = c.lenientBool("-i") ?? false
                multiline = c.lenientBool("multiline") ?? false
                headLimit = c.lenientInt("head_limit")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var mode: String?
            public var numFiles: Int
            public var filenames: [String]
            /// Matching lines (`content` mode).
            public var content: String?
            public var numLines: Int?
            public var numMatches: Int?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                mode = c.lenient(String.self, "mode")
                numFiles = c.lenientInt("numFiles") ?? 0
                filenames = c.lenient([String].self, "filenames") ?? []
                content = c.lenient(String.self, "content")
                numLines = c.lenientInt("numLines")
                numMatches = c.lenientInt("numMatches")
            }
        }
    }

    /// Finds files by glob pattern.
    public enum Glob: ToolDefinition {
        public static let name = "Glob"

        public struct Input: Sendable, Equatable, Decodable {
            public var pattern: String
            public var path: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                pattern = try c.required(String.self, "pattern")
                path = c.lenient(String.self, "path")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var filenames: [String]
            public var numFiles: Int
            public var truncated: Bool
            public var durationMS: Int

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filenames = c.lenient([String].self, "filenames") ?? []
                numFiles = c.lenientInt("numFiles") ?? filenames.count
                truncated = c.lenientBool("truncated") ?? false
                durationMS = c.lenientInt("durationMs") ?? 0
            }
        }
    }
}
