import Foundation

extension ItemToolResultContentItem {
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
        case "tool_reference":
            let _v: ToolReference = try _jp(dict)
            self = .toolReference(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .image(let v): return v.toJSON()
        case .text(let v): return v.toJSON()
        case .toolReference(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension ItemToolResultContentItem {
    public func strippingUnknown() -> ItemToolResultContentItem? {
        switch self {
        case .unknown: return nil
        case .image(let v): return v.strippingUnknown().map { .image($0) }
        case .text(let v): return v.strippingUnknown().map { .text($0) }
        case .toolReference(let v): return v.strippingUnknown().map { .toolReference($0) }
        }
    }
}

extension ItemToolResultContentItem {
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
        case .toolReference(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "tool_reference"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
