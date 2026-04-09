import Foundation

public enum Limit: JSONParseable {
    case string(String)
    case integer(Int)
    case other(Any)
}
