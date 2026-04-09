import Foundation

public struct ObjectTodoWrite: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let newTodos: [NewTodos]?
    public let oldTodos: [NewTodos]?
    public let verificationNudgeNeeded: Bool?
}
