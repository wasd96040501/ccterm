import Foundation

public struct Message2StreamEvent: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let event: StreamEventBody?
    public let parentToolUseId: String?
    public let sessionId: String?
    public let ttftMs: Int?
    public let uuid: String?
}
