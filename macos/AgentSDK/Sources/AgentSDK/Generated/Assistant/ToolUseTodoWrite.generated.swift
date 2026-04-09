import Foundation

public struct ToolUseTodoWrite: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseTodoWriteInput?
}
