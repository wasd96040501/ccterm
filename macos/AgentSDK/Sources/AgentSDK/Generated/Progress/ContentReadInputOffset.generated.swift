import Foundation

public enum ContentReadInputOffset: JSONParseable {
    case string(String)
    case integer(Int)
    case other(Any)
}
