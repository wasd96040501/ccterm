import Foundation

public enum InputMessage: JSONParseable {
    case string(String)
    case object(MessageObject)
    case other(Any)
}
