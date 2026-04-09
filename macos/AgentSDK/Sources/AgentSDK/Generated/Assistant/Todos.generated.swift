import Foundation

public enum Todos: JSONParseable {
    case string(String)
    case array([TodosItem])
    case other(Any)
}
