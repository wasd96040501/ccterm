import Foundation

extension Tools {
    /// Reads a file: text, image, PDF or notebook.
    public enum Read: ToolDefinition {
        public static let name = "Read"

        public struct Input: Sendable, Equatable, Decodable {
            public var filePath: String
            /// First line to read, 1-based.
            public var offset: Int?
            public var limit: Int?
            /// PDF page range, e.g. `"1-5"`.
            public var pages: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filePath = try c.required(String.self, "file_path")
                offset = c.lenientInt("offset")
                limit = c.lenientInt("limit")
                pages = c.lenient(String.self, "pages")
            }
        }

        public enum Output: Sendable, Equatable, Decodable {
            case text(TextFile)
            /// Base64 image data (may be empty when the CLI stripped it).
            case image(base64: String, mediaType: String)
            case pdf(filePath: String)
            case notebook(filePath: String)
            /// The file had not changed since the model last read it.
            case unchanged(filePath: String)
            /// A kind this SDK does not model.
            case other(JSONValue)

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                let file = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "file")
                let filePath = file?.lenient(String.self, "filePath") ?? ""
                switch c.lenient(String.self, "type") {
                case "text":
                    self = .text(try c.required(TextFile.self, "file"))
                case "image":
                    self = .image(
                        base64: file?.lenient(String.self, "base64") ?? "",
                        mediaType: file?.lenient(String.self, "type") ?? "")
                case "pdf": self = .pdf(filePath: filePath)
                case "notebook": self = .notebook(filePath: filePath)
                case "file_unchanged": self = .unchanged(filePath: filePath)
                default: self = .other(decoder.rawValue())
                }
            }
        }

        public struct TextFile: Sendable, Equatable, Decodable {
            public var filePath: String
            /// The lines read, without line numbers.
            public var content: String
            public var numLines: Int
            /// 1-based line number of the first line in `content`.
            public var startLine: Int
            public var totalLines: Int

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                filePath = c.lenient(String.self, "filePath") ?? ""
                content = c.lenient(String.self, "content") ?? ""
                numLines = c.lenientInt("numLines") ?? 0
                startLine = c.lenientInt("startLine") ?? 1
                totalLines = c.lenientInt("totalLines") ?? 0
            }
        }
    }
}
