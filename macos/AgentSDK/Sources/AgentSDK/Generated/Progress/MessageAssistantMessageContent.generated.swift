import Foundation

public enum MessageAssistantMessageContent: JSONParseable, UnknownStrippable {
    case Bash(ContentBash)
    case Edit(ContentEdit)
    case Glob(ContentGlob)
    case Grep(ContentGrep)
    case Read(ContentRead)
    case ToolSearch(ContentToolSearch)
    case WebFetch(ContentWebFetch)
    case WebSearch(ContentWebSearch)
    case Write(ContentWrite)
    case unknown(name: String, raw: [String: Any])
}
