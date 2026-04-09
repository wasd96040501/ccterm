import Foundation

public enum ToolUseResult: JSONParseable {
    case string(String)
    case object(ToolUseResultObject)
    case other(Any)
}
