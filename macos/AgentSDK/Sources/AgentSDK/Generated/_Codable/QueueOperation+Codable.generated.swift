import Foundation

extension QueueOperation {
    public init(json: Any) throws {
        guard let dict = json as? [String: Any] else {
            self = .unknown(name: "unknown", raw: [:]); return
        }
        guard let tag = dict["operation"] as? String else {
            self = .unknown(name: "unknown", raw: dict); return
        }
        switch tag {
        case "dequeue":
            let _v: Dequeue = try _jp(dict)
            self = .dequeue(_v)
        case "enqueue":
            let _v: Enqueue = try _jp(dict)
            self = .enqueue(_v)
        case "remove":
            let _v: Dequeue = try _jp(dict)
            self = .remove(_v)
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .dequeue(let v): return v.toJSON()
        case .enqueue(let v): return v.toJSON()
        case .remove(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }
}

extension QueueOperation {
    public func strippingUnknown() -> QueueOperation? {
        switch self {
        case .unknown: return nil
        case .dequeue(let v): return v.strippingUnknown().map { .dequeue($0) }
        case .enqueue(let v): return v.strippingUnknown().map { .enqueue($0) }
        case .remove(let v): return v.strippingUnknown().map { .remove($0) }
        }
    }
}

extension QueueOperation {
    public func toTypedJSON() -> Any {
        switch self {
        case .dequeue(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["operation"] = "dequeue"
            return d
        case .enqueue(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["operation"] = "enqueue"
            return d
        case .remove(let v):
            var d = v.toTypedJSON() as? [String: Any] ?? [:]
            d["operation"] = "remove"
            return d
        case .unknown(_, let raw): return raw
        }
    }
}
