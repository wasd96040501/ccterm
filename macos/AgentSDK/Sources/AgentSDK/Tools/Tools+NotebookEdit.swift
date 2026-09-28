import Foundation

extension Tools {
    /// Edits a Jupyter notebook cell.
    public enum NotebookEdit: ToolDefinition {
        public static let name = "NotebookEdit"
        public typealias Output = JSONValue

        public struct Input: Sendable, Equatable, Decodable {
            public var notebookPath: String
            public var cellID: String?
            public var newSource: String
            /// `code` or `markdown`.
            public var cellType: String?
            /// `replace` (default), `insert`, or `delete`.
            public var editMode: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                notebookPath = try c.required(String.self, "notebook_path")
                cellID = c.lenient(String.self, "cell_id")
                newSource = c.lenient(String.self, "new_source") ?? ""
                cellType = c.lenient(String.self, "cell_type")
                editMode = c.lenient(String.self, "edit_mode")
            }
        }
    }
}
