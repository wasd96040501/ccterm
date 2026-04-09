import Foundation

extension MessageContentItem {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "image":
            let _v: Image = try _jp(dict)
            self = .image(_v)
        case "text":
            let _v: Text = try _jp(dict)
            self = .text(_v)
        case "tool_result":
            let _v: ItemToolResult = try _jp(dict)
            self = .toolResult(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .image(let v): return v.toJSON()
        case .text(let v): return v.toJSON()
        case .toolResult(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension MessageContentItem {
    public func strippingUnknown() -> MessageContentItem? {
        switch self {
        case .unknown: return nil
        case .image(let v): return v.strippingUnknown().map { .image($0) }
        case .text(let v): return v.strippingUnknown().map { .text($0) }
        case .toolResult(let v): return v.strippingUnknown().map { .toolResult($0) }
        }
    }
}

extension MessageContentItem {
    public func toTypedJSON() -> Any {
        switch self {
        case .image(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "image"
            return d
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
