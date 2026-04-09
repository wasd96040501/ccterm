import Foundation

public struct ToolUseTodoWriteInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let todos: Todos?
}
