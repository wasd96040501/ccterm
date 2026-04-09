import Foundation

public enum ItemToolResultContent: JSONParseable {
    case string(String)
    case array([ItemToolResultContentItem])
    case other(Any)
}
