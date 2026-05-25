import Foundation

extension StreamEventBody {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:])
            return
        }
        guard let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: dict)
            return
        }
        switch tag {
        case "content_block_delta":
            let _v: StreamContentBlockDelta = try _jp(dict)
            self = .contentBlockDelta(_v)
        case "content_block_start":
            let _v: StreamContentBlockStart = try _jp(dict)
            self = .contentBlockStart(_v)
        case "content_block_stop":
            let _v: StreamContentBlockStop = try _jp(dict)
            self = .contentBlockStop(_v)
        case "message_delta":
            let _v: StreamMessageDelta = try _jp(dict)
            self = .messageDelta(_v)
        case "message_start":
            let _v: StreamMessageStart = try _jp(dict)
            self = .messageStart(_v)
        case "message_stop":
            let _v: StreamMessageStop = try _jp(dict)
            self = .messageStop(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .contentBlockDelta(let v): return v.toJSON()
        case .contentBlockStart(let v): return v.toJSON()
        case .contentBlockStop(let v): return v.toJSON()
        case .messageDelta(let v): return v.toJSON()
        case .messageStart(let v): return v.toJSON()
        case .messageStop(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension StreamEventBody {
    public func strippingUnknown() -> StreamEventBody? {
        switch self {
        case .unknown: return nil
        case .contentBlockDelta(let v): return v.strippingUnknown().map { .contentBlockDelta($0) }
        case .contentBlockStart(let v): return v.strippingUnknown().map { .contentBlockStart($0) }
        case .contentBlockStop(let v): return v.strippingUnknown().map { .contentBlockStop($0) }
        case .messageDelta(let v): return v.strippingUnknown().map { .messageDelta($0) }
        case .messageStart(let v): return v.strippingUnknown().map { .messageStart($0) }
        case .messageStop(let v): return v.strippingUnknown().map { .messageStop($0) }
        }
    }
}

extension StreamEventBody {
    public func toTypedJSON() -> Any {
        switch self {
        case .contentBlockDelta(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "content_block_delta"
            return d
        case .contentBlockStart(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "content_block_start"
            return d
        case .contentBlockStop(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "content_block_stop"
            return d
        case .messageDelta(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "message_delta"
            return d
        case .messageStart(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "message_start"
            return d
        case .messageStop(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["type"] = "message_stop"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
