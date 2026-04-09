import Foundation

public enum ToolUseReadInputOffset: JSONParseable {
    case string(String)
    case integer(Int)
    case other(Any)
}
