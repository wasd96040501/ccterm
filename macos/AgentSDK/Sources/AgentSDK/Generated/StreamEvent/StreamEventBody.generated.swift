import Foundation

public enum StreamEventBody: JSONParseable, UnknownStrippable {
    case contentBlockDelta(StreamContentBlockDelta)
    case contentBlockStart(StreamContentBlockStart)
    case contentBlockStop(StreamContentBlockStop)
    case messageDelta(StreamMessageDelta)
    case messageStart(StreamMessageStart)
    case messageStop(StreamMessageStop)
    case unknown(name: String, raw: [String: Any])
}
