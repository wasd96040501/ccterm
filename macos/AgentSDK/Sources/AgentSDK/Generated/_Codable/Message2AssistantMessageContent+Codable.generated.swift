import Foundation

extension Message2AssistantMessageContent {
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
        case "thinking":
            let _v: Thinking = try _jp(dict)
            self = .thinking(_v)
        case "tool_use":
            let _v: ToolUse = try _jp(dict)
            self = .toolUse(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .text(let v): return v.toJSON()
        case .thinking(let v): return v.toJSON()
        case .toolUse(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension Message2AssistantMessageContent {
    public func strippingUnknown() -> Message2AssistantMessageContent? {
        switch self {
        case .unknown: return nil
        case .text(let v): return v.strippingUnknown().map { .text($0) }
        case .thinking(let v): return v.strippingUnknown().map { .thinking($0) }
        case .toolUse(let v): return v.strippingUnknown().map { .toolUse($0) }
        }
    }
}

extension Message2AssistantMessageContent {
    public func toTypedJSON() -> Any {
        switch self {
        case .text(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "text"
            return d
        case .thinking(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "thinking"
            return d
        case .toolUse(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "tool_use"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
