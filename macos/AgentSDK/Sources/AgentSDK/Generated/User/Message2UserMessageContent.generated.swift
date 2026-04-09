import Foundation

public enum Message2UserMessageContent: JSONParseable {
    case string(String)
    case array([MessageContentItem])
    case other(Any)
}
