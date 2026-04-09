import Foundation

public enum ContentToolResultContent: JSONParseable {
    case string(String)
    case array([ContentToolResultContentItem])
    case other(Any)
}
