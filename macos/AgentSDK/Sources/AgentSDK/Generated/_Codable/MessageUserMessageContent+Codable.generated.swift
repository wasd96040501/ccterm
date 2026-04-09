import Foundation

extension MessageUserMessageContent {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "text":
            let _v: Text = try _jp(dict)
            self = .text(_v)
        case "tool_result":
            let _v: ContentToolResult = try _jp(dict)
            self = .toolResult(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .text(let v): return v.toJSON()
        case .toolResult(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension MessageUserMessageContent {
    public func strippingUnknown() -> MessageUserMessageContent? {
        switch self {
        case .unknown: return nil
        case .text(let v): return v.strippingUnknown().map { .text($0) }
        case .toolResult(let v): return v.strippingUnknown().map { .toolResult($0) }
        }
    }
}

extension MessageUserMessageContent {
    public func toTypedJSON() -> Any {
        switch self {
        case .text(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "text"
            return d
        case .toolResult(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "tool_result"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
